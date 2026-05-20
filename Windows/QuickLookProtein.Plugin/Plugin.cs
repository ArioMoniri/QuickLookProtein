// QuickLookProtein.Plugin — IViewer implementation for QL-Win/QuickLook.
//
// Lifecycle mirrors macOS's QLPreviewingController:
//   - CanHandle(path)  → "is this a file we render?"
//   - Prepare(path,…)  → set window size before content shows
//   - View(path,…)     → build the panel, kick off WebView2 load
//   - Cleanup()        → release the WebView2 instance

using QuickLook.Common.Plugin;
using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Windows;

namespace QuickLookProtein.Plugin;

public sealed class Plugin : IViewer
{
    /// File extensions we render. Matches the macOS QL extension's
    /// QLSupportedContentTypes list exactly so a user dropping the same
    /// file on either platform gets the same answer.
    private static readonly string[] SupportedExtensions = new[]
    {
        ".pdb", ".ent", ".pdbqt", ".pqr",
        ".cif", ".mmcif",
        ".sdf", ".mol", ".mol2",
        ".xyz",
        ".gro",
        ".cube", ".cub",
        ".vasp", ".poscar",
        ".cdjson",
        ".mmtf",
        ".prmtop", ".top"
    };

    // _panel is intentionally typed as `object?`, NOT `MoleculePanel?`.
    // Reason: QL-Win discovers our IViewer via Assembly.LoadFrom +
    // GetTypes(). When the CLR materialises Plugin's metadata it walks
    // every field's declared type. A `MoleculePanel?` field forces
    // MoleculePanel to be loaded at type-discovery time, which in turn
    // forces Microsoft.Web.WebView2.Wpf to resolve, which fails because
    // QL-Win's plugin folder isn't on the standard probing path. The
    // result was QL-Win silently dropping our plugin BEFORE Init() ever
    // ran (plugin.log never appeared in user diagnostics from 1.7.68).
    // Storing the panel as `object?` keeps Plugin's metadata free of
    // any WebView2 transitive ref; MoleculePanel is only resolved when
    // View() actually runs - at which point our static-cctor
    // AssemblyResolve hook is already in place to redirect the lookup
    // into the plugin folder.
    private object? _panel;

    /// Guarantees the AssemblyResolve hook is attached even when QL-Win
    /// constructs a fresh IViewer per file. Set once from the static
    /// constructor.
    private static readonly bool _resolverAttached;

