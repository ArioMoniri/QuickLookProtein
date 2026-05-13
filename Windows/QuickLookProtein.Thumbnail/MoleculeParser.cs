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
            "mol" or "sdf"        => ParseMol(reader),
            "mol2"                => ParseMol2(reader),
            "xyz"                 => ParseXyz(reader),
            "gro"                 => ParseGro(reader),
            "cif" or "mmcif"      => ParseCif(reader),
            "cube" or "cub"       => ParseCube(reader),
            _                     => null,
        };
    }

    /// <summary>
    /// Parse the atom_site loop of a CIF / mmCIF file. Handles both
    /// small-molecule CIF (one block, simple key-value) and the much
    /// more common macromolecular mmCIF (loop_-driven). We only need
    /// the Cartesian coordinates + element identifiers, so we walk
    /// the loop column headers, note which columns hold what, and
    /// read each data row by index.
    /// </summary>
    private static List<Atom> ParseCif(StreamReader r)
    {
        var atoms = new List<Atom>();
        string? line;
        // Step 1: scan to a `loop_` whose first column is an
        // `_atom_site.*` (mmCIF) or `_atom_site_*` (small-mol CIF).
        bool inLoopHeader = false;
        var loopColumns = new List<string>();
        while ((line = r.ReadLine()) != null)
        {
            var t = line.Trim();
            if (t.Length == 0 || t.StartsWith("#")) continue;
            if (t.Equals("loop_", StringComparison.Ordinal))
            {
                inLoopHeader = true;
                loopColumns.Clear();
                continue;
            }
            if (inLoopHeader && t.StartsWith("_"))
            {
                loopColumns.Add(t);
                continue;
            }
            if (inLoopHeader && loopColumns.Count > 0)
            {
                // First non-header line - either we're in the right
                // loop (atom_site) or we should skip its rows and
                // keep scanning for the right loop.
                var first = loopColumns[0];
                bool isAtomLoop = first.StartsWith("_atom_site.") || first.StartsWith("_atom_site_");
                if (!isAtomLoop)
                {
                    // Skip rows until the next directive.
                    while (line != null && !line.TrimStart().StartsWith("_") && !line.TrimStart().StartsWith("loop_") && !line.TrimStart().StartsWith("data_"))
                    {
                        line = r.ReadLine();
                    }
                    inLoopHeader = false;
                    if (line == null) break;
                    // Rewind logic isn't possible with StreamReader;
                    // re-evaluate the current line by falling through.
                    if (line.TrimStart().Equals("loop_", StringComparison.Ordinal))
                    {
                        inLoopHeader = true;
                        loopColumns.Clear();
                    }
                    continue;
                }

                // Find column indices we care about.
                int idxX = FindColumn(loopColumns, "Cartn_x", "x");
                int idxY = FindColumn(loopColumns, "Cartn_y", "y");
                int idxZ = FindColumn(loopColumns, "Cartn_z", "z");
                int idxSymbol = FindColumn(loopColumns, "type_symbol");
                int idxLabel  = FindColumn(loopColumns, "label_atom_id", "auth_atom_id");
                if (idxX < 0 || idxY < 0 || idxZ < 0) { inLoopHeader = false; continue; }

                // Read rows until we hit another directive / EOF.
                // CIF rows can wrap across multiple lines if a value
                // is quoted with semicolons - we don't bother with
                // that here since coordinates and elements never use
                // multi-line values.
                inLoopHeader = false;
                do
                {
                    var rowText = line!.Trim();
                    if (rowText.Length == 0 || rowText.StartsWith("#")) continue;
                    if (rowText.StartsWith("_") || rowText.StartsWith("loop_") || rowText.StartsWith("data_")) break;
                    var parts = rowText.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length <= Math.Max(idxX, Math.Max(idxY, idxZ))) continue;
                    if (!float.TryParse(parts[idxX], NumberStyles.Float, CultureInfo.InvariantCulture, out var x)) continue;
                    if (!float.TryParse(parts[idxY], NumberStyles.Float, CultureInfo.InvariantCulture, out var y)) continue;
                    if (!float.TryParse(parts[idxZ], NumberStyles.Float, CultureInfo.InvariantCulture, out var z)) continue;
                    string element = "";
                    if (idxSymbol >= 0 && idxSymbol < parts.Length) element = parts[idxSymbol];
                    else if (idxLabel >= 0 && idxLabel < parts.Length)
                        element = ExtractElementFromAtomName(parts[idxLabel].Trim('"', '\''));
                    if (string.IsNullOrEmpty(element)) element = "C";
                    atoms.Add(new Atom(x, y, z, element));
                    if (atoms.Count >= MaxAtoms) return atoms;
                } while ((line = r.ReadLine()) != null);
                break;
            }
        }
        return atoms;
    }

    private static int FindColumn(List<string> cols, params string[] candidates)
    {
        for (int i = 0; i < cols.Count; i++)
        {
            var name = cols[i];
            // Strip "_atom_site." / "_atom_site_" / "_" prefixes.
            var dot = name.IndexOf('.');
            string bare = dot >= 0 ? name.Substring(dot + 1) : name.TrimStart('_');
            // mmCIF uses Cartn_x; small-molecule CIF uses atom_site_fract_x or atom_site_Cartn_x
            // - we already stripped the leading _atom_site_ above when dot < 0.
            if (bare.StartsWith("atom_site_")) bare = bare.Substring("atom_site_".Length);
            foreach (var c in candidates)
            {
                if (string.Equals(bare, c, StringComparison.OrdinalIgnoreCase))
                    return i;
            }
        }
        return -1;
    }

    /// <summary>
    /// Parse the atoms section of a Gaussian Cube file. The header
    /// has line 3 = (natoms, originX, originY, originZ) and lines 4
    /// through (4 + |natoms| - 1) listing one atom each (atomic
    /// number, charge, x, y, z) in Bohr radii. We convert Bohr to
    /// Angstroms (* 0.529177) so the renderer's scale matches the
    /// other formats.
    /// </summary>
    private static List<Atom> ParseCube(StreamReader r)
    {
        var atoms = new List<Atom>();
        r.ReadLine(); r.ReadLine();   // two comment lines
        var nAtomsLine = r.ReadLine();
        if (nAtomsLine == null) return atoms;
        var parts = nAtomsLine.Trim().Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 1) return atoms;
        if (!int.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var nAtomsRaw)) return atoms;
        // Cube format encodes "negative natoms = volumetric data follows"
        // but the absolute count still applies for atom rows.
        int nAtoms = Math.Min(Math.Abs(nAtomsRaw), MaxAtoms);
        // Skip the three voxel-axis lines.
        r.ReadLine(); r.ReadLine(); r.ReadLine();
        const float bohrToAngstrom = 0.529177f;
        for (int i = 0; i < nAtoms; i++)
        {
            var line = r.ReadLine();
            if (line == null) break;
            var p = line.Trim().Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
            if (p.Length < 5) continue;
            if (!int.TryParse(p[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var atomicNumber)) continue;
            if (!float.TryParse(p[2], NumberStyles.Float, CultureInfo.InvariantCulture, out var x)) continue;
            if (!float.TryParse(p[3], NumberStyles.Float, CultureInfo.InvariantCulture, out var y)) continue;
            if (!float.TryParse(p[4], NumberStyles.Float, CultureInfo.InvariantCulture, out var z)) continue;
            atoms.Add(new Atom(x * bohrToAngstrom, y * bohrToAngstrom, z * bohrToAngstrom,
                               AtomicNumberToElement(atomicNumber)));
        }
        return atoms;
    }

    private static string AtomicNumberToElement(int z)
    {
        // Compact periodic table for the most common biology /
        // chemistry elements. Out-of-range falls back to "C" so the
        // renderer still produces something at thumbnail size.
        switch (z)
        {
            case  1: return "H";  case  2: return "He"; case  3: return "Li";
            case  4: return "Be"; case  5: return "B";  case  6: return "C";
            case  7: return "N";  case  8: return "O";  case  9: return "F";
            case 10: return "Ne"; case 11: return "Na"; case 12: return "Mg";
            case 13: return "Al"; case 14: return "Si"; case 15: return "P";
            case 16: return "S";  case 17: return "Cl"; case 18: return "Ar";
            case 19: return "K";  case 20: return "Ca"; case 25: return "Mn";
            case 26: return "Fe"; case 29: return "Cu"; case 30: return "Zn";
            case 35: return "Br"; case 53: return "I";
            default: return "C";
        }
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
