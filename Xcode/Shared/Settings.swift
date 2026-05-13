//
//  Settings.swift
//  QuickLookProtein
//
//  Created by Jethro Hemmann on 22.08.21.
//

import Foundation
import SwiftUI

/// Persistence + change-publishing for every user-tunable preview setting.
///
/// Originally implemented with `@AppStorage` properties on this ObservableObject.
/// That subtly fails on macOS 11/12: `@AppStorage` is a `DynamicProperty` designed
/// for use *inside a View*, and when placed on a class it writes to UserDefaults
/// but never invokes `objectWillChange.send()` on its enclosing ObservableObject.
/// Result: a Picker bound to `$userSettings.atomStylePDB` flips a UserDefaults
/// value but the View hosting `@StateObject var userSettings` never re-renders,
/// so the WebView keeps showing the old structure.
///
/// Fix: replace every `@AppStorage` with a manually persisted `@Published`
/// property whose `didSet` writes the new value back into UserDefaults. Reads
/// happen once in `init()` so the published value mirrors what's on disk. This
/// guarantees a Picker mutation triggers the standard ObservableObject ->
/// @StateObject -> View invalidation chain and the preview re-renders
/// immediately.
class SettingsStorage: ObservableObject {

    /// Shared preferences store, computed once at first access.
    ///
    /// We *try* the App Group container first so the main app and the
    /// QL/Thumbnail/Spotlight extensions can read each other's settings.
    /// On dev builds with auto-signing, App Group provisioning often
    /// silently fails — cfprefsd then logs
    /// `Using kCFPreferencesAnyUser with a container is only allowed
    /// for System Containers, detaching from cfprefsd` and rejects
    /// writes. To survive that we round-trip a probe key; if the write+
    /// read makes it back intact, the App Group is usable; otherwise we
    /// fall back to `UserDefaults.standard`. Cost of the fallback: settings
    /// won't sync between main app and extensions until the user adds the
    /// App Groups capability via Xcode UI — but everything inside the host
    /// app still works.
    static let preferencesStore: UserDefaults = {
        let groupID = "W3SKSV7VPT.group.com.jethrohemmann.QuickLookProtein"
        guard let group = UserDefaults(suiteName: groupID) else { return .standard }
        let probeKey = "_qlp_probe_v1"
        group.set(true, forKey: probeKey)
        let readBack = group.bool(forKey: probeKey)
        group.removeObject(forKey: probeKey)
        return readBack ? group : .standard
    }()

    // MARK: - Per-format atom display style
    @Published var atomStyleCIF:  Settings.AtomStyle { didSet { Self.write(atomStyleCIF,  forKey: "atomStyleCIF")  } }
    @Published var atomStylePDB:  Settings.AtomStyle { didSet { Self.write(atomStylePDB,  forKey: "atomStylePDB")  } }
    @Published var atomStyleSDF:  Settings.AtomStyle { didSet { Self.write(atomStyleSDF,  forKey: "atomStyleSDF")  } }
    @Published var atomStyleMOL2: Settings.AtomStyle { didSet { Self.write(atomStyleMOL2, forKey: "atomStyleMOL2") } }
    @Published var atomStyleXYZ:  Settings.AtomStyle { didSet { Self.write(atomStyleXYZ,  forKey: "atomStyleXYZ")  } }
    @Published var atomStyleMOL:  Settings.AtomStyle { didSet { Self.write(atomStyleMOL,  forKey: "atomStyleMOL")  } }
    @Published var atomStyleGRO:  Settings.AtomStyle { didSet { Self.write(atomStyleGRO,  forKey: "atomStyleGRO")  } }
    @Published var atomStyleCUBE: Settings.AtomStyle { didSet { Self.write(atomStyleCUBE, forKey: "atomStyleCUBE") } }

    // MARK: - Global rendering
    @Published var rotationSpeed:   Settings.RotationSpeed { didSet { Self.write(rotationSpeed,   forKey: "rotationSpeed")   } }
    @Published var colorScheme:     Settings.ColorScheme   { didSet { Self.write(colorScheme,     forKey: "colorScheme")     } }
    @Published var autoStyleHetero: Bool                   { didSet { Self.preferencesStore.set(autoStyleHetero, forKey: "autoStyleHetero") } }
    @Published var showSurface:     Bool                   { didSet { Self.preferencesStore.set(showSurface,     forKey: "showSurface")     } }
    @Published var hideHydrogens:   Bool                   { didSet { Self.preferencesStore.set(hideHydrogens,   forKey: "hideHydrogens")   } }
    @Published var showUnitCell:    Bool                   { didSet { Self.preferencesStore.set(showUnitCell,    forKey: "showUnitCell")    } }
    @Published var showInfoOverlay: Bool                   { didSet { Self.preferencesStore.set(showInfoOverlay, forKey: "showInfoOverlay") } }