    /// Static constructor - runs the FIRST time the CLR touches the
    /// Plugin type, which is when QL-Win does
    /// `Activator.CreateInstance(typeof(Plugin))`. That's BEFORE Init()
    /// (which is an instance method called after construction) and
    /// crucially BEFORE View() (which is what triggers MoleculePanel
    /// instantiation and therefore WebView2 type-loading). Attaching
    /// the resolver here means the very first WebView2 reference
    /// resolution attempt succeeds.
    static Plugin()
    {
        // FIRST thing the cctor does: drop a sentinel file. Bypasses
        // PluginLog entirely (raw File.WriteAllText) so that even if
        // PluginLog has a bug, we still get evidence that the cctor
        // ran. This file's existence (or absence) is what tells us
        // whether QL-Win is touching the Plugin type at all - the
        // previous diagnostics couldn't distinguish "QL-Win never
        // touched the type" from "QL-Win touched the type but
        // PluginLog silently failed".
        try
        {
            var sentinelDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "QuickLookProtein");
            Directory.CreateDirectory(sentinelDir);
            File.WriteAllText(
                Path.Combine(sentinelDir, "cctor.txt"),
                $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}\n" +
                $"Plugin static cctor ran in PID {Process.GetCurrentProcess().Id}\n" +
                $"  exe={Process.GetCurrentProcess().MainModule?.FileName}\n" +
                $"  is64bit={Environment.Is64BitProcess}\n" +
                $"  ver={typeof(Plugin).Assembly.GetName().Version}\n");
        }
        catch { /* sentinel write is best-effort; never throw from cctor */ }

        try
        {
            AppDomain.CurrentDomain.AssemblyResolve += ResolvePluginAssembly;
            _resolverAttached = true;
        }
        catch
        {
            // Static cctor must never throw - the type would be marked
            // unusable for the lifetime of the AppDomain. Init() will
            // re-attempt the hook attachment as a fallback.
        }

        // Pre-load the bitness-matched WebView2Loader.dll. The
        // managed Microsoft.Web.WebView2.Core wrapper P/Invokes
        // "WebView2Loader.dll" with no path, so Windows' default
        // DLL search order kicks in: AppDomain.BaseDirectory (= QL-
        // Win's exe folder, where there is no WebView2Loader), then
        // PATH, then system dir - and never the plugin folder.
        // Loading the correct bitness explicitly here puts the DLL
        // in the process's loaded-module cache so when the managed
        // wrapper's P/Invoke fires later, Windows resolves
        // "WebView2Loader.dll" against the already-loaded module
        // instead of going through its search order.
        try { PreloadWebView2Loader(); } catch { /* best-effort */ }
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr LoadLibraryW(string lpFileName);

    /// Probe `runtimes/win-{x86|x64}/native/WebView2Loader.dll`
    /// inside the plugin folder and pin the matching DLL into the
    /// process. The path layout mirrors what
    /// Microsoft.Web.WebView2.Core would look for itself when it's
    /// shipped via NuGet for a .NET SDK consumer.
    private static void PreloadWebView2Loader()
    {
        var pluginDir = Path.GetDirectoryName(typeof(Plugin).Assembly.Location);
        if (string.IsNullOrEmpty(pluginDir)) return;

        var arch = IntPtr.Size == 8 ? "x64" : "x86";
        var candidates = new[]
        {
            Path.Combine(pluginDir, "runtimes", "win-" + arch, "native", "WebView2Loader.dll"),
            // Fallback to the flat-folder copy. For an x64 process
            // that file is x64 (which is what's bundled at the root
            // for 1.7.69-and-earlier install layouts). For an x86
            // process the flat fallback won't match - the
            // runtimes/win-x86/native/ path above MUST resolve.
            Path.Combine(pluginDir, "WebView2Loader.dll"),
        };
        foreach (var path in candidates)
        {
            if (!File.Exists(path)) continue;
            var handle = LoadLibraryW(path);
            if (handle != IntPtr.Zero) return;   // pinned; we're done
        }
    }

    /// QL-Win uses Priority to break ties when several plugins claim the
    /// same file. Higher wins. The bundled TextViewer plugin claims
    /// "any text-like file" with `IsText(path)` heuristics and Priority
    /// in the low single digits, so a Priority-5 PDB-handler-here lost
    /// to the text viewer in practice and the user saw the raw ATOM
    /// records instead of a 3D preview. Bump to 100 so we comfortably
    /// outrank the text-fallback chain for the extensions we claim.
    public int Priority => 100;

    public void Init()
    {
        // Init is the first sign of life QL-Win shows us — if it
        // lands in plugin.log we know QL-Win successfully discovered
        // our DLL, materialised the Plugin type via GetTypes(), and
        // dispatched via Activator.CreateInstance. If plugin.log
        // never appears the failure is in QL-Win's discovery loop,
        // before Init() is reached. The static cctor above is the
        // primary AssemblyResolve attach point precisely so the hook
        // is armed for that earlier discovery path; this log line
        // here is just a heartbeat confirming the late path also
        // worked.
        PluginLog.Info($"Plugin.Init v{typeof(Plugin).Assembly.GetName().Version} - " +
                       $"assembly={typeof(Plugin).Assembly.Location}");
        PluginLog.Info($"Plugin.Init - resolverAttached={_resolverAttached}");
    }

    /// AppDomain.AssemblyResolve callback. Returns the assembly if
    /// we can find a sibling DLL matching the requested name in the
    /// plugin's install directory; null otherwise (lets other
    /// resolvers / the default probing chain handle it).
    private static Assembly? ResolvePluginAssembly(object sender, ResolveEventArgs args)
    {
        try
        {
            var requested = new AssemblyName(args.Name);
            // Don't shadow resource sub-assemblies QL-Win or another
            // plugin might own (they end in ".resources"). Those are
            // localized and not something we ship.
            if (requested.Name == null ||
                requested.Name.EndsWith(".resources", StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }

            var pluginDir = Path.GetDirectoryName(typeof(Plugin).Assembly.Location);
            if (string.IsNullOrEmpty(pluginDir))
            {
                return null;
            }

            var candidate = Path.Combine(pluginDir, requested.Name + ".dll");
            if (!File.Exists(candidate))
            {
                return null;
            }

            // LoadFrom (not LoadFile) so the CLR caches the result
            // by codebase and a second resolve for the same
            // assembly hits the cache. Required for XAML's repeated
            // type lookups during a single MoleculePanel inflation.
            PluginLog.Info($"Resolved '{requested.Name}' -> {candidate}");
            return Assembly.LoadFrom(candidate);
        }
        catch (Exception ex)
        {
            // Never throw out of an AssemblyResolve handler - the
            // CLR treats a thrown exception as "couldn't resolve"
            // but also leaves the AppDomain in a fragile state.
            PluginLog.Exception($"ResolvePluginAssembly({args.Name}) threw", ex);
            return null;
        }
    }

    public bool CanHandle(string path)
    {
        if (string.IsNullOrEmpty(path) || Directory.Exists(path))
            return false;
        var ext = Path.GetExtension(path).ToLowerInvariant();
        var ok = SupportedExtensions.Contains(ext);
        // Log every CanHandle call so we can spot the case where
        // QL-Win consults us but doesn't pick us (e.g. another
        // plugin returned true at a higher priority).
        PluginLog.Info($"CanHandle({path}) ext='{ext}' -> {ok}");
        return ok;
    }

    public void Prepare(string path, ContextObject context)
    {
        PluginLog.Info($"Prepare({path}) - QL-Win is about to call View()");
        // Default preview window size. Was 960x720 in 1.7.66-1.7.73,
        // which dominated 1080p screens. 720x540 is roughly half the
        // viewport on a 1080p laptop - large enough to read atom
        // labels at default zoom, small enough that the QuickLook
        // popover doesn't feel like a window. Users can resize freely.
        context.PreferredSize = new Size(720, 540);
    }

    public void View(string path, ContextObject context)
    {
        PluginLog.Info($"View({path}) - building MoleculePanel");
        try
        {
            // Indirect through a NoInlining helper. This keeps the
            // direct reference to MoleculePanel out of View()'s IL
            // body proper, which means the JIT for View() doesn't
            // force MoleculePanel's metadata load until the helper
            // is actually entered. By that point the static cctor's
            // AssemblyResolve hook is already attached, so the WPF
            // inflation of <wv2:WebView2> resolves cleanly.
            var panel = CreateMoleculePanel(path, context);
            _panel = panel;
            context.ViewerContent = panel;
            context.Title = Path.GetFileName(path);
        }
        catch (Exception ex)
        {
            PluginLog.Exception("View() threw before handoff", ex);
            throw;
        }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static MoleculePanel CreateMoleculePanel(string path, ContextObject context)
    {
        var p = new MoleculePanel();
        // The panel turns IsBusy off itself once the WebView signals
        // that the navigation has committed.
        p.LoadFile(path, context);
        return p;
    }

    public void Cleanup()
    {
        PluginLog.Info("Cleanup");
        GC.SuppressFinalize(this);
        // _panel is typed `object?` to keep MoleculePanel out of
        // Plugin's type metadata; cast via the IDisposable interface
        // (System namespace, always available) so we don't pull
        // MoleculePanel back into scope here.
        if (_panel is IDisposable d) d.Dispose();
        _panel = null;
    }
}
