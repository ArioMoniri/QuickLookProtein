// Settings UI code-behind. Populates the combos from enum values on
// load, reads current values from the SettingsStore registry hive,
// and writes back on every change. No "Save" button - settings
// persist on each interaction (matches the macOS UX).

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using QuickLookProtein.Shared;

namespace QuickLookProtein.Settings;

public partial class MainWindow : Window
{
    // Set to true while we're populating combos from disk so the
    // SelectionChanged handlers don't immediately write back what
    // they just read. WPF doesn't have a built-in "suspend events"
    // flag for ComboBox so we gate this manually.
    private bool _suppressWrites = true;

    public MainWindow()
    {
        InitializeComponent();
        Loaded += MainWindow_Loaded;
    }

    private void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        SetVersionLabel();
        PopulateAllCombos();
        LoadCurrentSettings();
        WireChangeHandlers();
        _suppressWrites = false;
        // Kick off the WebView2 init + first sample render. Done after
        // settings are loaded so the first render honours whatever
        // preferences are currently set.
        _ = InitPreviewAsync();
    }

    private void SetVersionLabel()
    {
        var asm = Assembly.GetExecutingAssembly();
        var v = asm.GetName().Version;
        VersionLabel.Text = $"Version {v?.Major}.{v?.Minor}.{v?.Build}";
    }

    private void PopulateAllCombos()
    {
        // Atom-style combos all share the same set of options.
        var styleCombos = new[]
        {
            PdbStyleCombo, CifStyleCombo, SdfStyleCombo, MolStyleCombo,
            Mol2StyleCombo, XyzStyleCombo, GroStyleCombo, CubeStyleCombo,
            PqrStyleCombo, VaspStyleCombo, CdjsonStyleCombo, MmtfStyleCombo,
        };
        foreach (var c in styleCombos)
        {
            foreach (var s in Enum.GetValues(typeof(AtomStyle)))
                c.Items.Add(s);
        }

        foreach (var s in Enum.GetValues(typeof(ColorScheme)))
            ColorSchemeCombo.Items.Add(s);
        foreach (var s in Enum.GetValues(typeof(RotationSpeed)))
            RotationCombo.Items.Add(s);
        foreach (var s in Enum.GetValues(typeof(DefaultZoom)))
            ZoomCombo.Items.Add(s);
    }

    private void LoadCurrentSettings()
    {
        PdbStyleCombo.SelectedItem    = SettingsStore.GetAtomStylePDB();
        CifStyleCombo.SelectedItem    = SettingsStore.GetAtomStyleCIF();
        SdfStyleCombo.SelectedItem    = SettingsStore.GetAtomStyleSDF();
        MolStyleCombo.SelectedItem    = SettingsStore.GetAtomStyleMOL();
        Mol2StyleCombo.SelectedItem   = SettingsStore.GetAtomStyleMOL2();
        XyzStyleCombo.SelectedItem    = SettingsStore.GetAtomStyleXYZ();
        GroStyleCombo.SelectedItem    = SettingsStore.GetAtomStyleGRO();
        CubeStyleCombo.SelectedItem   = SettingsStore.GetAtomStyleCUBE();
        PqrStyleCombo.SelectedItem    = SettingsStore.GetAtomStylePQR();
        VaspStyleCombo.SelectedItem   = SettingsStore.GetAtomStyleVASP();
        CdjsonStyleCombo.SelectedItem = SettingsStore.GetAtomStyleCDJSON();
        MmtfStyleCombo.SelectedItem   = SettingsStore.GetAtomStyleMMTF();

        ColorSchemeCombo.SelectedItem = SettingsStore.GetColorScheme();
        RotationCombo.SelectedItem    = SettingsStore.GetRotationSpeed();
        ZoomCombo.SelectedItem        = SettingsStore.GetDefaultZoom();

        AutoStyleHeteroCheck.IsChecked = SettingsStore.GetAutoStyleHetero();
        ShowSurfaceCheck.IsChecked     = SettingsStore.GetShowSurface();
        HideHydrogensCheck.IsChecked   = SettingsStore.GetHideHydrogens();
        ShowUnitCellCheck.IsChecked    = SettingsStore.GetShowUnitCell();
        ShowInfoOverlayCheck.IsChecked = SettingsStore.GetShowInfoOverlay();

        UpdateBgSwatchFromStore();
    }

    private void WireChangeHandlers()
    {
        PdbStyleCombo.SelectionChanged    += (_, _) => Save(() => SettingsStore.SetAtomStylePDB((AtomStyle)PdbStyleCombo.SelectedItem));
        CifStyleCombo.SelectionChanged    += (_, _) => Save(() => SettingsStore.SetAtomStyleCIF((AtomStyle)CifStyleCombo.SelectedItem));
        SdfStyleCombo.SelectionChanged    += (_, _) => Save(() => SettingsStore.SetAtomStyleSDF((AtomStyle)SdfStyleCombo.SelectedItem));
        MolStyleCombo.SelectionChanged    += (_, _) => Save(() => SettingsStore.SetAtomStyleMOL((AtomStyle)MolStyleCombo.SelectedItem));
        Mol2StyleCombo.SelectionChanged   += (_, _) => Save(() => SettingsStore.SetAtomStyleMOL2((AtomStyle)Mol2StyleCombo.SelectedItem));
        XyzStyleCombo.SelectionChanged    += (_, _) => Save(() => SettingsStore.SetAtomStyleXYZ((AtomStyle)XyzStyleCombo.SelectedItem));
        GroStyleCombo.SelectionChanged    += (_, _) => Save(() => SettingsStore.SetAtomStyleGRO((AtomStyle)GroStyleCombo.SelectedItem));
        CubeStyleCombo.SelectionChanged   += (_, _) => Save(() => SettingsStore.SetAtomStyleCUBE((AtomStyle)CubeStyleCombo.SelectedItem));
        PqrStyleCombo.SelectionChanged    += (_, _) => Save(() => SettingsStore.SetAtomStylePQR((AtomStyle)PqrStyleCombo.SelectedItem));
        VaspStyleCombo.SelectionChanged   += (_, _) => Save(() => SettingsStore.SetAtomStyleVASP((AtomStyle)VaspStyleCombo.SelectedItem));
        CdjsonStyleCombo.SelectionChanged += (_, _) => Save(() => SettingsStore.SetAtomStyleCDJSON((AtomStyle)CdjsonStyleCombo.SelectedItem));
        MmtfStyleCombo.SelectionChanged   += (_, _) => Save(() => SettingsStore.SetAtomStyleMMTF((AtomStyle)MmtfStyleCombo.SelectedItem));

        ColorSchemeCombo.SelectionChanged += (_, _) => Save(() => SettingsStore.SetColorScheme((ColorScheme)ColorSchemeCombo.SelectedItem));
        RotationCombo.SelectionChanged    += (_, _) => Save(() => SettingsStore.SetRotationSpeed((RotationSpeed)RotationCombo.SelectedItem));
        ZoomCombo.SelectionChanged        += (_, _) => Save(() => SettingsStore.SetDefaultZoom((DefaultZoom)ZoomCombo.SelectedItem));

        AutoStyleHeteroCheck.Click += (_, _) => Save(() => SettingsStore.SetAutoStyleHetero(AutoStyleHeteroCheck.IsChecked == true));
        ShowSurfaceCheck.Click     += (_, _) => Save(() => SettingsStore.SetShowSurface(ShowSurfaceCheck.IsChecked == true));
        HideHydrogensCheck.Click   += (_, _) => Save(() => SettingsStore.SetHideHydrogens(HideHydrogensCheck.IsChecked == true));
        ShowUnitCellCheck.Click    += (_, _) => Save(() => SettingsStore.SetShowUnitCell(ShowUnitCellCheck.IsChecked == true));
        ShowInfoOverlayCheck.Click += (_, _) => Save(() => SettingsStore.SetShowInfoOverlay(ShowInfoOverlayCheck.IsChecked == true));
    }

    private void Save(Action action)
    {
        if (_suppressWrites) return;
        try
        {
            action();
            StatusLabel.Text = $"Saved at {DateTime.Now:HH:mm:ss}.";
        }
        catch (Exception ex)
        {
            StatusLabel.Text = "Save failed: " + ex.Message;
        }
    }

    // ---- Background color picker -------------------------------------

    private void BgPickButton_Click(object sender, RoutedEventArgs e)
    {
        var (r, g, b, a) = SettingsStore.GetBgColor();
        // Use WinForms ColorDialog - WPF doesn't ship a built-in
        // color picker on net472 and we'd rather not pull in
        // ColorPicker NuGet packages.
        using var dlg = new System.Windows.Forms.ColorDialog
        {
            FullOpen = true,
            AnyColor = true,
            Color = System.Drawing.Color.FromArgb(
                (int)(a * 255), (int)(r * 255), (int)(g * 255), (int)(b * 255)),
        };
        if (dlg.ShowDialog() != System.Windows.Forms.DialogResult.OK) return;
        var c = dlg.Color;
        SettingsStore.SetBgColor(c.R / 255.0, c.G / 255.0, c.B / 255.0, 1.0);
        UpdateBgSwatchFromStore();
        StatusLabel.Text = $"Saved at {DateTime.Now:HH:mm:ss}.";
    }

    private void BgResetButton_Click(object sender, RoutedEventArgs e)
    {
        SettingsStore.SetBgColor(0, 0, 0, 0);
        UpdateBgSwatchFromStore();
        StatusLabel.Text = $"Transparent background applied.";
    }

    private void UpdateBgSwatchFromStore()
    {
        var (r, g, b, a) = SettingsStore.GetBgColor();
        BgSwatch.Background = new SolidColorBrush(
            Color.FromArgb(
                (byte)Math.Round(a * 255),
                (byte)Math.Round(r * 255),
                (byte)Math.Round(g * 255),
                (byte)Math.Round(b * 255)));
    }

    // ---- About / footer buttons --------------------------------------

    private void GithubButton_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "https://github.com/ArioMoniri/QuickLookProtein",
                UseShellExecute = true,
            });
        }
        catch { /* offline / no default browser; nothing useful to do */ }
    }

    private void OpenPluginFolderButton_Click(object sender, RoutedEventArgs e)
    {
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "QuickLook", "plugins", "QuickLookProtein");
        try
        {
            if (Directory.Exists(dir))
                Process.Start(new ProcessStartInfo { FileName = dir, UseShellExecute = true });
            else
                MessageBox.Show($"Plugin folder not found at:\n{dir}\n\nReinstall QuickLookProtein-Setup.exe if you've removed it.",
                                "QuickLookProtein", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch { }
    }

    // ---- Diagnostics card --------------------------------------------

    private void OpenPluginLog_Click(object sender, RoutedEventArgs e)
    {
        var log = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "QuickLookProtein", "plugin.log");
        if (!File.Exists(log))
        {
            MessageBox.Show(
                "No plugin log yet. Open a .pdb / .cif / etc. with Space-bar in Explorer once - the plugin writes here on every preview attempt.\n\nExpected path:\n" + log,
                "QuickLookProtein", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        try { Process.Start(new ProcessStartInfo { FileName = log, UseShellExecute = true }); }
        catch (Exception ex)
        {
            MessageBox.Show("Could not open log: " + ex.Message,
                            "QuickLookProtein", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void OpenQuickLookLog_Click(object sender, RoutedEventArgs e)
    {
        // QL-Win's own log lives at %LocalAppData%\QuickLook\App.log.
        // If our plugin failed to load entirely (TypeLoadException at
        // discovery time), QL-Win's log is the only place it shows up
        // - our plugin.log is empty because Init() was never called.
        var log = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "QuickLook", "App.log");
        if (!File.Exists(log))
        {
            MessageBox.Show(
                "QuickLook log not found at:\n" + log + "\n\nIs QuickLook actually installed?",
                "QuickLookProtein", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        try { Process.Start(new ProcessStartInfo { FileName = log, UseShellExecute = true }); }
        catch (Exception ex)
        {
            MessageBox.Show("Could not open log: " + ex.Message,
                            "QuickLookProtein", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void RestartQuickLookTray_Click(object sender, RoutedEventArgs e)
    {
        // Politely-then-firmly restart QuickLook so the user doesn't
        // have to dig through the tray themselves. CloseMainWindow
        // first (no elevation needed for same-integrity case), wait,
        // then re-launch from the standard install location.
        foreach (var p in Process.GetProcessesByName("QuickLook"))
        {
            try { p.CloseMainWindow(); } catch { }
        }
        System.Threading.Thread.Sleep(1000);
        foreach (var p in Process.GetProcessesByName("QuickLook"))
        {
            try { p.Kill(); } catch { }
        }

        var candidates = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                         "Programs", "QuickLook", "QuickLook.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                         "QuickLook", "QuickLook.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
                         "QuickLook", "QuickLook.exe"),
        };
        foreach (var p in candidates)
        {
            if (File.Exists(p))
            {
                try
                {
                    Process.Start(new ProcessStartInfo { FileName = p, UseShellExecute = true });
                    StatusLabel.Text = "QuickLook restarted.";
                    return;
                }
                catch { }
            }
        }
        MessageBox.Show("Could not find QuickLook.exe. Launch it manually from the Start Menu.",
                        "QuickLookProtein", MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    // ---- Live preview tiles -------------------------------------------
    //
    // Mirrors the macOS app's preview tile grid: ten file formats,
    // each with a bundled sample, rendered inside a WebView2 using
    // the same viewer.html + 3Dmol.js the Space-bar plugin uses.
    //
    // The samples live in a SampleAssets\ subfolder next to the
    // .exe (the csproj's <Content> entries copy them at build time).
    // We map that folder to a virtual host so the viewer.html can
    // reach 3Dmol.js with a relative <script src="3Dmol.js"> tag
    // exactly the way it does in the .qlplugin install.

    private const string PreviewVirtualHost = "qlpsettings.local";

    private static readonly (string Label, string Format, string SampleFile, string Atomstyle, string Caption)[] Samples = new[]
    {
        ("PDB",    "pdb",    "sample.pdb",  "cartoon", "XoxF protein (6OC6)"),
        ("CIF",    "cif",    "sample.cif",  "stick",   "Bioinspired Fe complex (1565673)"),
        ("SDF",    "sdf",    "sample.sdf",  "stick",   "Pyrroloquinoline quinone"),
        ("MOL",    "sdf",    "sample.mol",  "stick",   "Methane (V2000)"),
        ("MOL2",   "mol2",   "sample.mol2", "stick",   "Caffeine"),
        ("XYZ",    "xyz",    "sample.xyz",  "stick",   "Benzene"),
        ("GRO",    "gro",    "sample.gro",  "stick",   "Water (GROMACS)"),
        ("CUBE",   "cube",   "sample.cube", "stick",   "Water (Gaussian Cube)"),
        ("PQR",    "pqr",    "sample.pqr",  "stick",   "Methane (charges)"),
        ("VASP",   "vasp",   "sample.vasp", "sphere",  "Diamond cubic carbon"),
    };

    private int _currentSampleIndex;
    private string? _sampleAssetsDir;
    private string? _viewerTemplate;

    private async System.Threading.Tasks.Task InitPreviewAsync()
    {
        var exeDir = Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
        if (exeDir == null) return;
        _sampleAssetsDir = Path.Combine(exeDir, "SampleAssets");
        if (!Directory.Exists(_sampleAssetsDir))
        {
            PreviewCaption.Text = "Sample files not bundled with this build.";
            return;
        }
        var template = Path.Combine(_sampleAssetsDir, "viewer.html");
        if (!File.Exists(template))
        {
            PreviewCaption.Text = "viewer.html missing from sample assets.";
            return;
        }
        _viewerTemplate = await System.Threading.Tasks.Task.Run(() => File.ReadAllText(template));

        // Format tile buttons.
        for (int i = 0; i < Samples.Length; i++)
        {
            int idx = i;
            var btn = new Button
            {
                Content = Samples[i].Label,
                Margin  = new Thickness(0, 0, 6, 6),
                Padding = new Thickness(12, 4, 12, 4),
                Cursor  = System.Windows.Input.Cursors.Hand,
            };
            btn.Click += (_, _) => { _currentSampleIndex = idx; _ = LoadCurrentSampleAsync(); };
            FormatTilesWrap.Children.Add(btn);
        }

        // Per-user WebView2 data folder so we don't fight with other
        // WebView2-hosting apps for the default UDF.
        var userDataFolder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "QuickLookProtein", "WebView2-Settings");
        Directory.CreateDirectory(userDataFolder);
        var env = await Microsoft.Web.WebView2.Core.CoreWebView2Environment.CreateAsync(
            browserExecutableFolder: null, userDataFolder: userDataFolder);
        await PreviewWebView.EnsureCoreWebView2Async(env);
        PreviewWebView.CoreWebView2.SetVirtualHostNameToFolderMapping(
            PreviewVirtualHost, _sampleAssetsDir,
            Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind.Allow);

        await LoadCurrentSampleAsync();
    }

    private async System.Threading.Tasks.Task LoadCurrentSampleAsync()
    {
        if (_viewerTemplate == null || _sampleAssetsDir == null) return;
        if (_currentSampleIndex < 0 || _currentSampleIndex >= Samples.Length) return;
        var s = Samples[_currentSampleIndex];
        var samplePath = Path.Combine(_sampleAssetsDir, s.SampleFile);
        if (!File.Exists(samplePath))
        {
            PreviewCaption.Text = $"{s.Label}: sample file not bundled ({s.SampleFile}).";
            return;
        }
        string moleculeData;
        try
        {
            moleculeData = await System.Threading.Tasks.Task.Run(() => File.ReadAllText(samplePath));
        }
        catch (Exception ex)
        {
            PreviewCaption.Text = $"{s.Label}: could not read sample - {ex.Message}";
            return;
        }
        var html = BuildPreviewHtml(_viewerTemplate, s.Format, s.SampleFile, moleculeData);
        // Same trick as the plugin: rewrite the bare <script src="3Dmol.js">
        // tag so it resolves against the WebView2 virtual host. The
        // template ships with the relative tag because the macOS path
        // uses file:// baseURL where it resolves naturally.
        html = html.Replace("<script src=\"3Dmol.js\">",
                            $"<script src=\"https://{PreviewVirtualHost}/3Dmol.js\">");
        PreviewWebView.NavigateToString(html);
        PreviewCaption.Text = $"{s.Label} - {s.Caption}";
    }

    private void ReloadPreview_Click(object sender, RoutedEventArgs e)
    {
        _ = LoadCurrentSampleAsync();
    }

    /// <summary>Mirror of MoleculePanel.FillTemplate so the live
    /// preview honours the same Settings hive the plugin reads. Kept
    /// in this file rather than calling into the plugin DLL because
    /// the Settings app shouldn't take a runtime dependency on a
    /// COM-loaded plugin assembly.</summary>
    private static string BuildPreviewHtml(string template, string format, string fileName, string moleculeData)
    {
        var ext = Path.GetExtension(fileName).TrimStart('.').ToLowerInvariant();
        var atomStyle = QuickLookProtein.Shared.SettingsStore.GetAtomStyle(ext).ToString().ToLowerInvariant();
        var colorScheme = QuickLookProtein.Shared.SettingsStore.GetColorScheme().ToString().ToLowerInvariant();
        var rotation = ResolveRotation(QuickLookProtein.Shared.SettingsStore.GetRotationSpeed());
        var zoomFactor = ResolveZoom(QuickLookProtein.Shared.SettingsStore.GetDefaultZoom());
        var zoomIsAuto = QuickLookProtein.Shared.SettingsStore.GetDefaultZoom() == QuickLookProtein.Shared.DefaultZoom.Auto;
        var (br, bg, bb, ba) = QuickLookProtein.Shared.SettingsStore.GetBgColor();
        var bgHex = $"{(int)Math.Round(br*255):X2}{(int)Math.Round(bg*255):X2}{(int)Math.Round(bb*255):X2}";

        var safeData = SanitizeForScriptBlock(moleculeData);
        var safeName = System.Net.WebUtility.HtmlEncode(fileName);

        return template
            .Replace("{ATOM_STYLE}",        atomStyle)
            .Replace("{COLOR_SCHEME}",      colorScheme)
            .Replace("{BG_COLOR}",          bgHex)
            .Replace("{BG_ALPHA}",          ba.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture))
            .Replace("{ROTATION_SPEED}",    rotation)
            .Replace("{DATA_FORMAT}",       format)
            .Replace("{AUTO_STYLE_HETERO}", QuickLookProtein.Shared.SettingsStore.GetAutoStyleHetero() ? "true" : "false")
            .Replace("{SHOW_SURFACE}",      QuickLookProtein.Shared.SettingsStore.GetShowSurface()    ? "true" : "false")
            .Replace("{HIDE_H}",            QuickLookProtein.Shared.SettingsStore.GetHideHydrogens()  ? "true" : "false")
            .Replace("{SHOW_UNIT_CELL}",    QuickLookProtein.Shared.SettingsStore.GetShowUnitCell()   ? "true" : "false")
            .Replace("{SHOW_INFO}",         QuickLookProtein.Shared.SettingsStore.GetShowInfoOverlay()? "true" : "false")
            .Replace("{INFO_FILE_NAME}",         "true")
            .Replace("{INFO_ATOM_COUNT}",        "true")
            .Replace("{INFO_CHAIN_COUNT}",       "true")
            .Replace("{INFO_FORMAT}",            "true")
            .Replace("{INFO_RES_COUNT}",         "false")
            .Replace("{INFO_ELEMENT_BREAKDOWN}", "false")
            .Replace("{INFO_MOL_WEIGHT}",        "false")
            .Replace("{INFO_BOND_COUNT}",        "false")
            .Replace("{INFO_PDB_TITLE}",         "false")
            .Replace("{PDB_TITLE}",         "")
            .Replace("{FILE_NAME}",         safeName)
            .Replace("{ZOOM_FACTOR}",       zoomFactor)
            .Replace("{ZOOM_IS_AUTO}",      zoomIsAuto ? "true" : "false")
            .Replace("{THUMBNAIL_MODE}",    "false")
            .Replace("{MOL_DATA}",          safeData);
    }

    private static string ResolveRotation(QuickLookProtein.Shared.RotationSpeed s) => s switch
    {
        QuickLookProtein.Shared.RotationSpeed.Off    => "0",
        QuickLookProtein.Shared.RotationSpeed.Slow   => "1",
        QuickLookProtein.Shared.RotationSpeed.Medium => "2",
        QuickLookProtein.Shared.RotationSpeed.Fast   => "3",
        _ => "2",
    };

    private static string ResolveZoom(QuickLookProtein.Shared.DefaultZoom z) => z switch
    {
        QuickLookProtein.Shared.DefaultZoom.Tight  => "1.4",
        QuickLookProtein.Shared.DefaultZoom.Normal => "1.0",
        QuickLookProtein.Shared.DefaultZoom.Wide   => "0.7",
        _ => "1.0",
    };

    private static string SanitizeForScriptBlock(string s)
    {
        if (string.IsNullOrEmpty(s)) return "";
        var sb = new System.Text.StringBuilder(s);
        if (sb.Length > 0 && sb[0] == '﻿') sb.Remove(0, 1);
        sb.Replace("\0", "");
        sb.Replace("</script", @"<\/script");
        sb.Replace("<!--",    @"<\!--");
        sb.Replace("-->",     @"--\>");
        return sb.ToString();
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();
}