    /// Initial zoom factor applied after 3Dmol's `viewer.zoomTo()` auto-fit.
    @Published var defaultZoom: Settings.DefaultZoom { didSet { Self.write(defaultZoom, forKey: "defaultZoom") } }

    // MARK: - Background color components
    @Published var bgColorRed:     Double { didSet { Self.preferencesStore.set(bgColorRed,     forKey: "bgColorRed")     } }
    @Published var bgColorGreen:   Double { didSet { Self.preferencesStore.set(bgColorGreen,   forKey: "bgColorGreen")   } }
    @Published var bgColorBlue:    Double { didSet { Self.preferencesStore.set(bgColorBlue,    forKey: "bgColorBlue")    } }
    @Published var bgColorOpacity: Double { didSet { Self.preferencesStore.set(bgColorOpacity, forKey: "bgColorOpacity") } }

    init() {
        let store = Self.preferencesStore
        self.atomStyleCIF    = Self.read(forKey: "atomStyleCIF",    default: .stick)
        self.atomStylePDB    = Self.read(forKey: "atomStylePDB",    default: .cartoon)
        self.atomStyleSDF    = Self.read(forKey: "atomStyleSDF",    default: .stick)
        self.atomStyleMOL2   = Self.read(forKey: "atomStyleMOL2",   default: .stick)
        self.atomStyleXYZ    = Self.read(forKey: "atomStyleXYZ",    default: .stick)
        self.atomStyleMOL    = Self.read(forKey: "atomStyleMOL",    default: .stick)
        self.atomStyleGRO    = Self.read(forKey: "atomStyleGRO",    default: .cartoon)
        self.atomStyleCUBE   = Self.read(forKey: "atomStyleCUBE",   default: .stick)
        self.rotationSpeed   = Self.read(forKey: "rotationSpeed",   default: .medium)
        self.colorScheme     = Self.read(forKey: "colorScheme",     default: .spectrum)
        self.defaultZoom     = Self.read(forKey: "defaultZoom",     default: .auto)
        self.autoStyleHetero = store.object(forKey: "autoStyleHetero") as? Bool ?? true
        self.showSurface     = store.bool(forKey: "showSurface")
        self.hideHydrogens   = store.bool(forKey: "hideHydrogens")
        self.showUnitCell    = store.bool(forKey: "showUnitCell")
        self.showInfoOverlay = store.object(forKey: "showInfoOverlay") as? Bool ?? true
        self.bgColorRed      = store.double(forKey: "bgColorRed")
        self.bgColorGreen    = store.double(forKey: "bgColorGreen")
        self.bgColorBlue     = store.double(forKey: "bgColorBlue")
        self.bgColorOpacity  = store.double(forKey: "bgColorOpacity")
    }

    /// Read a RawRepresentable (String-backed) enum from the shared store.
    /// Returns `default` on miss so missing keys land on the same defaults as
    /// the old @AppStorage declarations.
    private static func read<T: RawRepresentable>(forKey key: String, default fallback: T) -> T
        where T.RawValue == String {
        guard let raw = preferencesStore.string(forKey: key),
              let value = T(rawValue: raw) else { return fallback }
        return value
    }

    /// Persist a RawRepresentable as its raw string value.
    private static func write<T: RawRepresentable>(_ value: T, forKey key: String)
        where T.RawValue == String {
        preferencesStore.set(value.rawValue, forKey: key)
    }

    var bgColor: Color {
        get {
            Color(.sRGB, red: bgColorRed, green: bgColorGreen, blue: bgColorBlue, opacity: bgColorOpacity)
        }
        set {
            bgColorRed = newValue.components.red
            bgColorGreen = newValue.components.green
            bgColorBlue = newValue.components.blue
            bgColorOpacity = newValue.components.opacity
        }
    }

    /// Resolve the configured AtomStyle for a given file extension (lowercased, no dot).
    ///
    /// Small-molecule formats (PQR, VASP/POSCAR, CDJSON) default to `.stick`
    /// rather than falling through to `atomStylePDB`. The cartoon style requires
    /// protein backbone atoms (N/CA/C/O), so any small-molecule file that gets
    /// the cartoon treatment renders as an empty viewport. The viewer template
    /// has a `cartoon` → `stick` fallback gated on protein detection, but that
    /// gate trips on residue-name lookups (e.g. a PQR file using "MET" for
    /// methane is misclassified as methionine and gets cartoon), so we'd
    /// rather not rely on it.
    func atomStyle(forExtension ext: String) -> Settings.AtomStyle {
        switch ext.lowercased() {
        case "pdb", "ent", "pdbqt":  return atomStylePDB
        case "cif", "mmcif":         return atomStyleCIF
        case "sdf":                  return atomStyleSDF
        case "mol2":                 return atomStyleMOL2
        case "xyz":                  return atomStyleXYZ
        case "mol":                  return atomStyleMOL
        case "gro":                  return atomStyleGRO
        case "cube", "cub":          return atomStyleCUBE
        case "pqr":                  return .stick   // PQR is PDB-shaped but typically small molecules
        case "vasp", "poscar":       return .sphere  // VASP/POSCAR crystals — atoms-as-balls is the convention and renders even without bonds
        case "cdjson", "json":       return .stick   // ChemDoodle JSON small molecules
        case "mmtf":                 return .cartoon // MMTF is compressed PDB — same convention as PDB
        default:                     return .stick   // unknown small-molecule formats — better than empty
        }
    }
}

