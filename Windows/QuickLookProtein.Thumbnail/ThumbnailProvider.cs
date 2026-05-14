// COM thumbnail provider for Windows Explorer.
//
// Explorer's thumbnail cache (thumbcache.dll) discovers handlers by
// looking up the file's extension in
// `HKCR\<ext>\ShellEx\{e357fccd-a995-4576-b01f-234630154e96}`.
// The value there is a CLSID, which is then resolved via
// `HKCR\CLSID\<clsid>\InProcServer32` to a DLL path. Explorer calls
// `CoCreateInstance` on the CLSID, casts to `IInitializeWithStream`,
// hands us the file as an IStream, then calls `IThumbnailProvider.GetThumbnail`.
//
// We register HKCU (per-user) variants of those keys from install.ps1
// so no admin rights are needed.
//
// Stable CLSID, never change it once shipped - users have the old
// value baked into their registry and changing it would orphan their
// thumbnails until the next install.

using System;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace QuickLookProtein.Thumbnail;

// Public because the COM class below references these types in its
// public method signatures. C# would otherwise complain about
// "inconsistent accessibility". COM consumers don't see the C#
// accessibility level anyway - it's a compile-time constraint only.

[ComImport]
[Guid("e357fccd-a995-4576-b01f-234630154e96")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IThumbnailProvider
{
    void GetThumbnail(uint cx, out IntPtr hBitmap, out WTS_ALPHATYPE pdwAlpha);
}

[ComImport]
[Guid("b824b49d-22ac-4161-ac8a-9916e8fa3f7f")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IInitializeWithStream
{
    void Initialize(IStream stream, uint grfMode);
}

public enum WTS_ALPHATYPE : uint
{
    WTSAT_UNKNOWN = 0,
    WTSAT_RGB     = 1,
    WTSAT_ARGB    = 2,
}

/// <summary>
/// Shell IThumbnailProvider for our 13 supported molecular file
/// formats. Stable CLSID embedded as the [Guid] attribute - the
/// installer references this exact string when registering shell-
/// handler keys, so it MUST NOT change between releases.
/// </summary>
[ComVisible(true)]
[Guid("B7E4A6F1-2D6E-4F58-9B1B-2E5A1F0B97A1")]
[ClassInterface(ClassInterfaceType.None)]
[ProgId("QuickLookProtein.Thumbnail")]
public sealed class MoleculeThumbnailProvider : IThumbnailProvider, IInitializeWithStream
{
    private byte[]? _data;
    private string  _extension = "";

    /// <summary>
    /// Explorer calls this with the file's contents as an IStream.
    /// We read it all into memory once - molecule files are small
    /// (typical PDB is &lt; 1 MB) and the COM IStream is
    /// single-threaded so streaming reads during render would just
    /// complicate the renderer for no real benefit.
    /// </summary>
    public void Initialize(IStream stream, uint grfMode)
    {
        // STATSTG carries the stream length so we can pre-size the
        // buffer instead of growing a MemoryStream in a loop.
        stream.Stat(out var stat, 1 /* STATFLAG_NONAME */);
        long length = stat.cbSize;
        // Hard cap so a hostile file (or 1 GB PDB dropped in a folder
        // gallery view) can't OOM Explorer's thumbcache process.
        const long maxBytes = 50L * 1024 * 1024;
        if (length > maxBytes) length = maxBytes;

        // System.Runtime.InteropServices.ComTypes.IStream.Read takes
        // a managed byte[] and an IntPtr out-param for bytes-read,
        // so we can hand it a single allocation and grow the
        // backing buffer via a chunk bounce. 64 KB chunks are big
        // enough to keep the COM round-trip count down on multi-MB
        // PDB files but small enough to avoid wasting pages on tiny
        // .xyz files.
        var buffer = new byte[length];
        int totalRead = 0;
        IntPtr pcbRead = Marshal.AllocHGlobal(sizeof(int));
        try
        {
            int chunkSize = (int)Math.Min(65536L, length);
            var chunk = new byte[chunkSize];
            while (totalRead < length)
            {
                int remaining = (int)Math.Min(chunk.Length, length - totalRead);
                stream.Read(chunk, remaining, pcbRead);
                int n = Marshal.ReadInt32(pcbRead);
                if (n <= 0) break;
                Buffer.BlockCopy(chunk, 0, buffer, totalRead, n);
                totalRead += n;
            }
        }
        finally
        {
            Marshal.FreeHGlobal(pcbRead);
        }
        if (totalRead < buffer.Length)
        {
            var trimmed = new byte[totalRead];
            Buffer.BlockCopy(buffer, 0, trimmed, 0, totalRead);
            _data = trimmed;
        }
        else
        {
            _data = buffer;
        }

        // We don't get the original filename from IInitializeWithStream
        // (it's IInitializeWithItem that carries that). Sniff format
        // from the stream contents instead - cheaper than registering
        // a different CLSID per extension.
        _extension = SniffFormat(_data);
    }

    /// <summary>
    /// Render the thumbnail at the requested edge length.
    /// hBitmap MUST be an HBITMAP from CreateDIBSection (or compatible);
    /// pdwAlpha tells Explorer whether the bitmap has a real alpha
    /// channel. We always return WTSAT_ARGB because our renderer writes
    /// transparent backgrounds.
    /// </summary>
    public void GetThumbnail(uint cx, out IntPtr hBitmap, out WTS_ALPHATYPE pdwAlpha)
    {
        hBitmap = IntPtr.Zero;
        // Opaque thumbnail (dark background painted by the renderer).
        // We sidestep the GDI+ alpha-HBITMAP roundtrip headaches by
        // not advertising alpha here.
        pdwAlpha = WTS_ALPHATYPE.WTSAT_RGB;
        if (_data is null || _data.Length == 0) return;

        try
        {
            int size = (int)Math.Max(16, Math.Min(cx, 1024));
            using var ms = new MemoryStream(_data, writable: false);
            var atoms = MoleculeParser.Parse(ms, _extension);
            if (atoms is null || atoms.Count == 0) return;
            // Pick render style: cartoon ribbon for proteins, CPK
            // for everything else. Detection is cheap (count CA
            // atoms in standard amino acids).
            using var bmp = RibbonRenderer.LooksLikeProtein(atoms)
                            ? RibbonRenderer.Render(atoms, size)
                            : CpkRenderer.Render(atoms, size);
            // Hand Explorer the HBITMAP. GetHbitmap allocates a new
            // GDI bitmap that the SHELL is responsible for releasing
            // (via DeleteObject) - which is exactly what Explorer
            // does internally, so this lifetime matches the contract.
            hBitmap = bmp.GetHbitmap();
        }
        catch
        {
            // Never throw out of a thumbnail provider - Explorer
            // catches the exception and shows a generic icon, but it
            // also blacklists the file extension for the rest of the
            // session, which is much worse than just returning a
            // null thumbnail and falling back to the generic icon
            // for this one file.
            hBitmap = IntPtr.Zero;
        }
    }

    private static string SniffFormat(byte[] data)
    {
        // Look at the first ~4KB and dispatch on simple markers.
        // Order matters: more-specific signatures first, generic
        // fallbacks last.
        int n = Math.Min(data.Length, 4096);
        var head = System.Text.Encoding.UTF8.GetString(data, 0, n);

        if (head.Contains("@<TRIPOS>"))               return "mol2";
        // CDJSON: ChemDoodle JSON has a top-level "a":[ ... ] array
        // of atom objects with x/y/z/l fields. Highly distinctive.
        if (head.Contains("\"a\":[") && head.Contains("\"l\""))
            return "cdjson";
        // CIF / mmCIF: starts with "data_" and contains "_atom_site"
        // somewhere in the header. We check both because some PDB
        // files have stray "data_" in their REMARK lines.
        if (head.StartsWith("data_", StringComparison.Ordinal)
            && head.IndexOf("_atom_site", StringComparison.Ordinal) >= 0)
        {
            return "cif";
        }
        if (head.IndexOf("HETATM", StringComparison.Ordinal) >= 0
         || head.IndexOf("ATOM  ", StringComparison.Ordinal) >= 0)
        {
            return "pdb";
        }
        // MOL/SDF V2000: line 4 has "  N  M  ...V2000"
        if (head.Contains("V2000"))                   return "mol";

        var lines = head.Split('\n');

        // Gaussian Cube: 2 comment lines, then a counts line where
        // the first token is +/- atom count and 3 floats follow.
        // We check for "5 numeric tokens on line 3 + 4 + 5 + 6".
        if (lines.Length >= 6
            && LooksLikeCubeCountsLine(lines[2])
            && LooksLikeCubeAxisLine(lines[3])
            && LooksLikeCubeAxisLine(lines[4])
            && LooksLikeCubeAxisLine(lines[5]))
        {
            return "cube";
        }

        // GRO: first line is title, second is integer atom count, third
        // has 8-char-wide coordinate fields starting at col 20.
        if (lines.Length >= 3 && int.TryParse(lines[1].Trim(), out _)
            && lines[2].Length > 44)
        {
            return "gro";
        }

        // VASP / POSCAR: line 2 is a single float (lattice scale),
        // lines 3-5 are 3-vector floats. Check AFTER PDB because some
        // PDB headers have lines that match by coincidence.
        if (lines.Length >= 6
            && SingleFloat(lines[1])
            && IsThreeFloats(lines[2]) && IsThreeFloats(lines[3]) && IsThreeFloats(lines[4]))
        {
            return "vasp";
        }

        // XYZ: first line is just an integer. Check this AFTER the
        // GRO check to avoid false positives (GRO's line 2 is also
        // an integer).
        var firstLine = lines[0].Trim();
        if (int.TryParse(firstLine, out _))           return "xyz";

        return "pdb";  // best-effort fallback
    }

    private static bool SingleFloat(string line)
    {
        var parts = line.Trim().Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
        return parts.Length == 1
            && float.TryParse(parts[0], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out _);
    }

    private static bool IsThreeFloats(string line)
    {
        var parts = line.Trim().Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 3) return false;
        for (int i = 0; i < 3; i++)
            if (!float.TryParse(parts[i], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out _))
                return false;
        return true;
    }

    private static bool LooksLikeCubeCountsLine(string line)
    {
        var parts = line.Trim().Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 4) return false;
        if (!int.TryParse(parts[0], out _)) return false;
        for (int i = 1; i < 4; i++)
            if (!float.TryParse(parts[i], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out _))
                return false;
        return true;
    }

    private static bool LooksLikeCubeAxisLine(string line)
    {
        // Axis lines: voxel-count followed by 3 floats (the basis vector).
        var parts = line.Trim().Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 4) return false;
        if (!int.TryParse(parts[0], out _)) return false;
        for (int i = 1; i < 4; i++)
            if (!float.TryParse(parts[i], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out _))
                return false;
        return true;
    }
}
