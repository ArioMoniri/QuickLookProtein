// Minimal parsers for the structure formats the thumbnail provider
// supports. Intentionally conservative - we only need atom positions
// and element identities; bonds are inferred at render time from
// distance heuristics, and we drop everything else (headers, hetero
// records, secondary structure, etc.) because thumbnails are tiny and
// have no room for that detail.
//
// Supports: .pdb / .ent, .mol / .sdf (V2000), .mol2, .xyz, .gro.
// PDB-style records get the most coverage because that's the dominant
// format in biology files.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;

namespace QuickLookProtein.Thumbnail;

internal readonly struct Atom
{
    public readonly float X, Y, Z;
    public readonly string Element;
    public Atom(float x, float y, float z, string e) { X = x; Y = y; Z = z; Element = e; }
}

internal static class MoleculeParser
{
    // Cap on number of atoms we'll parse for a thumbnail. PDBs with
    // 100k+ atoms exist; rendering all of them is wasteful at icon
    // sizes (most pixels would be overpainted). Sample uniformly.
    private const int MaxAtoms = 5000;

    public static List<Atom>? Parse(Stream stream, string extension)
    {
        var ext = (extension ?? "").TrimStart('.').ToLowerInvariant();
        using var reader = new StreamReader(stream, System.Text.Encoding.UTF8, true, 8192, leaveOpen: true);
        return ext switch
        {
            "pdb" or "ent" or "pdbqt" or "pqr" => ParsePdb(reader),
            "mol" or "sdf" => ParseMol(reader),
            "mol2"         => ParseMol2(reader),
            "xyz"          => ParseXyz(reader),
            "gro"          => ParseGro(reader),
            _              => null,
        };
    }

    // PDB ATOM/HETATM record - columns 13-16 atom name, 77-78 element,
    // 31-38 / 39-46 / 47-54 coordinates. We use the element field
    // when present, else fall back to the first 1-2 letters of the
    // atom name (this is how PyMOL and Chimera do it).
    private static List<Atom> ParsePdb(StreamReader r)
    {
        var atoms = new List<Atom>();
        string? line;
        while ((line = r.ReadLine()) != null)
        {
            if (atoms.Count >= MaxAtoms) break;
            if (line.Length < 54) continue;
            if (!(line.StartsWith("ATOM") || line.StartsWith("HETATM"))) continue;
            if (!float.TryParse(line.Substring(30, 8), NumberStyles.Float, CultureInfo.InvariantCulture, out var x)) continue;
            if (!float.TryParse(line.Substring(38, 8), NumberStyles.Float, CultureInfo.InvariantCulture, out var y)) continue;
            if (!float.TryParse(line.Substring(46, 8), NumberStyles.Float, CultureInfo.InvariantCulture, out var z)) continue;
            string element;
            if (line.Length >= 78)
            {
                element = line.Substring(76, 2).Trim();
                if (string.IsNullOrEmpty(element))
                    element = ExtractElementFromAtomName(line.Substring(12, 4).Trim());
            }
            else
            {
                element = ExtractElementFromAtomName(line.Substring(12, 4).Trim());
            }
            atoms.Add(new Atom(x, y, z, element));
        }
        return atoms;
    }

    private static string ExtractElementFromAtomName(string atomName)
    {
        if (string.IsNullOrEmpty(atomName)) return "C";
        // Strip leading digits (e.g. "1HE2" -> "HE2"). Most PDB atom
        // names start with the element letter; for two-letter
        // elements like CL/BR/FE the first two chars are the element.
        int i = 0;
        while (i < atomName.Length && char.IsDigit(atomName[i])) i++;
        if (i >= atomName.Length) return "C";
        return atomName.Substring(i, Math.Min(2, atomName.Length - i));
    }

