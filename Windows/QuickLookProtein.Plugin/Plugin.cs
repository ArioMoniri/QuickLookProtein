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
    /// same file. 0 = default; positive numbers win. We sit at 5 so we
    /// beat the built-in text/HTML viewers for .json / .top files (which
    /// they'd otherwise grab as plain text), without aggressively
    /// shadowing a user's higher-priority custom plugin.
    public int Priority => 5;

    public void Init()
    {
        // Nothing to pre-warm — WebView2 boots fast enough that doing
        // it eagerly here would just slow QL-Win's startup.
    }

    public bool CanHandle(string path)
    {
        if (string.IsNullOrEmpty(path) || Directory.Exists(path))
            return false;
        var ext = Path.GetExtension(path).ToLowerInvariant();
        return SupportedExtensions.Contains(ext);
    }

    public void Prepare(string path, ContextObject context)
    {
        // Same default size as the macOS preview window so the spacebar
        // experience feels consistent across platforms. Users can resize.
        context.PreferredSize = new Size(960, 720);
    }

    public void View(string path, ContextObject context)
    {
        _panel = new MoleculePanel();
        context.ViewerContent = _panel;
        context.Title = Path.GetFileName(path);
        // The panel turns IsBusy off itself once the WebView signals
        // the navigation has committed.
        _panel.LoadFile(path, context);
    }

    public void Cleanup()
    {
        GC.SuppressFinalize(this);
        _panel?.Dispose();
        _panel = null;
    }
}
