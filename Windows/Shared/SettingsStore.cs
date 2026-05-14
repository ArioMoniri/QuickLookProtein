// Cross-process settings store for the Windows side of the project.
//
// Mirrors what `Xcode/Shared/Settings.swift` does on macOS: a single
// class that owns every user-tunable preview parameter, persists it
// to a shared backing store, and exposes typed read / write helpers.
//
// The macOS version uses UserDefaults with an App Group container so
// the main app and the QL extension see each other's writes. The
// Windows analogue is the per-user registry under
// `HKCU\Software\QuickLookProtein`. Both the QL plugin (QuickLook
// loads it into its own process) and the Settings WPF app read /
// write the same hive, so a toggle flipped in Settings is visible
// to the next preview without any IPC.
//
// This file is referenced from BOTH the Plugin csproj and the
// Settings csproj via `<Compile Include="..\Shared\SettingsStore.cs" />`
// to keep one source of truth - no NuGet shared-package overhead,
// no risk of the two builds drifting.

using System;
using Microsoft.Win32;

namespace QuickLookProtein.Shared;

/// <summary>Per-format atom rendering style. Names match what the
/// macOS Settings enum uses + what 3Dmol.js's `setStyle` accepts so
/// passing them straight through to the viewer template works.
/// </summary>
public enum AtomStyle
{
    Cartoon,
    Stick,
    Sphere,
    Line,
}

public enum ColorScheme
{
    Spectrum,
    Chain,
    Element,
    SecondaryStructure,
    AminoAcid,
    // B-factor / pLDDT (1.7.29+). For X-ray structures this is
    // thermal motion (rwb gradient); for AlphaFold predictions
    // the B-factor field holds pLDDT confidence (roygb 50-90).
    // Viewer template auto-detects which by examining the range.
    Bfactor,
}

public enum RotationSpeed
{
    Off,
    Slow,
    Medium,
    Fast,
}

public enum DefaultZoom
{
    Auto,
    Tight,
    Normal,
    Wide,
}

/// <summary>
/// Read / write the user's preview preferences from
/// <c>HKCU\Software\QuickLookProtein\Settings</c>. Static-only - the
/// registry is the source of truth; there's no in-memory cache, so
/// changes from one process are visible to the other on its next
/// read.
/// </summary>
public static class SettingsStore
{
    private const string RootKey = @"Software\QuickLookProtein\Settings";

    // ---- Per-format atom style --------------------------------------------------
    // Defaults match the macOS Settings.swift fallbacks so first-run
    // behaviour is identical cross-platform.

    public static AtomStyle GetAtomStylePDB()    => ReadEnum("AtomStylePDB",    AtomStyle.Cartoon);
    public static AtomStyle GetAtomStyleCIF()    => ReadEnum("AtomStyleCIF",    AtomStyle.Stick);
    public static AtomStyle GetAtomStyleSDF()    => ReadEnum("AtomStyleSDF",    AtomStyle.Stick);
    public static AtomStyle GetAtomStyleMOL()    => ReadEnum("AtomStyleMOL",    AtomStyle.Stick);
    public static AtomStyle GetAtomStyleMOL2()   => ReadEnum("AtomStyleMOL2",   AtomStyle.Stick);
    public static AtomStyle GetAtomStyleXYZ()    => ReadEnum("AtomStyleXYZ",    AtomStyle.Stick);
    public static AtomStyle GetAtomStyleGRO()    => ReadEnum("AtomStyleGRO",    AtomStyle.Cartoon);
    public static AtomStyle GetAtomStyleCUBE()   => ReadEnum("AtomStyleCUBE",   AtomStyle.Stick);
    public static AtomStyle GetAtomStylePQR()    => ReadEnum("AtomStylePQR",    AtomStyle.Stick);
    public static AtomStyle GetAtomStyleVASP()   => ReadEnum("AtomStyleVASP",   AtomStyle.Sphere);
    public static AtomStyle GetAtomStyleCDJSON() => ReadEnum("AtomStyleCDJSON", AtomStyle.Stick);
    public static AtomStyle GetAtomStyleMMTF()   => ReadEnum("AtomStyleMMTF",   AtomStyle.Cartoon);

    public static void SetAtomStylePDB(AtomStyle v)    => WriteEnum("AtomStylePDB",    v);
    public static void SetAtomStyleCIF(AtomStyle v)    => WriteEnum("AtomStyleCIF",    v);
    public static void SetAtomStyleSDF(AtomStyle v)    => WriteEnum("AtomStyleSDF",    v);
    public static void SetAtomStyleMOL(AtomStyle v)    => WriteEnum("AtomStyleMOL",    v);
    public static void SetAtomStyleMOL2(AtomStyle v)   => WriteEnum("AtomStyleMOL2",   v);
    public static void SetAtomStyleXYZ(AtomStyle v)    => WriteEnum("AtomStyleXYZ",    v);
    public static void SetAtomStyleGRO(AtomStyle v)    => WriteEnum("AtomStyleGRO",    v);
    public static void SetAtomStyleCUBE(AtomStyle v)   => WriteEnum("AtomStyleCUBE",   v);
    public static void SetAtomStylePQR(AtomStyle v)    => WriteEnum("AtomStylePQR",    v);
    public static void SetAtomStyleVASP(AtomStyle v)   => WriteEnum("AtomStyleVASP",   v);
    public static void SetAtomStyleCDJSON(AtomStyle v) => WriteEnum("AtomStyleCDJSON", v);
    public static void SetAtomStyleMMTF(AtomStyle v)   => WriteEnum("AtomStyleMMTF",   v);

