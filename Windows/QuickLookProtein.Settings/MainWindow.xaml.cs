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

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();
}
