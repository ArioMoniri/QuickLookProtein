// Settings UI code-behind. Populates the combos from enum values on
// load, reads current values from the SettingsStore registry hive,
// and writes back on every change. No "Save" button - settings
// persist on each interaction (matches the macOS UX).

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;
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
        // Each step is wrapped so a fault in (say) registry I/O or
        // the WebView2 bootstrap doesn't tear down the whole window
        // before the user gets to see *any* settings. The status bar
        // surfaces what failed; the rest of the UI stays usable.
        try { SetVersionLabel();    } catch (Exception ex) { ReportStartupError("version label", ex); }
        try { PopulateAllCombos();  } catch (Exception ex) { ReportStartupError("populating options", ex); }
        try { LoadCurrentSettings();} catch (Exception ex) { ReportStartupError("loading saved settings", ex); }
        try { WireChangeHandlers(); } catch (Exception ex) { ReportStartupError("wiring change handlers", ex); }
        _suppressWrites = false;

        // WebView2 bootstrap is the most likely source of startup
        // failure (Evergreen Runtime missing on stripped-down VMs,
        // or a corporate policy blocking the user-data folder).
        // Treat it as best-effort: if it fails, the settings UI
        // still works, the preview pane just shows a caption.
        _ = InitPreviewAsync().ContinueWith(t =>
        {
            if (t.IsFaulted)
            {
                Dispatcher.Invoke(() =>
                    ReportStartupError("live-preview WebView2", t.Exception?.GetBaseException()));
            }
        }, System.Threading.Tasks.TaskScheduler.Default);

        // Auto-check at launch (opt-in). Fire-and-forget on a
        // worker so a slow network never blocks the UI showing.
        if (UpdateChecker.AutoCheckEnabled)
        {
            _ = RunUpdateCheckAsync(showNoUpdateMessage: false);
        }
    }

    private void ReportStartupError(string stage, Exception? ex)
    {
        var msg = ex?.Message ?? "(no detail)";
        StatusLabel.Text = $"Startup issue in {stage}: {msg}";
        PreviewCaption.Text = $"Live preview unavailable: {msg}";
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
        ShowInfoOverlayCheck.IsChecked        = SettingsStore.GetShowInfoOverlay();
        ShowControlsInPreviewCheck.IsChecked  = SettingsStore.GetShowControlsInPreview();
        OutlineShadingCheck.IsChecked         = SettingsStore.GetOutlineShading();
        AmbientOcclusionCheck.IsChecked       = SettingsStore.GetAmbientOcclusion();
        AutoOrientCheck.IsChecked             = SettingsStore.GetAutoOrient();
        CubeIsosurfaceCheck.IsChecked         = SettingsStore.GetCubeIsosurface();
        BioAssemblyCheck.IsChecked            = SettingsStore.GetBioAssembly();
        CryoEMRenderCheck.IsChecked           = SettingsStore.GetCryoEMRender();
        ShowShareButtonCheck.IsChecked        = SettingsStore.GetShowShareButton();
        CtlShowStickCheck.IsChecked    = SettingsStore.GetCtlShowStick();
        CtlShowLineCheck.IsChecked     = SettingsStore.GetCtlShowLine();
        CtlShowSphereCheck.IsChecked   = SettingsStore.GetCtlShowSphere();
        CtlShowCartoonCheck.IsChecked  = SettingsStore.GetCtlShowCartoon();
        CtlShowSurfaceCheck.IsChecked  = SettingsStore.GetCtlShowSurface();
        CtlShowColorSSCheck.IsChecked  = SettingsStore.GetCtlShowColorSS();
        CtlShowLabelCACheck.IsChecked  = SettingsStore.GetCtlShowLabelCA();
        CtlShowRecenterCheck.IsChecked = SettingsStore.GetCtlShowRecenter();

        // Launch-at-startup checkbox reflects current HKCU\...\Run
        // state.  Reads at load time so the checkbox is correct
        // even if QL-Win's own tray menu (or another tool) flipped
        // the registry between Settings-app sessions.
        LaunchAtStartupCheck.IsChecked = IsLaunchAtStartupEnabled();

        // Updates card (1.7.77+). Show the current installed
        // version unconditionally; auto-check at launch is opt-in
        // (off by default for the first release - users have to
        // tick the box to enable it).
        var v = UpdateChecker.CurrentVersion;
        UpdateStatusLabel.Text =
            $"Installed version: {v.Major}.{v.Minor}.{v.Build}  (build {v})";
        AutoCheckUpdatesCheck.IsChecked = UpdateChecker.AutoCheckEnabled;

        // Preview window size — populate slider + text box. The
        // text-box-changed handler updates the slider and vice versa
        // (both wired in WireChangeHandlers below).
        var pw = SettingsStore.GetPreviewWidth();
        var ph = SettingsStore.GetPreviewHeight();
        PreviewWidthSlider.Value = pw;
        PreviewWidthBox.Text     = pw.ToString(System.Globalization.CultureInfo.InvariantCulture);
        PreviewHeightSlider.Value = ph;
        PreviewHeightBox.Text     = ph.ToString(System.Globalization.CultureInfo.InvariantCulture);

        InfoFileNameCheck.IsChecked         = SettingsStore.GetInfoShowFileName();
        InfoAtomCountCheck.IsChecked        = SettingsStore.GetInfoShowAtomCount();
        InfoChainCountCheck.IsChecked       = SettingsStore.GetInfoShowChainCount();
        InfoResidueCountCheck.IsChecked     = SettingsStore.GetInfoShowResidueCount();
        InfoElementBreakdownCheck.IsChecked = SettingsStore.GetInfoShowElementBreakdown();
        InfoMolWeightCheck.IsChecked        = SettingsStore.GetInfoShowMolWeight();
        InfoBondCountCheck.IsChecked        = SettingsStore.GetInfoShowBondCount();
        InfoPDBTitleCheck.IsChecked         = SettingsStore.GetInfoShowPDBTitle();
        InfoFormatCheck.IsChecked           = SettingsStore.GetInfoShowFormat();

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
        ShowInfoOverlayCheck.Click        += (_, _) => Save(() => SettingsStore.SetShowInfoOverlay(ShowInfoOverlayCheck.IsChecked == true));
        ShowControlsInPreviewCheck.Click  += (_, _) => Save(() => SettingsStore.SetShowControlsInPreview(ShowControlsInPreviewCheck.IsChecked == true));
        OutlineShadingCheck.Click         += (_, _) => Save(() => SettingsStore.SetOutlineShading(OutlineShadingCheck.IsChecked == true));
        AmbientOcclusionCheck.Click       += (_, _) => Save(() => SettingsStore.SetAmbientOcclusion(AmbientOcclusionCheck.IsChecked == true));
        AutoOrientCheck.Click             += (_, _) => Save(() => SettingsStore.SetAutoOrient(AutoOrientCheck.IsChecked == true));
        CubeIsosurfaceCheck.Click         += (_, _) => Save(() => SettingsStore.SetCubeIsosurface(CubeIsosurfaceCheck.IsChecked == true));
        BioAssemblyCheck.Click            += (_, _) => Save(() => SettingsStore.SetBioAssembly(BioAssemblyCheck.IsChecked == true));
        CryoEMRenderCheck.Click           += (_, _) => Save(() => SettingsStore.SetCryoEMRender(CryoEMRenderCheck.IsChecked == true));
        ShowShareButtonCheck.Click        += (_, _) => Save(() => SettingsStore.SetShowShareButton(ShowShareButtonCheck.IsChecked == true));
        CtlShowStickCheck.Click    += (_, _) => Save(() => SettingsStore.SetCtlShowStick(CtlShowStickCheck.IsChecked == true));
        CtlShowLineCheck.Click     += (_, _) => Save(() => SettingsStore.SetCtlShowLine(CtlShowLineCheck.IsChecked == true));
        CtlShowSphereCheck.Click   += (_, _) => Save(() => SettingsStore.SetCtlShowSphere(CtlShowSphereCheck.IsChecked == true));
        CtlShowCartoonCheck.Click  += (_, _) => Save(() => SettingsStore.SetCtlShowCartoon(CtlShowCartoonCheck.IsChecked == true));
        CtlShowSurfaceCheck.Click  += (_, _) => Save(() => SettingsStore.SetCtlShowSurface(CtlShowSurfaceCheck.IsChecked == true));
        CtlShowColorSSCheck.Click  += (_, _) => Save(() => SettingsStore.SetCtlShowColorSS(CtlShowColorSSCheck.IsChecked == true));
        CtlShowLabelCACheck.Click  += (_, _) => Save(() => SettingsStore.SetCtlShowLabelCA(CtlShowLabelCACheck.IsChecked == true));
        CtlShowRecenterCheck.Click += (_, _) => Save(() => SettingsStore.SetCtlShowRecenter(CtlShowRecenterCheck.IsChecked == true));

        InfoFileNameCheck.Click         += (_, _) => Save(() => SettingsStore.SetInfoShowFileName(InfoFileNameCheck.IsChecked == true));
        InfoAtomCountCheck.Click        += (_, _) => Save(() => SettingsStore.SetInfoShowAtomCount(InfoAtomCountCheck.IsChecked == true));
        InfoChainCountCheck.Click       += (_, _) => Save(() => SettingsStore.SetInfoShowChainCount(InfoChainCountCheck.IsChecked == true));
        InfoResidueCountCheck.Click     += (_, _) => Save(() => SettingsStore.SetInfoShowResidueCount(InfoResidueCountCheck.IsChecked == true));
        InfoElementBreakdownCheck.Click += (_, _) => Save(() => SettingsStore.SetInfoShowElementBreakdown(InfoElementBreakdownCheck.IsChecked == true));
        InfoMolWeightCheck.Click        += (_, _) => Save(() => SettingsStore.SetInfoShowMolWeight(InfoMolWeightCheck.IsChecked == true));
        InfoBondCountCheck.Click        += (_, _) => Save(() => SettingsStore.SetInfoShowBondCount(InfoBondCountCheck.IsChecked == true));
        InfoPDBTitleCheck.Click         += (_, _) => Save(() => SettingsStore.SetInfoShowPDBTitle(InfoPDBTitleCheck.IsChecked == true));
        InfoFormatCheck.Click           += (_, _) => Save(() => SettingsStore.SetInfoShowFormat(InfoFormatCheck.IsChecked == true));

        AutoCheckUpdatesCheck.Click += (_, _) =>
        {
            if (_suppressWrites) return;
            UpdateChecker.AutoCheckEnabled = AutoCheckUpdatesCheck.IsChecked == true;
            StatusLabel.Text = AutoCheckUpdatesCheck.IsChecked == true
                ? "Auto-check enabled. We'll check GitHub each time Settings opens."
                : "Auto-check disabled. Use 'Check for updates' to check manually.";
        };

        LaunchAtStartupCheck.Click += (_, _) =>
        {
            if (_suppressWrites) return;
            try
            {
                SetLaunchAtStartup(LaunchAtStartupCheck.IsChecked == true);
                StatusLabel.Text = LaunchAtStartupCheck.IsChecked == true
                    ? "QuickLook will launch at sign-in."
                    : "QuickLook will NOT launch at sign-in. Start it manually after each boot.";
            }
            catch (Exception ex)
            {
                StatusLabel.Text = "Failed to update startup: " + ex.Message;
                // Reflect actual state if the write failed.
                LaunchAtStartupCheck.IsChecked = IsLaunchAtStartupEnabled();
            }
        };

        // Preview-window-size wiring. The slider and text box stay in
        // sync via a guard flag so the slider->box->slider feedback
        // doesn't loop on every micro-change. ValueChanged on the
        // slider writes the int to the store; LostFocus on the box
        // parses, clamps, and writes (avoiding a write per keystroke).
        bool syncing = false;
        void UpdateFromSlider(Slider s, TextBox tb, Action<int> setter, int min, int max)
        {
            if (syncing) return;
            syncing = true;
            var v = (int)Math.Round(s.Value);
            v = Math.Max(min, Math.Min(max, v));
            tb.Text = v.ToString(System.Globalization.CultureInfo.InvariantCulture);
            Save(() => setter(v));
            syncing = false;
        }
        void UpdateFromBox(TextBox tb, Slider s, Action<int> setter, int min, int max)
        {
            if (syncing) return;
            if (!int.TryParse(tb.Text,
                              System.Globalization.NumberStyles.Integer,
                              System.Globalization.CultureInfo.InvariantCulture,
                              out var v)) return;
            v = Math.Max(min, Math.Min(max, v));
            syncing = true;
            tb.Text  = v.ToString(System.Globalization.CultureInfo.InvariantCulture);
            s.Value  = v;
            Save(() => setter(v));
            syncing = false;
        }
        PreviewWidthSlider.ValueChanged  += (_, _) => UpdateFromSlider(
            PreviewWidthSlider, PreviewWidthBox,
            SettingsStore.SetPreviewWidth,
            SettingsStore.PreviewWidthMin, SettingsStore.PreviewWidthMax);
        PreviewHeightSlider.ValueChanged += (_, _) => UpdateFromSlider(
            PreviewHeightSlider, PreviewHeightBox,
            SettingsStore.SetPreviewHeight,
            SettingsStore.PreviewHeightMin, SettingsStore.PreviewHeightMax);
        PreviewWidthBox.LostFocus  += (_, _) => UpdateFromBox(
            PreviewWidthBox, PreviewWidthSlider,
            SettingsStore.SetPreviewWidth,
            SettingsStore.PreviewWidthMin, SettingsStore.PreviewWidthMax);
        PreviewHeightBox.LostFocus += (_, _) => UpdateFromBox(
            PreviewHeightBox, PreviewHeightSlider,
            SettingsStore.SetPreviewHeight,
            SettingsStore.PreviewHeightMin, SettingsStore.PreviewHeightMax);
        // Enter on the text box commits the value immediately.
        PreviewWidthBox.KeyDown  += (_, e) => { if (e.Key == System.Windows.Input.Key.Enter) UpdateFromBox(
            PreviewWidthBox, PreviewWidthSlider,
            SettingsStore.SetPreviewWidth,
            SettingsStore.PreviewWidthMin, SettingsStore.PreviewWidthMax); };
        PreviewHeightBox.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Enter) UpdateFromBox(
            PreviewHeightBox, PreviewHeightSlider,
            SettingsStore.SetPreviewHeight,
            SettingsStore.PreviewHeightMin, SettingsStore.PreviewHeightMax); };
    }

    /// One-click preset for a compact preview popover.
    private void PreviewSize_Compact_Click(object sender, RoutedEventArgs e)
        => ApplyPreviewSize(480, 360);

    /// Reset preview size to the new in-tree default (560 x 420).
    private void PreviewSize_Default_Click(object sender, RoutedEventArgs e)
        => ApplyPreviewSize(SettingsStore.PreviewWidthDefault,
                            SettingsStore.PreviewHeightDefault);

    /// One-click preset for a roomy preview window (matches the
    /// 1.7.66-1.7.73 default).
    private void PreviewSize_Large_Click(object sender, RoutedEventArgs e)
        => ApplyPreviewSize(960, 720);

    private void ApplyPreviewSize(int w, int h)
    {
        PreviewWidthSlider.Value  = w;
        PreviewHeightSlider.Value = h;
        // Box text is updated by the slider-changed handler; the
        // Save call also fires there, so we don't double-write here.
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
        OpenUrl("https://github.com/ArioMoniri/QuickLookProtein");
    }

    private void OriginalRepoButton_Click(object sender, RoutedEventArgs e)
    {
        // Jethro Hemmann's upstream repo. Linked from the About card
        // to give the original author visible attribution that the
        // user can follow on one click.
        OpenUrl("https://github.com/JethroHemmann/QuickLookProtein");
    }

    private static void OpenUrl(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = url,
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
                                "QuickLookProtein2", MessageBoxButton.OK, MessageBoxImage.Information);
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
                "QuickLookProtein2", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        try { Process.Start(new ProcessStartInfo { FileName = log, UseShellExecute = true }); }
        catch (Exception ex)
        {
            MessageBox.Show("Could not open log: " + ex.Message,
                            "QuickLookProtein2", MessageBoxButton.OK, MessageBoxImage.Warning);
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
                "QuickLookProtein2", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        try { Process.Start(new ProcessStartInfo { FileName = log, UseShellExecute = true }); }
        catch (Exception ex)
        {
            MessageBox.Show("Could not open log: " + ex.Message,
                            "QuickLookProtein2", MessageBoxButton.OK, MessageBoxImage.Warning);
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
                        "QuickLookProtein2", MessageBoxButton.OK, MessageBoxImage.Warning);
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
            .Replace("{INFO_FILE_NAME}",         QuickLookProtein.Shared.SettingsStore.GetInfoShowFileName()         ? "true" : "false")
            .Replace("{INFO_ATOM_COUNT}",        QuickLookProtein.Shared.SettingsStore.GetInfoShowAtomCount()        ? "true" : "false")
            .Replace("{INFO_CHAIN_COUNT}",       QuickLookProtein.Shared.SettingsStore.GetInfoShowChainCount()       ? "true" : "false")
            .Replace("{INFO_FORMAT}",            QuickLookProtein.Shared.SettingsStore.GetInfoShowFormat()           ? "true" : "false")
            .Replace("{INFO_RES_COUNT}",         QuickLookProtein.Shared.SettingsStore.GetInfoShowResidueCount()     ? "true" : "false")
            .Replace("{INFO_ELEMENT_BREAKDOWN}", QuickLookProtein.Shared.SettingsStore.GetInfoShowElementBreakdown() ? "true" : "false")
            .Replace("{INFO_MOL_WEIGHT}",        QuickLookProtein.Shared.SettingsStore.GetInfoShowMolWeight()        ? "true" : "false")
            .Replace("{INFO_BOND_COUNT}",        QuickLookProtein.Shared.SettingsStore.GetInfoShowBondCount()        ? "true" : "false")
            .Replace("{INFO_PDB_TITLE}",         QuickLookProtein.Shared.SettingsStore.GetInfoShowPDBTitle()         ? "true" : "false")
            .Replace("{SHOW_CONTROLS}",          QuickLookProtein.Shared.SettingsStore.GetShowControlsInPreview()    ? "true" : "false")
            .Replace("{CTL_SHOW_STICK}",         QuickLookProtein.Shared.SettingsStore.GetCtlShowStick()    ? "true" : "false")
            .Replace("{CTL_SHOW_LINE}",          QuickLookProtein.Shared.SettingsStore.GetCtlShowLine()     ? "true" : "false")
            .Replace("{CTL_SHOW_SPHERE}",        QuickLookProtein.Shared.SettingsStore.GetCtlShowSphere()   ? "true" : "false")
            .Replace("{CTL_SHOW_CARTOON}",       QuickLookProtein.Shared.SettingsStore.GetCtlShowCartoon()  ? "true" : "false")
            .Replace("{CTL_SHOW_SURFACE}",       QuickLookProtein.Shared.SettingsStore.GetCtlShowSurface()  ? "true" : "false")
            .Replace("{CTL_SHOW_COLORSS}",       QuickLookProtein.Shared.SettingsStore.GetCtlShowColorSS()  ? "true" : "false")
            .Replace("{CTL_SHOW_LABELCA}",       QuickLookProtein.Shared.SettingsStore.GetCtlShowLabelCA()  ? "true" : "false")
            .Replace("{CTL_SHOW_RECENTER}",      QuickLookProtein.Shared.SettingsStore.GetCtlShowRecenter() ? "true" : "false")
            .Replace("{OUTLINE_SHADING}",        QuickLookProtein.Shared.SettingsStore.GetOutlineShading()    ? "true" : "false")
            .Replace("{AMBIENT_OCCLUSION}",      QuickLookProtein.Shared.SettingsStore.GetAmbientOcclusion() ? "true" : "false")
            .Replace("{AUTO_ORIENT}",            QuickLookProtein.Shared.SettingsStore.GetAutoOrient()        ? "true" : "false")
            .Replace("{CUBE_ISOSURFACE}",        QuickLookProtein.Shared.SettingsStore.GetCubeIsosurface()  ? "true" : "false")
            .Replace("{BIO_ASSEMBLY}",           QuickLookProtein.Shared.SettingsStore.GetBioAssembly()     ? "true" : "false")
            .Replace("{IS_CRYO_EM}",             "false")
            .Replace("{CRYO_EM_SIGMA}",          "2.5")
            .Replace("{SHOW_SHARE_BUTTON}",      QuickLookProtein.Shared.SettingsStore.GetShowShareButton() ? "true" : "false")
            .Replace("{PDB_TITLE}",              "")
            .Replace("{EXTRA_MODELS_JSON}",      "[]")
            .Replace("{EXTRA_MODELS_HTML}",      "")
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

    // ---- Launch-at-startup (1.7.76+) ---------------------------------
    //
    // Per-user autorun via HKCU\Software\Microsoft\Windows\CurrentVersion\Run.
    // Value name "QuickLook" matches what QL-Win's own installer writes,
    // so toggling here flips the same entry QL-Win's tray menu does -
    // no two competing autorun records.

    private const string RunRoot  = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValue = "QuickLook";

    private static string? FindQuickLookExe()
    {
        var candidates = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                         "Programs", "QuickLook", "QuickLook.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                         "QuickLook", "QuickLook.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
                         "QuickLook", "QuickLook.exe"),
        };
        foreach (var p in candidates) if (File.Exists(p)) return p;
        return null;
    }

    private static bool IsLaunchAtStartupEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunRoot, writable: false);
            return key?.GetValue(RunValue) is string s && !string.IsNullOrWhiteSpace(s);
        }
        catch { return false; }
    }

    private static void SetLaunchAtStartup(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunRoot, writable: true)
            ?? throw new InvalidOperationException("Could not open HKCU\\...\\Run for writing");
        if (enabled)
        {
            var exe = FindQuickLookExe()
                ?? throw new FileNotFoundException("QuickLook.exe not found in any standard install path; reinstall QuickLookProtein-Setup.exe.");
            // Quote the path so paths with spaces work.
            key.SetValue(RunValue, "\"" + exe + "\"", RegistryValueKind.String);
        }
        else
        {
            key.DeleteValue(RunValue, throwOnMissingValue: false);
        }
    }

    // ---- Refresh thumbnails (1.7.76+) --------------------------------
    //
    // P/Invokes the same SHChangeNotify broadcast install.ps1 does,
    // plus ie4uinit -ClearIconCache. If neither nudge revives stale
    // thumbnails the user can click the button again with the
    // Shift key held to force a full explorer.exe restart.

    [DllImport("shell32.dll", CharSet = CharSet.Auto)]
    private static extern void SHChangeNotify(int wEventId, int uFlags, IntPtr dwItem1, IntPtr dwItem2);

    private const int SHCNE_ASSOCCHANGED = 0x08000000;
    private const int SHCNF_IDLIST       = 0x0000;

    // ---- Software Update (1.7.77+) -----------------------------------
    //
    // GitHub /releases/latest checker. Manual button always works;
    // the AutoCheckUpdates checkbox gates a fire-and-forget run on
    // every Settings-window open.

    private UpdateInfo? _pendingUpdate;

    private async void CheckForUpdates_Click(object sender, RoutedEventArgs e)
    {
        await RunUpdateCheckAsync(showNoUpdateMessage: true);
    }

    private async System.Threading.Tasks.Task RunUpdateCheckAsync(bool showNoUpdateMessage)
    {
        try
        {
            CheckForUpdatesButton.IsEnabled = false;
            UpdateStatusLabel.Text = "Checking GitHub for updates...";
            var info = await UpdateChecker.CheckAsync();
            if (info == null)
            {
                UpdateStatusLabel.Text = "Couldn't reach GitHub. Check your network and try again.";
                return;
            }
            var current = UpdateChecker.CurrentVersion;
            if (UpdateChecker.IsNewer(info))
            {
                _pendingUpdate = info;
                UpdateStatusLabel.Text =
                    $"Update available: {info.TagName} (you have {current.Major}.{current.Minor}.{current.Build}).";
                UpdateNotesLabel.Text = info.ReleaseNotes;
                UpdateNotesLabel.Visibility = string.IsNullOrEmpty(info.ReleaseNotes)
                    ? Visibility.Collapsed : Visibility.Visible;
                InstallUpdateButton.Visibility = string.IsNullOrEmpty(info.SetupExeUrl)
                    ? Visibility.Collapsed : Visibility.Visible;
                OpenReleasePageButton.Visibility = Visibility.Visible;
            }
            else
            {
                _pendingUpdate = null;
                UpdateNotesLabel.Visibility = Visibility.Collapsed;
                InstallUpdateButton.Visibility = Visibility.Collapsed;
                OpenReleasePageButton.Visibility = Visibility.Collapsed;
                if (showNoUpdateMessage)
                {
                    UpdateStatusLabel.Text =
                        $"You're up to date ({current.Major}.{current.Minor}.{current.Build}).";
                }
                else
                {
                    // Restore the resting status line for the auto-check path.
                    UpdateStatusLabel.Text =
                        $"Installed version: {current.Major}.{current.Minor}.{current.Build}  (build {current})";
                }
            }
        }
        catch (Exception ex)
        {
            UpdateStatusLabel.Text = "Update check failed: " + ex.Message;
        }
        finally
        {
            CheckForUpdatesButton.IsEnabled = true;
        }
    }

    private async void InstallUpdate_Click(object sender, RoutedEventArgs e)
    {
        if (_pendingUpdate == null)
        {
            UpdateStatusLabel.Text = "No update is currently pending.";
            return;
        }
        try
        {
            InstallUpdateButton.IsEnabled = false;
            CheckForUpdatesButton.IsEnabled = false;
            UpdateStatusLabel.Text = $"Downloading {_pendingUpdate.TagName} setup...";
            var progress = new Progress<double>(p =>
                UpdateStatusLabel.Text = $"Downloading {_pendingUpdate.TagName} setup... {p * 100:F0}%");
            await UpdateChecker.DownloadAndInstallAsync(_pendingUpdate, progress);
            // DownloadAndInstallAsync launches Setup.exe and calls
            // Application.Shutdown() - control normally doesn't
            // return here. If it does, surface the state so the
            // user knows what happened.
            UpdateStatusLabel.Text = "Setup launched. Settings will close shortly so the installer can replace it.";
        }
        catch (Exception ex)
        {
            UpdateStatusLabel.Text = "Install failed: " + ex.Message;
            InstallUpdateButton.IsEnabled = true;
            CheckForUpdatesButton.IsEnabled = true;
        }
    }

    private void OpenReleasePage_Click(object sender, RoutedEventArgs e)
    {
        if (_pendingUpdate == null) return;
        OpenUrl(_pendingUpdate.ReleaseUrl);
    }

    private void RefreshThumbnails_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            // 1. Broadcast: shell re-walks association handlers.
            SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, IntPtr.Zero, IntPtr.Zero);

            // 2. Clear the icon cache so old bitmaps don't paper over
            //    the new handler results.
            var ie4uinit = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "ie4uinit.exe");
            if (File.Exists(ie4uinit))
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = ie4uinit,
                    Arguments = "-ClearIconCache",
                    CreateNoWindow = true,
                    UseShellExecute = false,
                })?.WaitForExit(3000);
            }

            // 3. If the user held Shift while clicking, do the
            //    nuclear option: restart explorer.exe. Documented in
            //    the button's tooltip + the README's Diagnostics
            //    section so it's discoverable but not a surprise.
            var shift = (System.Windows.Input.Keyboard.Modifiers
                         & System.Windows.Input.ModifierKeys.Shift) != 0;
            if (shift)
            {
                foreach (var p in Process.GetProcessesByName("explorer"))
                {
                    try { p.Kill(); } catch { }
                }
                // Windows auto-restarts explorer.exe from the shell
                // watchdog after a brief delay; no need to launch.
            }

            StatusLabel.Text = shift
                ? "Thumbnails refresh requested + explorer.exe restarted."
                : "Thumbnails refresh requested. Switch Explorer to Icon view to see changes; Shift+click this for a full Explorer restart.";
        }
        catch (Exception ex)
        {
            StatusLabel.Text = "Refresh failed: " + ex.Message;
        }
    }
}
