// Cartoon-ribbon rendering path for protein thumbnails.
//
// When the parsed atom list looks like a protein - multiple chains
// of CA atoms in recognised amino-acid residues - we get a much more
// recognisable thumbnail by drawing a smooth tube through the
// alpha-carbon backbone than by piling up CPK spheres (proteins have
// thousands of atoms; CPK at 64x64 collapses into a dense blob).
//
// Pipeline:
//   1. Filter to CA atoms, grouped by chain, sorted by residue seq.
//   2. Within each chain, sample a Catmull-Rom spline through the
//      CA positions to get a smooth curve (10 samples per segment).
//   3. Apply the same isometric rotation as CpkRenderer so multi-
//      chain thumbnails align with the per-chain ones.
//   4. Project to 2D and walk the polyline back-to-front, drawing a
//      tapered stroke at each segment with a color that varies along
//      the backbone (spectrum N->C, same N-to-C rainbow 3Dmol uses
//      for the Space-bar preview).

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace QuickLookProtein.Thumbnail;

internal static class RibbonRenderer
{
    /// <summary>Returns true if the atom list looks like a protein
    /// worth rendering as a cartoon ribbon (multiple CA atoms in
    /// standard amino-acid residues).</summary>
    public static bool LooksLikeProtein(List<Atom> atoms)
    {
        int caCount = 0;
        foreach (var a in atoms)
        {
            if (a.AtomName == "CA" && AminoAcids.Contains(a.ResidueName))
            {
                caCount++;
                if (caCount >= 10) return true;
            }
        }
        return false;
    }

    public static Bitmap Render(List<Atom> atoms, int size)
    {
        var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode      = SmoothingMode.AntiAlias;
        g.InterpolationMode  = InterpolationMode.HighQualityBicubic;
        g.CompositingQuality = CompositingQuality.HighQuality;
        // Match the CpkRenderer background so a folder mixing
        // proteins and small molecules looks consistent.
        g.Clear(Color.FromArgb(255, 14, 14, 16));

        // Group CA atoms by chain, sorted by residue number.
        var chains = new Dictionary<char, List<Atom>>();
        foreach (var a in atoms)
        {
            if (a.AtomName != "CA" || !AminoAcids.Contains(a.ResidueName)) continue;
            if (!chains.TryGetValue(a.ChainId, out var list))
            {
                list = new List<Atom>();
                chains[a.ChainId] = list;
            }
            list.Add(a);
        }
        if (chains.Count == 0) return bmp;
        foreach (var list in chains.Values)
            list.Sort((p, q) => p.ResidueSeq.CompareTo(q.ResidueSeq));

        // Compute bounding box across ALL backbone atoms so multi-
        // chain structures stay in proportion.
        float minX = float.MaxValue, minY = float.MaxValue, minZ = float.MaxValue;
        float maxX = float.MinValue, maxY = float.MinValue, maxZ = float.MinValue;
        foreach (var list in chains.Values)
        {
            foreach (var a in list)
            {
                if (a.X < minX) minX = a.X; if (a.X > maxX) maxX = a.X;
                if (a.Y < minY) minY = a.Y; if (a.Y > maxY) maxY = a.Y;
                if (a.Z < minZ) minZ = a.Z; if (a.Z > maxZ) maxZ = a.Z;
            }
        }
        float cx = (minX + maxX) * 0.5f;
        float cy = (minY + maxY) * 0.5f;
        float cz = (minZ + maxZ) * 0.5f;
        float extent = Math.Max(Math.Max(maxX - minX, maxY - minY), maxZ - minZ);
        if (extent < 0.001f) extent = 1f;

        // Same isometric rotation as the CPK path.
        const float yaw   = 0.523598f;  // 30 degrees
        const float pitch = 0.349066f;  // 20 degrees
        float sy = (float)Math.Sin(yaw),   cyR = (float)Math.Cos(yaw);
        float sp = (float)Math.Sin(pitch), cpR = (float)Math.Cos(pitch);
        float scale = (size * 0.80f) / extent;

        // For each chain: spline-interpolate, project, depth-sort
        // segments, draw back-to-front so the tube self-occludes
        // somewhat (a real 3D tube would do this with shading and
        // z-buffer; we approximate with sort-by-midpoint-depth).
        var segments = new List<(PointF a, PointF b, float depth, Color color, float thickness)>();
        foreach (var list in chains.Values)
        {
            if (list.Count < 2) continue;
            var samples = CatmullRomSpline(list, samplesPerSegment: 8);
            for (int i = 0; i < samples.Count - 1; i++)
            {
                var p0 = samples[i];
                var p1 = samples[i + 1];
                var (sx0, sy0, sz0) = Project(p0.x - cx, p0.y - cy, p0.z - cz,
                                              sy, cyR, sp, cpR, scale, size);
                var (sx1, sy1, sz1) = Project(p1.x - cx, p1.y - cy, p1.z - cz,
                                              sy, cyR, sp, cpR, scale, size);
                float depth = (sz0 + sz1) * 0.5f;
                // Color along the chain N->C with a spectrum hue,
                // same as 3Dmol's `spectrum` color scheme.
                float t = (float)i / Math.Max(1, samples.Count - 1);
                var color = SpectrumColor(t);
                // Tube thickness scales with viewport but is floored
                // so tiny chains still read at 32x32.
                float thickness = Math.Max(1.5f, size / 80f);
                segments.Add((new PointF(sx0, sy0), new PointF(sx1, sy1),
                              depth, color, thickness));
            }
        }
        segments.Sort((a, b) => a.depth.CompareTo(b.depth));

        // First pass: dark outline. Second pass: colored core. Gives
        // a subtle depth-of-field look at thumbnail sizes.
        foreach (var s in segments)
        {
            using var outline = new Pen(Color.FromArgb(180, 0, 0, 0), s.thickness + 1.4f)
            { StartCap = LineCap.Round, EndCap = LineCap.Round };
            g.DrawLine(outline, s.a, s.b);
        }
        foreach (var s in segments)
        {
            using var core = new Pen(s.color, s.thickness)
            { StartCap = LineCap.Round, EndCap = LineCap.Round };
            g.DrawLine(core, s.a, s.b);
        }

        return bmp;
    }

