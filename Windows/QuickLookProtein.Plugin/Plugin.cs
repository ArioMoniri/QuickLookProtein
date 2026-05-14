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