    public static AtomStyle GetAtomStyle(string extension) => extension switch
    {
        "pdb" or "ent"     => GetAtomStylePDB(),
        "pdbqt"            => GetAtomStylePDB(),
        "cif" or "mmcif"   => GetAtomStyleCIF(),
        "sdf"              => GetAtomStyleSDF(),
        "mol"              => GetAtomStyleMOL(),
        "mol2"             => GetAtomStyleMOL2(),
        "xyz"              => GetAtomStyleXYZ(),
        "gro"              => GetAtomStyleGRO(),
        "cube" or "cub"    => GetAtomStyleCUBE(),
        "pqr"              => GetAtomStylePQR(),
        "vasp" or "poscar" => GetAtomStyleVASP(),
        "cdjson"           => GetAtomStyleCDJSON(),
        "mmtf"             => GetAtomStyleMMTF(),
        _                  => AtomStyle.Stick,
    };

    // ---- Global rendering --------------------------------------------------

    public static ColorScheme   GetColorScheme()   => ReadEnum("ColorScheme",   ColorScheme.Spectrum);
    public static RotationSpeed GetRotationSpeed() => ReadEnum("RotationSpeed", RotationSpeed.Medium);
    public static DefaultZoom   GetDefaultZoom()   => ReadEnum("DefaultZoom",   DefaultZoom.Auto);
    public static bool GetAutoStyleHetero() => ReadBool("AutoStyleHetero", true);
    public static bool GetShowSurface()     => ReadBool("ShowSurface",     false);
    public static bool GetHideHydrogens()   => ReadBool("HideHydrogens",   false);
    public static bool GetShowUnitCell()    => ReadBool("ShowUnitCell",    false);
    public static bool GetShowInfoOverlay() => ReadBool("ShowInfoOverlay", true);

    // Info-overlay field toggles (1.7.23+ on Windows; v1.7.19 already
    // shipped these on macOS). Defaults match the macOS path: the
    // four pre-1.7.19 fields default ON, the five new ones default
    // OFF so existing users don't get a wall of extra text.
    public static bool GetInfoShowFileName()         => ReadBool("InfoShowFileName",         true);
    public static bool GetInfoShowAtomCount()        => ReadBool("InfoShowAtomCount",        true);
    public static bool GetInfoShowChainCount()       => ReadBool("InfoShowChainCount",       true);
    public static bool GetInfoShowFormat()           => ReadBool("InfoShowFormat",           true);
    public static bool GetInfoShowResidueCount()     => ReadBool("InfoShowResidueCount",     false);
    public static bool GetInfoShowElementBreakdown() => ReadBool("InfoShowElementBreakdown", false);
    public static bool GetInfoShowMolWeight()        => ReadBool("InfoShowMolWeight",        false);
    public static bool GetInfoShowBondCount()        => ReadBool("InfoShowBondCount",        false);
    public static bool GetInfoShowPDBTitle()         => ReadBool("InfoShowPDBTitle",         false);

    /// Interactive 3Dmol control toolbar (Stick / Line / Sphere /
    /// Cartoon / Surface / Color SS / Label αC / Recenter) shown
    /// bottom-right of every Quick Look preview. Default ON.
    public static bool GetShowControlsInPreview()    => ReadBool("ShowControlsInPreview",    true);
    public static void SetShowControlsInPreview(bool v) => WriteBool("ShowControlsInPreview", v);

    // Per-button toolbar visibility (1.7.29+ on Windows; matches the
    // 8 Mac ctlShow* toggles). Defaults all ON.
    public static bool GetCtlShowStick()    => ReadBool("CtlShowStick",    true);
    public static bool GetCtlShowLine()     => ReadBool("CtlShowLine",     true);
    public static bool GetCtlShowSphere()   => ReadBool("CtlShowSphere",   true);
    public static bool GetCtlShowCartoon()  => ReadBool("CtlShowCartoon",  true);
    public static bool GetCtlShowSurface()  => ReadBool("CtlShowSurface",  true);
    public static bool GetCtlShowColorSS()  => ReadBool("CtlShowColorSS",  true);
    public static bool GetCtlShowLabelCA()  => ReadBool("CtlShowLabelCA",  true);
    public static bool GetCtlShowRecenter() => ReadBool("CtlShowRecenter", true);
    public static void SetCtlShowStick(bool v)    => WriteBool("CtlShowStick",    v);
    public static void SetCtlShowLine(bool v)     => WriteBool("CtlShowLine",     v);
    public static void SetCtlShowSphere(bool v)   => WriteBool("CtlShowSphere",   v);
    public static void SetCtlShowCartoon(bool v)  => WriteBool("CtlShowCartoon",  v);
    public static void SetCtlShowSurface(bool v)  => WriteBool("CtlShowSurface",  v);
    public static void SetCtlShowColorSS(bool v)  => WriteBool("CtlShowColorSS",  v);
    public static void SetCtlShowLabelCA(bool v)  => WriteBool("CtlShowLabelCA",  v);
    public static void SetCtlShowRecenter(bool v) => WriteBool("CtlShowRecenter", v);