    private static (float sx, float sy, float sz) Project(
        float x, float y, float z,
        float sinYaw, float cosYaw, float sinPitch, float cosPitch,
        float scale, int size)
    {
        float x1 =  x * cosYaw + z * sinYaw;
        float z1 = -x * sinYaw + z * cosYaw;
        float y2 =  y * cosPitch - z1 * sinPitch;
        float z2 =  y * sinPitch + z1 * cosPitch;
        return (size * 0.5f + x1 * scale,
                size * 0.5f - y2 * scale,
                z2);
    }

    // Catmull-Rom centripetal spline through the CA points. Uniform
    // parametrisation is fine here - we're not doing physical
    // simulation, just a smooth visual curve.
    private static List<(float x, float y, float z)> CatmullRomSpline(List<Atom> points, int samplesPerSegment)
    {
        var result = new List<(float x, float y, float z)>(points.Count * samplesPerSegment);
        for (int i = 0; i < points.Count - 1; i++)
        {
            var p0 = i == 0 ? points[i] : points[i - 1];
            var p1 = points[i];
            var p2 = points[i + 1];
            var p3 = (i + 2 < points.Count) ? points[i + 2] : points[i + 1];
            for (int s = 0; s < samplesPerSegment; s++)
            {
                float t = (float)s / samplesPerSegment;
                float t2 = t * t;
                float t3 = t2 * t;
                float a = -0.5f * t3 + t2 - 0.5f * t;
                float b =  1.5f * t3 - 2.5f * t2 + 1f;
                float c = -1.5f * t3 + 2f   * t2 + 0.5f * t;
                float d =  0.5f * t3 - 0.5f * t2;
                result.Add((
                    a * p0.X + b * p1.X + c * p2.X + d * p3.X,
                    a * p0.Y + b * p1.Y + c * p2.Y + d * p3.Y,
                    a * p0.Z + b * p1.Z + c * p2.Z + d * p3.Z));
            }
        }
        result.Add((points[points.Count - 1].X,
                    points[points.Count - 1].Y,
                    points[points.Count - 1].Z));
        return result;
    }

    /// <summary>Spectrum (rainbow N->C) color at parameter t in [0,1].
    /// Approximates 3Dmol's `spectrum` scheme: cycle through blue ->
    /// cyan -> green -> yellow -> red.</summary>
    private static Color SpectrumColor(float t)
    {
        t = Math.Max(0, Math.Min(1, t));
        // Map t to HSV hue from 240 (blue) -> 0 (red) clockwise.
        float h = (1f - t) * 240f;
        return HsvToRgb(h, 0.85f, 1.0f);
    }

    private static Color HsvToRgb(float h, float s, float v)
    {
        float c = v * s;
        float x = c * (1f - Math.Abs((h / 60f) % 2f - 1f));
        float m = v - c;
        float r = 0, g = 0, b = 0;
        if (h < 60)       { r = c; g = x; }
        else if (h < 120) { r = x; g = c; }
        else if (h < 180) { g = c; b = x; }
        else if (h < 240) { g = x; b = c; }
        else if (h < 300) { r = x; b = c; }
        else              { r = c; b = x; }
        return Color.FromArgb(255,
            (int)((r + m) * 255), (int)((g + m) * 255), (int)((b + m) * 255));
    }

    // Standard amino-acid residue names we treat as protein backbone.
    // Includes the most common modified residues (MSE = selenomet,
    // CSO = oxidised cys, HID/HIE/HIP histidine tautomers) so X-ray
    // structures with non-canonical residues still render.
    private static readonly HashSet<string> AminoAcids = new(StringComparer.OrdinalIgnoreCase)
    {
        "ALA","ARG","ASN","ASP","CYS","GLN","GLU","GLY","HIS","ILE",
        "LEU","LYS","MET","PHE","PRO","SER","THR","TRP","TYR","VAL",
        "MSE","SEP","TPO","PTR","CSO","HID","HIE","HIP","CYX","ASX","GLX",
        "PYL","SEC","ASH","GLH","LYN","CYM",
    };
}
