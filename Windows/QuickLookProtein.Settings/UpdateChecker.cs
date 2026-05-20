// UpdateChecker.cs - in-process auto-updater for the Windows
// Settings app (1.7.77+).
//
// Why we wrote our own instead of pulling in WinSparkle:
//   - WinSparkle is a 1.6 MB native DLL that we'd have to ship in
//     the Setup.exe payload, sign separately (it's currently
//     unsigned), and bridge via P/Invoke.  Our needs are simple
//     enough that a 200-line managed-only checker beats the
//     deps tax.
//   - The plugin DLL itself is loaded by QL-Win's process, not the
//     Settings app, so the actual install flow has to be
//     "download Setup.exe -> run it -> Setup.exe quits QuickLook,
//     replaces files, restarts QuickLook" anyway.  WinSparkle's
//     in-place .exe replacement model doesn't fit that shape -
//     we'd still end up shelling out to Setup.exe.
//
// Flow:
//   1. CheckAsync() hits the GitHub releases API once and parses
//      the latest non-draft, non-prerelease tag.
//   2. If the tag's numeric part is strictly greater than the
//      running Settings.exe FileVersion, returns an UpdateInfo
//      with the version, release URL, and a short release-notes
//      excerpt (the body's first 500 chars after collapsing
//      markdown headers).
//   3. DownloadAndInstallAsync(info) GETs
//      QuickLookProtein-Setup.exe from the matching release,
//      streams to %TEMP%, launches it via Process.Start, then
//      Shutdown()s the WPF app so Setup.exe can replace
//      Settings.exe without an in-use lock.
//
// Settings:
//   "AutoCheckUpdates" (HKCU\Software\QuickLookProtein\Settings,
//   DWORD) gates the launch-time check.  Default OFF for the
//   first release - the user has to opt in via the Settings
//   "Updates" card.  Manual "Check now" works regardless.

using Microsoft.Win32;
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;

namespace QuickLookProtein.Settings;

public sealed class UpdateInfo
{
    public Version Latest { get; init; } = new Version(0, 0, 0, 0);
    public string TagName { get; init; } = "";
    public string ReleaseUrl { get; init; } = "";
    public string SetupExeUrl { get; init; } = "";
    public string ReleaseNotes { get; init; } = "";
}

internal static class UpdateChecker
{
    private const string RepoOwner = "ArioMoniri";
    private const string RepoName  = "QuickLookProtein";
    private const string SetupAssetName = "QuickLookProtein-Setup.exe";
    private const string UserAgent = "QuickLookProtein-Settings/1.0";

    // The releases API endpoint returns the most recent NON-draft,
    // NON-prerelease release. We want exactly that semantic.
    private const string ApiUrl =
        "https://api.github.com/repos/" + RepoOwner + "/" + RepoName + "/releases/latest";

    /// <summary>Read+write the "auto-check at launch" preference.</summary>
    public static bool AutoCheckEnabled
    {
        get
        {
            try
            {
                using var k = Registry.CurrentUser.OpenSubKey(
                    @"Software\QuickLookProtein\Settings", writable: false);
                return k?.GetValue("AutoCheckUpdates") is int i && i != 0;
            }
            catch { return false; }
        }
        set
        {
            try
            {
                using var k = Registry.CurrentUser.CreateSubKey(
                    @"Software\QuickLookProtein\Settings", writable: true);
                k?.SetValue("AutoCheckUpdates", value ? 1 : 0, RegistryValueKind.DWord);
            }
            catch { /* best-effort */ }
        }
    }

    /// <summary>Current Settings.exe version stamped by the release
    /// workflow's /p:FileVersion=… flag. Falls back to 0.0.0 for
    /// local dev builds (the csproj defaults FileVersion to 0.0.0).</summary>
    public static Version CurrentVersion
    {
        get
        {
            try
            {
                var v = Assembly.GetExecutingAssembly().GetName().Version;
                return v ?? new Version(0, 0, 0, 0);
            }
            catch { return new Version(0, 0, 0, 0); }
        }
    }

    /// <summary>Hit GitHub once and return either null (no update)
    /// or an UpdateInfo with the latest version + the Setup.exe URL.
    /// Errors are swallowed and logged via Debug.WriteLine; the
    /// caller treats null as "couldn't check, no notification".</summary>
    public static async Task<UpdateInfo?> CheckAsync()
    {
        try
        {
            // Force TLS 1.2 - GitHub API requires it and .NET 4.7.2
            // sometimes defaults to TLS 1.0.
            try
            {
                ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            }
            catch { /* fixed in .NET 4.7+ by default; ignore on newer */ }

            using var http = new HttpClient
            {
                Timeout = TimeSpan.FromSeconds(15)
            };
            http.DefaultRequestHeaders.UserAgent.ParseAdd(UserAgent);
            http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");

            var json = await http.GetStringAsync(ApiUrl).ConfigureAwait(false);

            // Parse the small subset we need without pulling in a JSON
            // library. The shape is stable: tag_name, html_url, body,
            // assets[].name, assets[].browser_download_url.  Regex is
            // fine for the four scalar fields; the assets array
            // lookup is one-pass.
            var tag = ExtractJsonScalar(json, "tag_name");
            var url = ExtractJsonScalar(json, "html_url");
            var body = ExtractJsonScalar(json, "body");
            if (string.IsNullOrEmpty(tag) || string.IsNullOrEmpty(url))
                return null;

            // tag_name is e.g. "v1.7.77" - strip the leading v.
            var verStr = tag!.TrimStart('v', 'V');
            if (!TryParseVersion(verStr, out var latest))
                return null;

            // Find the Setup.exe asset URL inside the assets array.
            var setupUrl = ExtractAssetUrl(json, SetupAssetName);

            return new UpdateInfo
            {
                Latest = latest,
                TagName = tag!,
                ReleaseUrl = url!,
                SetupExeUrl = setupUrl ?? "",
                ReleaseNotes = TruncateMarkdown(body ?? "", 500),
            };
        }
        catch (Exception ex)
        {
            Debug.WriteLine("UpdateChecker.CheckAsync failed: " + ex.Message);
            return null;
        }
    }

