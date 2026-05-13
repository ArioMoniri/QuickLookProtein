// MoleculePanel — the WPF UserControl that hosts a WebView2 and renders
// a structure file by handing it the shared 3Dmol.js viewer template.
//
// Why a virtual host mapping (rather than loadHTMLString / NavigateToString):
//   The macOS QLExtension uses loadHTMLString(html, baseURL:) with a
//   file:// URL so the inline <script src="3Dmol.js"> resolves against
//   the .appex bundle. WebView2's equivalent is
//   `SetVirtualHostNameToFolderMapping` — we map a fake hostname to the
//   plugin's Resources/ directory and have the HTML reference
//   `https://quicklookprotein.local/3Dmol.js`. That keeps the rendered
//   page on an https-like origin (which WebView2 trusts more readily
//   for WebGL + WASM than file://) and avoids the brittle
//   "WebContent process can't follow file:// across bundle boundaries"
//   problem we hit on macOS Tahoe with the thumbnail extension.

using Microsoft.Web.WebView2.Core;
using QuickLook.Common.Plugin;
using System;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Controls;
using System.Windows.Threading;

namespace QuickLookProtein.Plugin;

public partial class MoleculePanel : UserControl, IDisposable
{
    /// Stable virtual host name for the WebView2 → Resources mapping.
    /// Anything in <c>Resources/</c> becomes reachable at
    /// <c>https://VIRTUAL_HOST/&lt;filename&gt;</c>.
    private const string VirtualHost = "quicklookprotein.local";

    public MoleculePanel()
    {
        InitializeComponent();
    }

    public async void LoadFile(string path, ContextObject context)
    {
        // Surface the filename on the splash before WebView2 starts —
        // gives the user something to recognise while the renderer warms.
        SplashTitle.Text = $"Loading {Path.GetFileName(path)}…";
        try
        {
            await LoadFileAsync(path, context);
        }
        catch (Exception ex)
        {
            // Surface the failure in the preview itself rather than
            // ending up with a silent blank window. QL-Win doesn't have
            // a built-in "error sheet" we can pop, so we render an
            // HTML error page inside the same WebView.
            await EnsureWebViewReadyAsync();
            WebView.NavigateToString(BuildErrorHtml(
                "Could not render molecule",
                $"{ex.GetType().Name}: {ex.Message}"));
        }
        finally
        {
            // Mark the panel as no-longer-busy on the UI thread so
            // QL-Win's spinner clears.
            await Dispatcher.InvokeAsync(() => context.IsBusy = false,
                                         DispatcherPriority.Loaded);
        }
    }

    private async Task LoadFileAsync(string path, ContextObject context)
    {
        // Resources/ sits next to our DLL in the plugin's install dir.
        // Don't rely on Environment.CurrentDirectory — QL-Win's process
        // CWD is its own install dir, not the plugin's.
        var pluginDir = Path.GetDirectoryName(
            Assembly.GetExecutingAssembly().Location)
            ?? throw new InvalidOperationException("plugin DLL has no path");
        var resourcesDir = Path.Combine(pluginDir, "Resources");
        var templatePath = Path.Combine(resourcesDir, "viewer.html");
        if (!File.Exists(templatePath))
            throw new FileNotFoundException(
                $"viewer.html missing from plugin install at {resourcesDir}");

        var template = await File.ReadAllTextAsync(templatePath);
        var moleculeData = await File.ReadAllTextAsync(path);
        var ext = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        var html = FillTemplate(template, ext,
                                Path.GetFileName(path),
                                moleculeData);

        await EnsureWebViewReadyAsync();
        // The macOS app reads 3Dmol.js with a relative <script src="3Dmol.js">
        // tag relative to the baseURL. Map the plugin's Resources/ to a
        // virtual host so the same tag resolves to that folder here.
        WebView.CoreWebView2.SetVirtualHostNameToFolderMapping(
            VirtualHost, resourcesDir,
            CoreWebView2HostResourceAccessKind.Allow);

        // Rewrite the bare <script src="3Dmol.js"> to point at the
        // virtual host. We do this in code rather than in the template
        // so the same template still works on macOS where it resolves
        // against the .appex's own Resources/ as baseURL.
        html = html.Replace(
            "<script src=\"3Dmol.js\">",
            $"<script src=\"https://{VirtualHost}/3Dmol.js\">");

        WebView.NavigateToString(html);
    }

