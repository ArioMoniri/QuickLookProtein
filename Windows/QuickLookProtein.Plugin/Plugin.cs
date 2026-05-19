// QuickLookProtein.Plugin — IViewer implementation for QL-Win/QuickLook.
//
// Lifecycle mirrors macOS's QLPreviewingController:
//   - CanHandle(path)  → "is this a file we render?"
//   - Prepare(path,…)  → set window size before content shows
//   - View(path,…)     → build the panel, kick off WebView2 load
//   - Cleanup()        → release the WebView2 instance

using QuickLook.Common.Plugin;
using System;
using System.IO;
using System.Linq;
using System.Reflection;
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

    private MoleculePanel? _panel;

    /// Set the first time Init() runs so the AssemblyResolve hook only
    /// attaches once even if QL-Win re-instantiates the IViewer (some
    /// QL-Win configurations construct a fresh viewer per file).
    private static bool _resolverAttached;

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
        // Init is the first sign of life - if it's in the log, we
        // know QL-Win discovered our DLL, loaded it, instantiated
        // the IViewer class, and dispatched. If it's missing, the
        // plugin failed earlier - usually a TypeLoadException from
        // a missing dependency, which QL-Win logs to its own
        // App.log at %LocalAppData%\QuickLook\App.log.
        PluginLog.Info($"Plugin.Init - assembly={typeof(Plugin).Assembly.Location}");

        // Plugin-local AssemblyResolve hook. QL-Win loads our DLL
        // via Assembly.LoadFile(...), which means the CLR's standard
        // probing paths (AppDomain.BaseDirectory + GAC) do NOT
        // include the plugin folder. When QL-Win calls View() and
        // MoleculePanel is instantiated, its XAML references
        //   xmlns:wv2="clr-namespace:Microsoft.Web.WebView2.Wpf;
        //              assembly=Microsoft.Web.WebView2.Wpf"
        // and the XAML parser asks the CLR to resolve that
        // assembly. With no resolver pointed at our folder, the load
        // fails -> XamlParseException -> QL-Win silently drops the
        // plugin and falls back to its built-in text viewer (which
        // is what the user sees: raw ATOM lines in Notepad-style
        // rendering instead of the 3D preview).
        //
        // Attach a handler that probes the plugin's *own* directory
        // (%LocalAppData%\QuickLook\plugins\QuickLookProtein\) for
        // the requested assembly. WebView2.Core / .Wpf / .WinForms
        // and any future transitive dep ship alongside the plugin
        // DLL there, so a directory-local search resolves all of
        // them in one go.
        if (!_resolverAttached)
        {
            AppDomain.CurrentDomain.AssemblyResolve += ResolvePluginAssembly;
            _resolverAttached = true;
            PluginLog.Info("Plugin.Init - AssemblyResolve handler attached");
        }
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
        // Same default size as the macOS preview window so the spacebar
        // experience feels consistent across platforms. Users can resize.
        context.PreferredSize = new Size(960, 720);
    }

    public void View(string path, ContextObject context)
    {
        PluginLog.Info($"View({path}) - building MoleculePanel");
        try
        {
            _panel = new MoleculePanel();
            context.ViewerContent = _panel;
            context.Title = Path.GetFileName(path);
            // The panel turns IsBusy off itself once the WebView signals
            // the navigation has committed.
            _panel.LoadFile(path, context);
        }
        catch (Exception ex)
        {
            PluginLog.Exception("View() threw before handoff", ex);
            throw;
        }
    }

    public void Cleanup()
    {
        PluginLog.Info("Cleanup");
        GC.SuppressFinalize(this);
        _panel?.Dispose();
        _panel = null;
    }
}