    // MOL V2000: counts line "N_atoms N_bonds...", then N_atoms lines
    // of "x y z element ...".
    private static List<Atom> ParseMol(StreamReader r)
    {
        var atoms = new List<Atom>();
        // Skip 3 header lines.
        for (int i = 0; i < 3; i++) if (r.ReadLine() is null) return atoms;
        var counts = r.ReadLine();
        if (counts is null || counts.Length < 6) return atoms;
        if (!int.TryParse(counts.Substring(0, 3).Trim(), out var nAtoms)) return atoms;
        nAtoms = Math.Min(nAtoms, MaxAtoms);
        for (int i = 0; i < nAtoms; i++)
        {
            var line = r.ReadLine();
            if (line is null || line.Length < 34) continue;
            if (!float.TryParse(line.Substring(0, 10), NumberStyles.Float, CultureInfo.InvariantCulture, out var x)) continue;
            if (!float.TryParse(line.Substring(10, 10), NumberStyles.Float, CultureInfo.InvariantCulture, out var y)) continue;
            if (!float.TryParse(line.Substring(20, 10), NumberStyles.Float, CultureInfo.InvariantCulture, out var z)) continue;
            var element = line.Substring(31, Math.Min(3, line.Length - 31)).Trim();
            atoms.Add(new Atom(x, y, z, element));
        }
        return atoms;
    }

    // MOL2: @<TRIPOS>ATOM section, whitespace-separated, atom name in
    // column 2 (first letters = element).
    private static List<Atom> ParseMol2(StreamReader r)
    {
        var atoms = new List<Atom>();
        string? line;
        bool inAtoms = false;
        while ((line = r.ReadLine()) != null)
        {
            if (atoms.Count >= MaxAtoms) break;
            if (line.StartsWith("@<TRIPOS>ATOM")) { inAtoms = true; continue; }
            if (line.StartsWith("@<TRIPOS>")) { if (inAtoms) break; continue; }
            if (!inAtoms) continue;
            var parts = line.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 6) continue;
            if (!float.TryParse(parts[2], NumberStyles.Float, CultureInfo.InvariantCulture, out var x)) continue;
            if (!float.TryParse(parts[3], NumberStyles.Float, CultureInfo.InvariantCulture, out var y)) continue;
            if (!float.TryParse(parts[4], NumberStyles.Float, CultureInfo.InvariantCulture, out var z)) continue;
            // SYBYL atom type "C.3" -> element "C"
            var type = parts[5];
            var dot = type.IndexOf('.');
            var element = dot > 0 ? type.Substring(0, dot) : type;
            atoms.Add(new Atom(x, y, z, element));
        }
        return atoms;
    }

    // XYZ: line 1 = atom count, line 2 = comment, then "elem x y z".
    private static List<Atom> ParseXyz(StreamReader r)
    {
        var atoms = new List<Atom>();
        var first = r.ReadLine();
        if (first is null || !int.TryParse(first.Trim(), out var nAtoms)) return atoms;
        nAtoms = Math.Min(nAtoms, MaxAtoms);
        r.ReadLine();  // comment
        for (int i = 0; i < nAtoms; i++)
        {
            var line = r.ReadLine();
            if (line is null) break;
            var parts = line.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 4) continue;
            if (!float.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var x)) continue;
            if (!float.TryParse(parts[2], NumberStyles.Float, CultureInfo.InvariantCulture, out var y)) continue;
            if (!float.TryParse(parts[3], NumberStyles.Float, CultureInfo.InvariantCulture, out var z)) continue;
            atoms.Add(new Atom(x, y, z, parts[0]));
        }
        return atoms;
    }

    // GROMACS GRO: line 1 = title, 2 = atom count, then fixed-width
    // residue/atom/x/y/z (nm - we convert to Angstroms by *10 so the
    // thumbnail renderer's scale heuristics match the other formats).
    private static List<Atom> ParseGro(StreamReader r)
    {
        var atoms = new List<Atom>();
        r.ReadLine();  // title
        var countLine = r.ReadLine();
        if (countLine is null || !int.TryParse(countLine.Trim(), out var nAtoms)) return atoms;
        nAtoms = Math.Min(nAtoms, MaxAtoms);
        for (int i = 0; i < nAtoms; i++)
        {
            var line = r.ReadLine();
            if (line is null || line.Length < 44) break;
            var atomName = line.Substring(10, 5).Trim();
            if (!float.TryParse(line.Substring(20, 8), NumberStyles.Float, CultureInfo.InvariantCulture, out var x)) continue;
            if (!float.TryParse(line.Substring(28, 8), NumberStyles.Float, CultureInfo.InvariantCulture, out var y)) continue;
            if (!float.TryParse(line.Substring(36, 8), NumberStyles.Float, CultureInfo.InvariantCulture, out var z)) continue;
            atoms.Add(new Atom(x * 10f, y * 10f, z * 10f,
                               ExtractElementFromAtomName(atomName)));
        }
        return atoms;
    }
}