    /// Initialise the WebView2 core only once; subsequent calls are
    /// no-ops because EnsureCoreWebView2Async short-circuits internally.
    private async Task EnsureWebViewReadyAsync()
    {
        if (WebView.CoreWebView2 != null) return;
        // Use a per-user data folder under LocalAppData so multiple
        // QL-Win plugins can't fight over a shared user-data folder.
        var userDataFolder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "QuickLookProtein", "WebView2");
        Directory.CreateDirectory(userDataFolder);
        var env = await CoreWebView2Environment.CreateAsync(
            browserExecutableFolder: null,
            userDataFolder: userDataFolder);
        await WebView.EnsureCoreWebView2Async(env);

        // Hide the splash once the WebView has fully painted. We use
        // NavigationCompleted (not ContentLoading) because the WebGL
        // canvas inside the page only becomes visible after 3Dmol's
        // `viewer.render()` runs, and that happens in the page's load
        // handler — by NavigationCompleted, the molecule is on screen.
        WebView.CoreWebView2.NavigationCompleted += (_, _) =>
        {
            Splash.Visibility = System.Windows.Visibility.Collapsed;
        };
    }

    /// Substitute every <c>{KEY}</c> placeholder the macOS viewer
    /// template uses. We keep the placeholder set identical to
    /// <c>Xcode/Shared/SharedFunctions.swift</c>'s
    /// <c>prepare3DmolHTML</c> so future template changes only need to
    /// be edited in one place.
    private static string FillTemplate(string template, string ext,
                                       string fileName, string moleculeData)
    {
        var (format, atomStyle) = ResolveFormatAndStyle(ext);
        var safeData = SanitizeForScriptBlock(moleculeData);
        var safeName = EscapeForHtmlAttribute(fileName);

        // Order matters: insert the molecule data block LAST so
        // {…} sequences inside it can't be mistaken for placeholders.
        var html = template
            .Replace("{ATOM_STYLE}",        atomStyle)
            .Replace("{COLOR_SCHEME}",      "spectrum")
            .Replace("{BG_COLOR}",          "000000")
            .Replace("{BG_ALPHA}",          "1.0")
            .Replace("{ROTATION_SPEED}",    "1")
            .Replace("{DATA_FORMAT}",       format)
            .Replace("{AUTO_STYLE_HETERO}", "true")
            .Replace("{SHOW_SURFACE}",      "false")
            .Replace("{HIDE_H}",            "false")
            .Replace("{SHOW_UNIT_CELL}",    "false")
            .Replace("{SHOW_INFO}",         "true")
            .Replace("{FILE_NAME}",         safeName)
            .Replace("{ZOOM_FACTOR}",       "1.0")
            .Replace("{ZOOM_IS_AUTO}",      "true")
            .Replace("{THUMBNAIL_MODE}",    "false")
            .Replace("{MOL_DATA}",          safeData);
        return html;
    }

    /// Map a file extension to the (3Dmol-format, default-atom-style)
    /// pair. Mirrors Settings.swift's dataFormat(forExtension:) plus
    /// atomStyle(forExtension:) so both platforms share defaults.
    private static (string Format, string AtomStyle) ResolveFormatAndStyle(string ext) => ext switch
    {
        "pdb"    or "ent"    => ("pdb",    "cartoon"),
        "pdbqt"              => ("pdbqt",  "cartoon"),
        "pqr"                => ("pqr",    "stick"),
        "cif"    or "mmcif"  => ("cif",    "stick"),
        "sdf"                => ("sdf",    "stick"),
        "mol"                => ("sdf",    "stick"),   // 3Dmol parses MOL via SDF parser
        "mol2"               => ("mol2",   "stick"),
        "xyz"                => ("xyz",    "stick"),
        "gro"                => ("gro",    "cartoon"),
        "prmtop" or "top"    => ("prmtop", "stick"),
        "cube"   or "cub"    => ("cube",   "stick"),
        "vasp"   or "poscar" => ("vasp",   "sphere"),
        "cdjson" or "json"   => ("cdjson", "stick"),
        "mmtf"               => ("mmtf",   "cartoon"),
        _                    => ("pdb",    "stick"),
    };

    /// Neutralise the only sequences that can break out of a
    /// <c>&lt;script type="text/plain"&gt;</c> data block. Same set as the
    /// Swift sanitiser, kept in lock-step so a file that renders on macOS
    /// renders identically here.
    private static string SanitizeForScriptBlock(string s)
    {
        if (s.Length > 0 && s[0] == '﻿') s = s.Substring(1);
        var sb = new StringBuilder(s);
        sb.Replace("\0", string.Empty);
        sb.Replace("</script", @"<\/script");
        sb.Replace("<!--",    @"<\!--");
        sb.Replace("-->",     @"--\>");
        return sb.ToString();
    }

    private static string EscapeForHtmlAttribute(string s)
    {
        var sb = new StringBuilder(s);
        sb.Replace("\\", "\\\\");
        sb.Replace("\"", "\\\"");
        sb.Replace("'",  "\\'");
        sb.Replace("<",  "&lt;");
        sb.Replace(">",  "&gt;");
        sb.Replace("{",  "&#123;");
        sb.Replace("}",  "&#125;");
        sb.Replace("\n", " ");
        sb.Replace("\r", " ");
        return sb.ToString();
    }

    private static string BuildErrorHtml(string title, string detail)
    {
        // Slightly fancier error page than the previous one-liner: shows a
        // branded header, the actual error, and a hint about supported
        // formats so the user can tell at a glance whether the failure is
        // "this format isn't supported" vs "the file is malformed".
        var safeTitle  = System.Net.WebUtility.HtmlEncode(title);
        var safeDetail = System.Net.WebUtility.HtmlEncode(detail);
        return $@"
<!doctype html>
<html>
<head>
  <meta charset=""utf-8"">
  <style>
    :root {{ color-scheme: dark; }}
    html, body {{ margin: 0; height: 100%; background: #0e0e10;
                  color: #e6e6e8; font: 13px/1.45 'Segoe UI Variable',
                  'Segoe UI', -apple-system, BlinkMacSystemFont,
                  Helvetica, Arial, sans-serif; }}
    .wrap {{ height: 100%; display: flex; align-items: center;
             justify-content: center; padding: 24px; }}
    .card {{ max-width: 480px; padding: 28px 30px; border-radius: 14px;
             background: linear-gradient(180deg, #1c1c20, #131316);
             border: 1px solid #2a2a2e; text-align: center;
             box-shadow: 0 8px 24px rgba(0,0,0,0.45); }}
    .icon {{ width: 52px; height: 52px; border-radius: 12px;
             background: rgba(255, 102, 102, 0.14);
             color: #ff8a8a; display: inline-flex; align-items: center;
             justify-content: center; font-size: 28px;
             margin-bottom: 14px; }}
    .title {{ font-size: 16px; font-weight: 600;
              color: #ff8a8a; margin-bottom: 6px; }}
    .detail {{ font-size: 13px; color: #c8c8cc; margin-bottom: 14px;
               word-break: break-word; }}
    .hint {{ font-size: 11.5px; color: #8a8a90; line-height: 1.55; }}
    code {{ font-family: 'Cascadia Code', 'JetBrains Mono', Consolas,
            monospace; font-size: 11px;
            background: rgba(255,255,255,0.04); padding: 2px 5px;
            border-radius: 4px; }}
  </style>
</head>
<body>
  <div class=""wrap"">
    <div class=""card"">
      <div class=""icon"">!</div>
      <div class=""title"">{safeTitle}</div>
      <div class=""detail"">{safeDetail}</div>
      <div class=""hint"">
        Supported formats:
        <code>.pdb</code> <code>.cif</code> <code>.sdf</code>
        <code>.mol</code> <code>.mol2</code> <code>.xyz</code>
        <code>.gro</code> <code>.cube</code> <code>.pqr</code>
        <code>.vasp</code> <code>.cdjson</code> <code>.mmtf</code>
        <br>If your file is one of these and still fails to render,
        please open an issue at
        github.com/ArioMoniri/QuickLookProtein
      </div>
    </div>
  </div>
</body>
</html>";
    }

    public void Dispose()
    {
        WebView?.Dispose();
    }
}
