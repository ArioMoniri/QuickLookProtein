// CPK color + atomic-radius table.
//
// Numbers cross-checked against:
//   - CPK colors: Jmol's default palette
//     (https://jmol.sourceforge.net/jscolors/)
//   - Atomic radii: covalent radii in pm from Cordero et al. 2008,
//     scaled down a bit for thumbnail rendering so atoms don't merge
//     into a solid blob at icon sizes.
//
// We keep the table small (16 common elements + a fallback) instead of
// the full periodic table because the thumbnail provider doesn't need
// to handle exotic transition metals - 99% of structure files in
// practice are organic / biological.

using System.Collections.Generic;
using System.Drawing;

namespace QuickLookProtein.Thumbnail;

internal static class ElementData
{
    internal readonly struct Info
    {
        public readonly Color Color;
        public readonly float Radius;
        public Info(Color c, float r) { Color = c; Radius = r; }
    }

    // Fallback for unrecognised elements - mid-grey, average size.
    private static readonly Info Default = new(Color.FromArgb(200, 200, 200), 0.70f);

    private static readonly Dictionary<string, Info> Table = new()
    {
        ["H"]  = new(Color.FromArgb(255, 255, 255), 0.31f),
        ["C"]  = new(Color.FromArgb( 64,  64,  64), 0.76f),
        ["N"]  = new(Color.FromArgb( 48,  80, 248), 0.71f),
        ["O"]  = new(Color.FromArgb(255,  13,  13), 0.66f),
        ["F"]  = new(Color.FromArgb(144, 224,  80), 0.57f),
        ["P"]  = new(Color.FromArgb(255, 128,   0), 1.07f),
        ["S"]  = new(Color.FromArgb(255, 255,  48), 1.05f),
        ["CL"] = new(Color.FromArgb( 31, 240,  31), 1.02f),
        ["BR"] = new(Color.FromArgb(166,  41,  41), 1.20f),
        ["I"]  = new(Color.FromArgb(148,   0, 148), 1.39f),
        ["NA"] = new(Color.FromArgb(171,  92, 242), 1.66f),
        ["K"]  = new(Color.FromArgb(143,  64, 212), 2.03f),
        ["MG"] = new(Color.FromArgb(138, 255,   0), 1.41f),
        ["CA"] = new(Color.FromArgb( 61, 255,   0), 1.76f),
        ["FE"] = new(Color.FromArgb(224, 102,  51), 1.32f),
        ["ZN"] = new(Color.FromArgb(125, 128, 176), 1.22f),
        ["CU"] = new(Color.FromArgb(200, 128,  51), 1.32f),
        ["MN"] = new(Color.FromArgb(156, 122, 199), 1.39f),
    };

    public static Info Get(string element)
    {
        if (string.IsNullOrEmpty(element)) return Default;
        var key = element.Trim().ToUpperInvariant();
        return Table.TryGetValue(key, out var info) ? info : Default;
    }
}