    // Outline shading (1.7.29+). Default OFF.
    public static bool GetOutlineShading() => ReadBool("OutlineShading", false);
    public static void SetOutlineShading(bool v) => WriteBool("OutlineShading", v);

    public static void SetInfoShowFileName(bool v)         => WriteBool("InfoShowFileName",         v);
    public static void SetInfoShowAtomCount(bool v)        => WriteBool("InfoShowAtomCount",        v);
    public static void SetInfoShowChainCount(bool v)       => WriteBool("InfoShowChainCount",       v);
    public static void SetInfoShowFormat(bool v)           => WriteBool("InfoShowFormat",           v);
    public static void SetInfoShowResidueCount(bool v)     => WriteBool("InfoShowResidueCount",     v);
    public static void SetInfoShowElementBreakdown(bool v) => WriteBool("InfoShowElementBreakdown", v);
    public static void SetInfoShowMolWeight(bool v)        => WriteBool("InfoShowMolWeight",        v);
    public static void SetInfoShowBondCount(bool v)        => WriteBool("InfoShowBondCount",        v);
    public static void SetInfoShowPDBTitle(bool v)         => WriteBool("InfoShowPDBTitle",         v);

    public static void SetColorScheme(ColorScheme v)     => WriteEnum("ColorScheme",     v);
    public static void SetRotationSpeed(RotationSpeed v) => WriteEnum("RotationSpeed",   v);
    public static void SetDefaultZoom(DefaultZoom v)     => WriteEnum("DefaultZoom",     v);
    public static void SetAutoStyleHetero(bool v) => WriteBool("AutoStyleHetero", v);
    public static void SetShowSurface(bool v)     => WriteBool("ShowSurface",     v);
    public static void SetHideHydrogens(bool v)   => WriteBool("HideHydrogens",   v);
    public static void SetShowUnitCell(bool v)    => WriteBool("ShowUnitCell",    v);
    public static void SetShowInfoOverlay(bool v) => WriteBool("ShowInfoOverlay", v);

    // ---- Background color (RGBA, 0..1 floats) ------------------------------

    public static (double R, double G, double B, double A) GetBgColor()
    {
        return (ReadDouble("BgColorR", 0.0),
                ReadDouble("BgColorG", 0.0),
                ReadDouble("BgColorB", 0.0),
                ReadDouble("BgColorA", 0.0));
    }

    public static void SetBgColor(double r, double g, double b, double a)
    {
        WriteDouble("BgColorR", r);
        WriteDouble("BgColorG", g);
        WriteDouble("BgColorB", b);
        WriteDouble("BgColorA", a);
    }

    // ---- low-level helpers --------------------------------------------------

    private static RegistryKey OpenRoot(bool writable)
    {
        return Registry.CurrentUser.CreateSubKey(RootKey, writable);
    }

    private static T ReadEnum<T>(string name, T fallback) where T : struct, Enum
    {
        try
        {
            using var key = OpenRoot(false);
            var raw = key?.GetValue(name) as string;
            if (raw == null) return fallback;
            return Enum.TryParse<T>(raw, true, out var v) ? v : fallback;
        }
        catch { return fallback; }
    }

    private static void WriteEnum<T>(string name, T value) where T : struct, Enum
    {
        try
        {
            using var key = OpenRoot(true);
            key?.SetValue(name, value.ToString(), RegistryValueKind.String);
        }
        catch { /* swallow - settings persistence is best-effort */ }
    }

    private static bool ReadBool(string name, bool fallback)
    {
        try
        {
            using var key = OpenRoot(false);
            var v = key?.GetValue(name);
            if (v is int i)   return i != 0;
            if (v is string s) return s == "1" || string.Equals(s, "true", StringComparison.OrdinalIgnoreCase);
            return fallback;
        }
        catch { return fallback; }
    }

    private static void WriteBool(string name, bool value)
    {
        try
        {
            using var key = OpenRoot(true);
            key?.SetValue(name, value ? 1 : 0, RegistryValueKind.DWord);
        }
        catch { }
    }

    private static double ReadDouble(string name, double fallback)
    {
        try
        {
            using var key = OpenRoot(false);
            var s = key?.GetValue(name) as string;
            if (s == null) return fallback;
            return double.TryParse(s, System.Globalization.NumberStyles.Float,
                                   System.Globalization.CultureInfo.InvariantCulture, out var v)
                ? v : fallback;
        }
        catch { return fallback; }
    }

    private static void WriteDouble(string name, double value)
    {
        try
        {
            using var key = OpenRoot(true);
            key?.SetValue(name,
                          value.ToString("R", System.Globalization.CultureInfo.InvariantCulture),
                          RegistryValueKind.String);
        }
        catch { }
    }
}
