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
    // Optional extra metadata captured from PDB only (other parsers
    // leave these defaults). The thumbnail renderer uses these to
    // detect protein backbone for cartoon-ribbon rendering: a CA atom
    // with a recognised amino-acid residue name flags the row as part
    // of a protein chain.
    public readonly string AtomName;     // e.g. "CA", "N", "O", "C"
    public readonly string ResidueName;  // e.g. "ALA", "MET"
    public readonly char   ChainId;      // e.g. 'A'
    public readonly int    ResidueSeq;   // residue number

    public Atom(float x, float y, float z, string e,
                string atomName = "", string residueName = "",
                char chainId = ' ', int residueSeq = 0)
    {
        X = x; Y = y; Z = z; Element = e;
        AtomName = atomName; ResidueName = residueName;
        ChainId = chainId; ResidueSeq = residueSeq;
    }
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
            "vasp" or "poscar"    => ParseVasp(reader),
            "cdjson" or "json"    => ParseCdjson(reader),
            _                     => null,
        };
    }

    /// <summary>
    /// Parse a VASP POSCAR / CONTCAR / .vasp file. The format is
    /// Fortran-flavoured fixed-column-ish: lattice vectors, optional
    /// element symbol line, atom counts per element, "Direct" or
    /// "Cartesian" mode flag, then coordinates. We handle both
    /// fractional ("Direct") and Cartesian modes - in the fractional
    /// case we multiply by the lattice matrix to get Angstroms.
    /// </summary>
    private static List<Atom> ParseVasp(StreamReader r)
    {
        var atoms = new List<Atom>();
        var comment = r.ReadLine();                          // line 1
        var scaleLine = r.ReadLine();                        // line 2
        if (scaleLine == null) return atoms;
        if (!float.TryParse(scaleLine.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var scale)) scale = 1f;

        // Lattice vectors (3 lines, three floats each).
        var lattice = new float[3, 3];
        for (int i = 0; i < 3; i++)
        {
            var line = r.ReadLine();
            if (line == null) return atoms;
            var p = line.Trim().Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
            if (p.Length < 3) return atoms;
            for (int j = 0; j < 3; j++)
                float.TryParse(p[j], NumberStyles.Float, CultureInfo.InvariantCulture, out lattice[i, j]);
        }

        // Next line is either element symbols (VASP 5+) or atom
        // counts (older format). Distinguish by trying to parse the
        // first token as an integer.
        var nextLine = r.ReadLine();
        if (nextLine == null) return atoms;
        var nextParts = nextLine.Trim().Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
        string[]? elementSymbols = null;
        string[] countParts;
        if (nextParts.Length > 0 && int.TryParse(nextParts[0], out _))
        {
            // Older format: no element line, counts are here. We'll
            // use the comment line as a hint - VASP convention is to
            // put space-separated element names there. Best-effort
            // only; if the comment isn't elements, we fall back to
            // "C" for everything.
            countParts = nextParts;
            if (!string.IsNullOrWhiteSpace(comment))
            {
                var c = comment!.Trim().Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                if (c.Length == countParts.Length) elementSymbols = c;
            }
        }
        else
        {
            elementSymbols = nextParts;
            var countLine = r.ReadLine();
            if (countLine == null) return atoms;
            countParts = countLine.Trim().Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
        }
        var counts = new int[countParts.Length];
        for (int i = 0; i < countParts.Length; i++)
            int.TryParse(countParts[i], out counts[i]);

        // Optional "Selective dynamics" line; skip it.
        var modeLine = r.ReadLine();
        if (modeLine != null && modeLine.Trim().StartsWith("S", StringComparison.OrdinalIgnoreCase))
            modeLine = r.ReadLine();
        if (modeLine == null) return atoms;
        bool fractional = modeLine.Trim().StartsWith("D", StringComparison.OrdinalIgnoreCase);

        // Read atom coordinates.
        for (int e = 0; e < counts.Length; e++)
        {
            string element = (elementSymbols != null && e < elementSymbols.Length)
                ? elementSymbols[e] : "C";
            for (int j = 0; j < counts[e] && atoms.Count < MaxAtoms; j++)
            {
                var line = r.ReadLine();
                if (line == null) return atoms;
                var p = line.Trim().Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                if (p.Length < 3) continue;
                if (!float.TryParse(p[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var a)) continue;
                if (!float.TryParse(p[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var b)) continue;
                if (!float.TryParse(p[2], NumberStyles.Float, CultureInfo.InvariantCulture, out var c)) continue;
                float x, y, z;
                if (fractional)
                {
                    // (a,b,c) are fractional - multiply by lattice.
                    x = scale * (a * lattice[0, 0] + b * lattice[1, 0] + c * lattice[2, 0]);
                    y = scale * (a * lattice[0, 1] + b * lattice[1, 1] + c * lattice[2, 1]);
                    z = scale * (a * lattice[0, 2] + b * lattice[1, 2] + c * lattice[2, 2]);
                }
                else
                {
                    x = a * scale; y = b * scale; z = c * scale;
                }
                atoms.Add(new Atom(x, y, z, element));
            }
        }
        return atoms;
    }

    /// <summary>
    /// Parse ChemDoodle JSON (.cdjson). The format is small enough
    /// that a hand-rolled scanner beats pulling in a full JSON
    /// library - we only need the `a` array (atoms) with x/y/z/l
    /// (label = element). DataContractJsonSerializer would also work
    /// but adds boilerplate type definitions for what's effectively
    /// five fields.
    /// </summary>
    private static List<Atom> ParseCdjson(StreamReader r)
    {
        var atoms = new List<Atom>();
        var text = r.ReadToEnd();
        if (string.IsNullOrWhiteSpace(text)) return atoms;
        // Find the "a":[ ... ] section.
        int aStart = IndexOfRegexLike(text, "\"a\"");
        if (aStart < 0) return atoms;
        int bracket = text.IndexOf('[', aStart);
        if (bracket < 0) return atoms;
        int depth = 0;
        int i = bracket;
        for (; i < text.Length; i++)
        {
            char ch = text[i];
            if (ch == '[') depth++;
            else if (ch == ']') { depth--; if (depth == 0) { i++; break; } }
            else if (ch == '{' && depth == 1)
            {
                int objStart = i;
                int objDepth = 0;
                int j = i;
                for (; j < text.Length; j++)
                {
                    if (text[j] == '{') objDepth++;
                    else if (text[j] == '}') { objDepth--; if (objDepth == 0) { j++; break; } }
                }
                var atomObj = text.Substring(objStart, j - objStart);
                if (TryParseCdjsonAtom(atomObj, out var atom))
                {
                    atoms.Add(atom);
                    if (atoms.Count >= MaxAtoms) return atoms;
                }
                i = j - 1;
            }
        }
        return atoms;
    }

    private static bool TryParseCdjsonAtom(string obj, out Atom atom)
    {
        atom = default;
        float x = 0, y = 0, z = 0;
        string el = "C";
        if (TryReadJsonFloat(obj, "\"x\"", out var fx)) x = fx;
        if (TryReadJsonFloat(obj, "\"y\"", out var fy)) y = fy;
        if (TryReadJsonFloat(obj, "\"z\"", out var fz)) z = fz;
        if (TryReadJsonString(obj, "\"l\"", out var lbl)) el = lbl;
        atom = new Atom(x, y, z, el);
        return true;
    }

    private static int IndexOfRegexLike(string text, string needle)
    {
        // Plain IndexOf wrapper - kept as its own method so the name
        // documents intent. Case-sensitive (JSON keys are).
        return text.IndexOf(needle, StringComparison.Ordinal);
    }

    private static bool TryReadJsonFloat(string obj, string key, out float value)
    {
        value = 0;
        int idx = obj.IndexOf(key, StringComparison.Ordinal);
        if (idx < 0) return false;
        int colon = obj.IndexOf(':', idx);
        if (colon < 0) return false;
        int end = obj.IndexOfAny(new[] { ',', '}' }, colon + 1);
        if (end < 0) end = obj.Length;
        var s = obj.Substring(colon + 1, end - colon - 1).Trim();
        return float.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out value);
    }

    private static bool TryReadJsonString(string obj, string key, out string value)
    {
        value = "";
        int idx = obj.IndexOf(key, StringComparison.Ordinal);
        if (idx < 0) return false;
        int colon = obj.IndexOf(':', idx);
        if (colon < 0) return false;
        int q1 = obj.IndexOf('"', colon + 1);
        if (q1 < 0) return false;
        int q2 = obj.IndexOf('"', q1 + 1);
        if (q2 < 0) return false;
        value = obj.Substring(q1 + 1, q2 - q1 - 1);
        return true;
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
            var atomName = line.Substring(12, 4).Trim();
            string element;
            if (line.Length >= 78)
            {
                element = line.Substring(76, 2).Trim();
                if (string.IsNullOrEmpty(element))
                    element = ExtractElementFromAtomName(atomName);
            }
            else
            {
                element = ExtractElementFromAtomName(atomName);
            }
            // Capture residue + chain so the renderer can spot
            // protein backbones (CA atoms in standard amino acids).
            string residueName = line.Length >= 20 ? line.Substring(17, 3).Trim() : "";
            char chainId = line.Length >= 22 ? line[21] : ' ';
            int residueSeq = 0;
            if (line.Length >= 26)
                int.TryParse(line.Substring(22, 4).Trim(), out residueSeq);
            atoms.Add(new Atom(x, y, z, element,
                               atomName, residueName, chainId, residueSeq));
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