extension Color {
    var components: (red: Double, green: Double, blue: Double, opacity: Double) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var opacity: CGFloat = 0
        NSColor(self).getRed(&red, green: &green, blue: &blue, alpha: &opacity)
        return (Double(red), Double(green), Double(blue), Double(opacity))
    }
}

struct Settings {

    enum AtomStyle: String, CaseIterable, Identifiable {
        case cartoon = "Cartoon"
        case line = "Line"
        case stick = "Stick"
        case sphere = "Sphere"

        var id: AtomStyle { return self }

        /// 3Dmol.js style key — must match a property in the style spec object.
        var jsValue: String {
            switch self {
            case .cartoon: return "cartoon"
            case .line:    return "line"
            case .stick:   return "stick"
            case .sphere:  return "sphere"
            }
        }
    }

    enum ColorScheme: String, CaseIterable, Identifiable {
        case spectrum = "Spectrum (rainbow)"
        case chain    = "By chain"
        case element  = "By element (CPK)"
        case ssJmol   = "Secondary structure"
        case residue  = "By amino acid"

        var id: ColorScheme { return self }

        /// Token read by the JS in 3Dmol_viewer.html — keep in sync with the switch there.
        var jsValue: String {
            switch self {
            case .spectrum: return "spectrum"
            case .chain:    return "chain"
            case .element:  return "element"
            case .ssJmol:   return "ssJmol"
            case .residue:  return "residue"
            }
        }
    }

    /// Initial zoom factor applied *after* 3Dmol's auto-fit `zoomTo()`. A value
    /// > 1 zooms in (closer to the molecule); < 1 zooms out. `auto` skips the
    /// extra zoom call so 3Dmol's fitting heuristic decides framing alone.
    enum DefaultZoom: String, CaseIterable, Identifiable {
        case auto      = "Auto-fit"
        case zoom50    = "50%"
        case zoom75    = "75%"
        case zoom100   = "100%"
        case zoom125   = "125%"
        case zoom150   = "150%"
        case zoom200   = "200%"

        var id: DefaultZoom { return self }

        /// Numeric factor passed to `viewer.zoom(factor)` in the viewer
        /// template. `auto` returns 1.0 but the template skips the call
        /// entirely on that token; see {ZOOM_FACTOR} substitution.
        var factor: Double {
            switch self {
            case .auto:    return 1.0
            case .zoom50:  return 0.5
            case .zoom75:  return 0.75
            case .zoom100: return 1.0
            case .zoom125: return 1.25
            case .zoom150: return 1.5
            case .zoom200: return 2.0
            }
        }
    }

    enum RotationSpeed: String, CaseIterable, Identifiable {
        case noRotation = "No rotation"
        case slow = "Slow"
        case medium = "Medium"
        case fast = "Fast"

        var id: RotationSpeed { return self }

        func rotationSpeedNumber() -> Float {
            switch self {
            case .slow:       return 0.5
            case .medium:     return 1
            case .fast:       return 2
            case .noRotation: return 0
            }
        }
    }

    /// Maps a file extension to the format token that 3Dmol.js's `addModel` understands.
    /// Returns nil for unknown formats so the caller can surface an error.
    static func dataFormat(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "pdb", "ent":     return "pdb"
        case "pdbqt":          return "pdbqt"   // AutoDock / Vina docking output
        case "pqr":            return "pqr"     // PDB + per-atom charge/radius (APBS, PDB2PQR)
        case "cif", "mmcif":   return "cif"
        case "sdf":            return "sdf"
        case "mol":            return "sdf"     // 3Dmol parses single MOL via the SDF parser
        case "mol2":           return "mol2"
        case "xyz":            return "xyz"
        case "gro":            return "gro"
        case "prmtop", "top":  return "prmtop"  // AMBER topology
        case "cube", "cub":    return "cube"    // Gaussian volumetric
        case "vasp", "poscar": return "vasp"    // VASP / POSCAR
        case "cdjson", "json": return "cdjson"  // ChemDoodle JSON
        case "mmtf":           return "mmtf"    // RCSB compressed binary PDB
        default:               return nil
        }
    }
}