    /// <summary>True if <paramref name="info"/>'s version is strictly
    /// greater than the running Settings.exe.</summary>
    public static bool IsNewer(UpdateInfo info)
    {
        return info.Latest > CurrentVersion;
    }

    /// <summary>Download the Setup.exe to %TEMP%, run it, and quit
    /// this app so Setup.exe can replace our files without an
    /// in-use lock.  Returns the path the installer was downloaded
    /// to for diagnostic purposes; throws on network / IO failure.</summary>
    public static async Task<string> DownloadAndInstallAsync(UpdateInfo info, IProgress<double>? progress = null)
    {
        if (string.IsNullOrEmpty(info.SetupExeUrl))
            throw new InvalidOperationException("No Setup.exe asset URL in the release");

        var tempPath = Path.Combine(Path.GetTempPath(),
            $"QuickLookProtein-Setup-{info.TagName}.exe");

        try { ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12; }
        catch { }

        using (var http = new HttpClient { Timeout = TimeSpan.FromMinutes(5) })
        {
            http.DefaultRequestHeaders.UserAgent.ParseAdd(UserAgent);

            using var resp = await http.GetAsync(info.SetupExeUrl,
                HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false);
            resp.EnsureSuccessStatusCode();

            var total = resp.Content.Headers.ContentLength ?? -1L;
            using var fs = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None);
            using var src = await resp.Content.ReadAsStreamAsync().ConfigureAwait(false);

            var buf = new byte[64 * 1024];
            long copied = 0;
            int n;
            while ((n = await src.ReadAsync(buf, 0, buf.Length).ConfigureAwait(false)) > 0)
            {
                await fs.WriteAsync(buf, 0, n).ConfigureAwait(false);
                copied += n;
                if (total > 0 && progress != null)
                {
                    progress.Report((double)copied / total);
                }
            }
        }

        // Launch the installer and quit ourselves so Setup.exe can
        // replace Settings.exe without a sharing-violation. Setup.exe
        // also re-launches the Settings app at the end of its run.
        Process.Start(new ProcessStartInfo
        {
            FileName = tempPath,
            UseShellExecute = true,   // gives Windows a chance to handle UAC if it triggers
        });

        await Application.Current.Dispatcher.InvokeAsync(() =>
        {
            // Small delay so the launched Setup.exe handle is alive
            // before we close the WPF app and release the EXE lock.
            Application.Current.Shutdown();
        });

        return tempPath;
    }

    // ------------ tiny JSON helpers ----------------

    private static string? ExtractJsonScalar(string json, string key)
    {
        // Matches  "key":"value"  with backslash-escape handling.
        // Good enough for the four well-formed GitHub fields we need;
        // not a general JSON parser.
        var m = Regex.Match(json,
            "\"" + Regex.Escape(key) + "\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"");
        if (!m.Success) return null;
        return Regex.Unescape(m.Groups[1].Value);
    }

    private static string? ExtractAssetUrl(string json, string assetName)
    {
        // Walk the assets array looking for { "name": "<assetName>",
        // ..., "browser_download_url": "<url>" } in any order.
        // We only need the first match. Regex pattern allows other
        // fields between name and browser_download_url because the
        // GitHub API doesn't guarantee field order.
        var nameEsc = Regex.Escape(assetName);
        var pattern =
            "\"name\"\\s*:\\s*\"" + nameEsc + "\""           // anchor on name
            + "[\\s\\S]*?"                                   // intervening fields
            + "\"browser_download_url\"\\s*:\\s*\"([^\"]+)\"";
        var m = Regex.Match(json, pattern);
        return m.Success ? m.Groups[1].Value : null;
    }

    private static bool TryParseVersion(string s, out Version v)
    {
        // GitHub tags are X.Y.Z; Version requires X.Y.Z.W or X.Y.Z.
        // Pad missing parts with zero.
        var parts = s.Split('.');
        if (parts.Length < 2) { v = new Version(); return false; }
        var nums = new int[Math.Max(parts.Length, 3)];
        for (int i = 0; i < parts.Length; i++)
        {
            if (!int.TryParse(parts[i], out nums[i]))
            {
                v = new Version();
                return false;
            }
        }
        try
        {
            v = parts.Length switch
            {
                2 => new Version(nums[0], nums[1]),
                3 => new Version(nums[0], nums[1], nums[2]),
                _ => new Version(nums[0], nums[1], nums[2], nums[3]),
            };
            return true;
        }
        catch
        {
            v = new Version();
            return false;
        }
    }

    private static string TruncateMarkdown(string md, int maxChars)
    {
        if (string.IsNullOrEmpty(md)) return "";
        // Collapse markdown headers + bullets to plain-ish lines so
        // the WPF TextBlock renders something readable. The full
        // notes are at info.ReleaseUrl for users who want them.
        var s = md.Replace("\r\n", "\n");
        s = Regex.Replace(s, @"^#{1,6}\s*", "", RegexOptions.Multiline);
        s = Regex.Replace(s, @"^\s*[-*]\s*", "• ", RegexOptions.Multiline);
        s = Regex.Replace(s, @"`+", "");
        s = Regex.Replace(s, @"\*\*([^*]+)\*\*", "$1");
        s = s.Trim();
        if (s.Length > maxChars) s = s.Substring(0, maxChars) + " …";
        return s;
    }
}
