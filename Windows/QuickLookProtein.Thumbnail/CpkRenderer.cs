// Render a parsed atom list to a Bitmap using a simple depth-sorted
// CPK representation. Matches what the macOS QLThumbnail.appex does
// in Swift, just on top of System.Drawing instead of Core Graphics.
//
// Steps:
//   1. Center atoms on their bounding-box midpoint.
//   2. Apply a fixed isometric rotation so different structures look
//      similar in scale and orientation (so two RCSB downloads of the
//      same PDB render to visually-similar thumbnails - the macOS
//      version does this too).
//   3. Project to 2D, sort back-to-front by post-rotation Z.
//   4. Draw each atom as a radial-gradient circle. Highlight is a
//      lighter spot offset toward the upper-left to give the
//      impression of a 3D sphere with directional lighting.

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace QuickLookProtein.Thumbnail;

internal static class CpkRenderer
{
    public static Bitmap Render(List<Atom> atoms, int size)
    {
        var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode      = SmoothingMode.AntiAlias;
        g.InterpolationMode  = InterpolationMode.HighQualityBicubic;
        g.CompositingQuality = CompositingQuality.HighQuality;

        // Opaque dark background. We could return ARGB and let
        // Explorer composite, but GDI+'s Bitmap.GetHbitmap doesn't
        // round-trip 32-bit alpha cleanly without going through
        // CreateDIBSection - and shipping a CreateDIBSection helper
        // for every Windows / target framework combination is a lot
        // of moving parts. Opaque background also matches the macOS
        // QLThumbnail.appex look (dark grey, structure pops out).
        g.Clear(Color.FromArgb(255, 14, 14, 16));

        if (atoms == null || atoms.Count == 0) return bmp;

        // Translate to centroid-relative coordinates.
        float minX = float.MaxValue, minY = float.MaxValue, minZ = float.MaxValue;
        float maxX = float.MinValue, maxY = float.MinValue, maxZ = float.MinValue;
        foreach (var a in atoms)
        {
            if (a.X < minX) minX = a.X; if (a.X > maxX) maxX = a.X;
            if (a.Y < minY) minY = a.Y; if (a.Y > maxY) maxY = a.Y;
            if (a.Z < minZ) minZ = a.Z; if (a.Z > maxZ) maxZ = a.Z;
        }
        float cx = (minX + maxX) * 0.5f;
        float cy = (minY + maxY) * 0.5f;
        float cz = (minZ + maxZ) * 0.5f;
        float extent = Math.Max(Math.Max(maxX - minX, maxY - minY), maxZ - minZ);
        if (extent < 0.001f) extent = 1f;

        // Isometric-ish rotation, copied from the Mac side so
        // thumbnails feel familiar across platforms. 30deg yaw, 20deg
        // pitch (in radians).
        const float yaw   = 0.523598f;  // 30 degrees
        const float pitch = 0.349066f;  // 20 degrees
        float sy = (float)Math.Sin(yaw),   cy_ = (float)Math.Cos(yaw);
        float sp = (float)Math.Sin(pitch), cp_ = (float)Math.Cos(pitch);

        // Project + sort.
        var projected = new List<(float ScreenX, float ScreenY, float Depth, float Radius, Color Color)>(atoms.Count);
        // Fit the rotated bounding box to ~80% of the icon.
        float scale = (size * 0.80f) / extent;

        foreach (var a in atoms)
        {
            float x = a.X - cx;
            float y = a.Y - cy;
            float z = a.Z - cz;

            // Y-axis (yaw) then X-axis (pitch) rotation.
            float x1 =  x * cy_ + z * sy;
            float z1 = -x * sy  + z * cy_;
            float y2 =  y * cp_ - z1 * sp;
            float z2 =  y * sp  + z1 * cp_;

            float screenX = size * 0.5f + x1 * scale;
            float screenY = size * 0.5f - y2 * scale;   // flip Y for screen
            var info = ElementData.Get(a.Element);
            float radius = info.Radius * scale * 0.55f;
            // Floor at 1px to keep big proteins recognisable at 32x32.
            if (radius < 1.0f) radius = 1.0f;
            projected.Add((screenX, screenY, z2, radius, info.Color));
        }
        // Back-to-front (smaller z first when looking at -z direction).
        projected.Sort((a, b) => a.Depth.CompareTo(b.Depth));

        foreach (var p in projected)
        {
            DrawAtom(g, p.ScreenX, p.ScreenY, p.Radius, p.Color);
        }

        return bmp;
    }

    private static void DrawAtom(Graphics g, float x, float y, float r, Color color)
    {
        var rect = new RectangleF(x - r, y - r, r * 2f, r * 2f);

        // Subtle dark outline first so neighbouring atoms separate.
        using (var pen = new Pen(Color.FromArgb(140, 0, 0, 0), Math.Max(0.6f, r * 0.08f)))
        {
            g.DrawEllipse(pen, rect);
        }

        // Fill with a radial highlight: lighter blob offset toward
        // upper-left over a darker base. Approximates a Phong-shaded
        // sphere just well enough to read as 3D at icon sizes.
        using (var path = new GraphicsPath())
        {
            path.AddEllipse(rect);
            using var brush = new PathGradientBrush(path)
            {
                CenterPoint = new PointF(x - r * 0.35f, y - r * 0.35f),
                CenterColor = Lighten(color, 0.55f),
                SurroundColors = new[] { Darken(color, 0.25f) },
            };
            g.FillEllipse(brush, rect);
        }
    }

    private static Color Lighten(Color c, float amount)
    {
        amount = Math.Max(0f, Math.Min(1f, amount));
        return Color.FromArgb(
            c.A,
            (int)(c.R + (255 - c.R) * amount),
            (int)(c.G + (255 - c.G) * amount),
            (int)(c.B + (255 - c.B) * amount));
    }

    private static Color Darken(Color c, float amount)
    {
        amount = Math.Max(0f, Math.Min(1f, amount));
        return Color.FromArgb(
            c.A,
            (int)(c.R * (1 - amount)),
            (int)(c.G * (1 - amount)),
            (int)(c.B * (1 - amount)));
    }
}
