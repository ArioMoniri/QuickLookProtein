// MainWindow.Theme.cs — v1.7.81 redesign code-behind.
//
// Houses the bits the new UI needs but the original MainWindow.xaml.cs
// shouldn't be burdened with: light/dark palette swapping in response
// to Windows theme changes, Mica/Acrylic backdrop via DWM P/Invoke,
// sidebar-nav SelectionChanged → tab visibility, slider mouse-wheel
// suppression, and the Thumbnails "Reset to Auto" handler.
//
// Everything is partial-class on MainWindow so XAML's x:Name fields
// remain accessible without ceremony.

using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32;
using QuickLookProtein.Shared;

namespace QuickLookProtein.Settings;

public partial class MainWindow
{
    // ============================================================
    // Theme (light / dark, system-following)
    // ============================================================
    //
    // Strategy: every theme-sensitive brush in MainWindow.xaml is a
    // DynamicResource pointing at a SolidColorBrush in Window.Resources.
    // ApplyTheme() mutates each brush's .Color in place, so every
    // control that binds to the brush updates instantly without us
    // having to walk the visual tree. The XAML ships with the LIGHT
    // palette as defaults so the designer + the first paint look
    // correct before code-behind runs.

    private static bool IsSystemDarkMode()
    {
        // HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize
        // AppsUseLightTheme: 0 = dark, 1 = light. Default missing on
        // Windows 10 LTSC and a few corp images, so treat absence as
        // "light" rather than guessing.
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            var v = key?.GetValue("AppsUseLightTheme");
            return v is int i && i == 0;
        }
        catch
        {
            return false;
        }
    }

    private void ApplyTheme()
    {
        bool dark = IsSystemDarkMode();
        if (dark) ApplyDarkPalette();
        else      ApplyLightPalette();

        // Repaint the title-bar / window chrome to match. Without
        // this, a dark-mode app would still have a white title bar
        // on Win10+ — looks jarring against the dark client area.
        ApplyDarkTitleBar(dark);
    }

    private void SetBrush(string key, byte r, byte g, byte b, byte a = 0xFF)
    {
        if (Resources[key] is SolidColorBrush b1)
        {
            b1.Color = Color.FromArgb(a, r, g, b);
        }
    }

    private void ApplyLightPalette()
    {
        SetBrush("AppBg",             0, 0, 0, 0); // transparent (Mica)
        SetBrush("SidebarBg",         0xF3, 0xF3, 0xF3);
        SetBrush("ContentBg",         0xFA, 0xFA, 0xFA);
        SetBrush("CardBg",            0xFF, 0xFF, 0xFF);
        SetBrush("CardStroke",        0xE5, 0xE5, 0xE5);
        SetBrush("HoverBg",           0xEF, 0xEF, 0xEF);
        SetBrush("PressedBg",         0xE3, 0xE3, 0xE3);
        SetBrush("NavSelectedBg",     0xE5, 0xF1, 0xFB);
        SetBrush("NavSelectedStroke", 0x00, 0x67, 0xC0);
        SetBrush("TextPrimary",       0x1F, 0x1F, 0x1F);
        SetBrush("TextSecondary",     0x5C, 0x5C, 0x5C);
        SetBrush("TextMuted",         0x8B, 0x8B, 0x8B);
        SetBrush("Accent",            0x00, 0x67, 0xC0);
        SetBrush("AccentHover",       0x1A, 0x77, 0xCC);
        SetBrush("AccentPressed",     0x00, 0x5A, 0xA0);
        SetBrush("WarnBg",            0xFF, 0xF4, 0xCE);
        SetBrush("WarnText",          0x5B, 0x45, 0x00);
        SetBrush("ErrBg",             0xFD, 0xE7, 0xE9);
        SetBrush("ErrText",           0x8E, 0x17, 0x26);
    }

    private void ApplyDarkPalette()
    {
        SetBrush("AppBg",             0, 0, 0, 0); // transparent (Mica)
        SetBrush("SidebarBg",         0x1C, 0x1C, 0x1C);
        SetBrush("ContentBg",         0x20, 0x20, 0x20);
        SetBrush("CardBg",            0x2B, 0x2B, 0x2B);
        SetBrush("CardStroke",        0x3D, 0x3D, 0x3D);
        SetBrush("HoverBg",           0x36, 0x36, 0x36);
        SetBrush("PressedBg",         0x42, 0x42, 0x42);
        SetBrush("NavSelectedBg",     0x33, 0x3F, 0x52);
        SetBrush("NavSelectedStroke", 0x4C, 0xC2, 0xFF);
        SetBrush("TextPrimary",       0xFF, 0xFF, 0xFF);
        SetBrush("TextSecondary",     0xC8, 0xC8, 0xC8);
        SetBrush("TextMuted",         0x90, 0x90, 0x90);
        SetBrush("Accent",            0x4C, 0xC2, 0xFF);
        SetBrush("AccentHover",       0x6F, 0xD0, 0xFF);
        SetBrush("AccentPressed",     0x37, 0xA8, 0xE0);
        SetBrush("WarnBg",            0x44, 0x3A, 0x16);
        SetBrush("WarnText",          0xFC, 0xE1, 0x80);
        SetBrush("ErrBg",             0x44, 0x21, 0x26);
        SetBrush("ErrText",           0xFF, 0x99, 0xA4);
    }

    private void HookSystemThemeChange()
    {
        // Windows broadcasts WM_SETTINGCHANGE → UserPreferenceCategory.General
        // when the user flips Settings → Personalisation → Colours.
        // ResetTheme reads the registry fresh and re-applies — cheap.
        SystemEvents.UserPreferenceChanged += (_, e) =>
        {
            if (e.Category == UserPreferenceCategory.General)
            {
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    try { ApplyTheme(); ApplySystemBackdrop(); } catch { }
                }));
            }
        };
    }

    // ============================================================
    // Mica / Acrylic backdrop (Windows 11) and dark title bar
    // ============================================================

    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    private const int DWMWA_SYSTEMBACKDROP_TYPE     = 38; // Win11 22H2+
    private const int DWMWA_MICA_EFFECT             = 1029; // Win11 21H2 undocumented

    [DllImport("dwmapi.dll", CharSet = CharSet.Unicode)]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);

    /// <summary>
    /// Best-effort: enable Mica on Win11 22H2+, fall back to the
    /// pre-22H2 mica-effect flag on Win11 21H2, do nothing on
    /// Windows 10 (the window simply uses the AppBg solid colour).
    /// </summary>
    private void ApplySystemBackdrop()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;

        // For Mica to actually render, the window must not paint over
        // it with a solid colour. We set Window.Background = the
        // theme "AppBg" brush, whose colour is 0,0,0,0 (transparent)
        // in both palettes — so the DWM-painted backdrop shows
        // through the entire window. Sidebar + content paint their
        // own solid surfaces, leaving only the 1-px title-bar strip
        // and any padding showing the Mica.

        bool dark = IsSystemDarkMode();
        int immersiveDark = dark ? 1 : 0;
        try { DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref immersiveDark, sizeof(int)); }
        catch { }

        // Try the new attribute first (Win11 22H2+, build 22621).
        // 0 = Auto, 1 = None, 2 = Mainwindow (Mica), 3 = Transient (Acrylic), 4 = Tabbed.
        int backdrop = 2;
        var result = TrySetAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, backdrop);
        if (result != 0)
        {
            // Fall back to the pre-22H2 mica-effect flag (build 22000-22621).
            int mica = 1;
            TrySetAttribute(hwnd, DWMWA_MICA_EFFECT, mica);
        }
    }

    private static int TrySetAttribute(IntPtr hwnd, int attr, int value)
    {
        try
        {
            int v = value;
            return DwmSetWindowAttribute(hwnd, attr, ref v, sizeof(int));
        }
        catch
        {
            return -1;
        }
    }

    private void ApplyDarkTitleBar(bool dark)
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        int v = dark ? 1 : 0;
        try { DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref v, sizeof(int)); }
        catch { }
    }

    // ============================================================
    // Sidebar nav — tab visibility
    // ============================================================

    /// <summary>
    /// Maps each ListBoxItem's Tag (set in XAML) to the corresponding
    /// content StackPanel. Centralising the lookup keeps the XAML
    /// declarative — adding a new tab is one XAML entry + one
    /// dictionary line here.
    /// </summary>
    private (string Tag, StackPanel Panel)[] AllTabs() => new[]
    {
        ("General",     GeneralTab),
        ("FileFormats", FileFormatsTab),
        ("Appearance",  AppearanceTab),
        ("Rendering",   RenderingTab),
        ("Toolbar",     ToolbarTab),
        ("InfoOverlay", InfoOverlayTab),
        ("Thumbnails",  ThumbnailsTab),
        ("Update",      UpdateTab),
        ("About",       AboutTab),
    };

    private void NavList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender is not ListBox lb) return;
        if (lb.SelectedItem is not ListBoxItem item) return;
        var tag = item.Tag as string ?? "General";
        ShowTab(tag);
    }

    private void ShowTab(string tag)
    {
        foreach (var (t, panel) in AllTabs())
        {
            if (panel != null)
                panel.Visibility = string.Equals(t, tag, StringComparison.Ordinal)
                    ? Visibility.Visible
                    : Visibility.Collapsed;
        }
    }

    // ============================================================
    // Slider tuning — kill the mouse-wheel jumpiness
    // ============================================================

    private void ConfigureSliders()
    {
        // Mouse-wheel over a Slider normally changes the value by
        // SmallChange × delta/120. With the wide ranges we use for
        // preview-window-size (240-2400), even a single wheel notch
        // could push the value 80px — the source of the "sensitivity
        // too high" complaint. Eat the wheel event entirely; users
        // can still drag the thumb, type into the text box, or click
        // the Compact/Default/Large presets.
        void StopWheel(object s, System.Windows.Input.MouseWheelEventArgs ev) { ev.Handled = true; }

        if (PreviewWidthSlider  != null) PreviewWidthSlider.PreviewMouseWheel  += StopWheel;
        if (PreviewHeightSlider != null) PreviewHeightSlider.PreviewMouseWheel += StopWheel;
    }

    // ============================================================
    // Thumbnails: "Reset to Auto" button
    // ============================================================

    private void ThumbStyle_ResetAll_Click(object sender, RoutedEventArgs e)
    {
        // Reset every per-format ThumbStyle entry to Auto and reflect
        // the change in the UI. Save() goes through _suppressWrites,
        // so wrap our own flag flip to keep ComboBox SelectionChanged
        // from firing duplicate writes.
        try
        {
            _suppressWrites = true;
            var combos = new[]
            {
                ("pdb",    ThumbPdbCombo),
                ("cif",    ThumbCifCombo),
                ("sdf",    ThumbSdfCombo),
                ("mol",    ThumbMolCombo),
                ("mol2",   ThumbMol2Combo),
                ("xyz",    ThumbXyzCombo),
                ("gro",    ThumbGroCombo),
                ("cube",   ThumbCubeCombo),
                ("pqr",    ThumbPqrCombo),
                ("vasp",   ThumbVaspCombo),
                ("cdjson", ThumbCdjsonCombo),
                ("mmtf",   ThumbMmtfCombo),
            };
            foreach (var (ext, combo) in combos)
            {
                SettingsStore.SetThumbStyle(ext, ThumbnailStyle.Auto);
                if (combo != null) combo.SelectedItem = ThumbnailStyle.Auto;
            }
            StatusLabel.Text = "Thumbnail styles reset to Auto. Use Refresh thumbnails to redraw Explorer icons.";
        }
        catch (Exception ex)
        {
            StatusLabel.Text = "Reset failed: " + ex.Message;
        }
        finally
        {
            _suppressWrites = false;
        }
    }
}
