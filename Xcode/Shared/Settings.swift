//
//  Settings.swift
//  QuickLookProtein
//
//  Created by Jethro Hemmann on 22.08.21.
//

import Foundation
import SwiftUI

class SettingsStorage: ObservableObject {

    /// Shared preferences store, computed once at first access.
    ///
    /// We *try* the App Group container first so the main app and the
    /// QL/Thumbnail/Spotlight extensions can read each other's settings.
    /// On dev builds with auto-signing, App Group provisioning often
    /// silently fails — cfprefsd then logs
    /// `Using kCFPreferencesAnyUser with a container is only allowed
    /// for System Containers, detaching from cfprefsd` and rejects
    /// writes, which means @AppStorage Picker changes never persist
    /// and the previews never update.
    ///
    /// To survive that, we round-trip a probe key. If the write+read
    /// makes it back intact, the App Group is usable; otherwise we
    /// fall back to `UserDefaults.standard`. The cost of the fallback
    /// is that settings won't sync between main app and extensions
    /// until the user adds the App Groups capability via Xcode UI —
    /// but at least everything inside the host app works.
    static let preferencesStore: UserDefaults = {
        let groupID = "FF68N39FU5.group.com.ariomoniri.QuickLookProtein"
        guard let group = UserDefaults(suiteName: groupID) else { return .standard }
        let probeKey = "_qlp_probe_v1"
        group.set(true, forKey: probeKey)
        let readBack = group.bool(forKey: probeKey)
        group.removeObject(forKey: probeKey)
        return readBack ? group : .standard
    }()

    // MARK: - Per-format atom display style
    @AppStorage("atomStyleCIF", store: SettingsStorage.preferencesStore)
    var atomStyleCIF: Settings.AtomStyle = .stick
    @AppStorage("atomStylePDB", store: SettingsStorage.preferencesStore)
    var atomStylePDB: Settings.AtomStyle = .cartoon
    @AppStorage("atomStyleSDF", store: SettingsStorage.preferencesStore)
    var atomStyleSDF: Settings.AtomStyle = .stick
    @AppStorage("atomStyleMOL2", store: SettingsStorage.preferencesStore)
    var atomStyleMOL2: Settings.AtomStyle = .stick
    @AppStorage("atomStyleXYZ", store: SettingsStorage.preferencesStore)
    var atomStyleXYZ: Settings.AtomStyle = .stick
    @AppStorage("atomStyleMOL", store: SettingsStorage.preferencesStore)
    var atomStyleMOL: Settings.AtomStyle = .stick
    @AppStorage("atomStyleGRO", store: SettingsStorage.preferencesStore)
    var atomStyleGRO: Settings.AtomStyle = .cartoon
    @AppStorage("atomStyleCUBE", store: SettingsStorage.preferencesStore)
    var atomStyleCUBE: Settings.AtomStyle = .stick

    // MARK: - Global rendering
    @AppStorage("rotationSpeed", store: SettingsStorage.preferencesStore)
    var rotationSpeed: Settings.RotationSpeed = .medium
    @AppStorage("colorScheme", store: SettingsStorage.preferencesStore)
    var colorScheme: Settings.ColorScheme = .spectrum
    @AppStorage("autoStyleHetero", store: SettingsStorage.preferencesStore)
    var autoStyleHetero: Bool = true
    @AppStorage("showSurface", store: SettingsStorage.preferencesStore)
    var showSurface: Bool = false
    @AppStorage("hideHydrogens", store: SettingsStorage.preferencesStore)
    var hideHydrogens: Bool = false
    @AppStorage("showUnitCell", store: SettingsStorage.preferencesStore)
    var showUnitCell: Bool = false
    @AppStorage("showInfoOverlay", store: SettingsStorage.preferencesStore)
    var showInfoOverlay: Bool = true

    /// Initial zoom factor applied after 3Dmol's `viewer.zoomTo()` auto-fit.
    /// Lets the user open Quick Look previews wider or tighter on the molecule
    /// without manually scrolling to zoom every time.
    @AppStorage("defaultZoom", store: SettingsStorage.preferencesStore)
    var defaultZoom: Settings.DefaultZoom = .auto

    // MARK: - Background color components
    @AppStorage("bgColorRed", store: SettingsStorage.preferencesStore)
    var bgColorRed: Double = 0.0
    @AppStorage("bgColorGreen", store: SettingsStorage.preferencesStore)
    var bgColorGreen: Double = 0.0
    @AppStorage("bgColorBlue", store: SettingsStorage.preferencesStore)
    var bgColorBlue: Double = 0.0
    @AppStorage("bgColorOpacity", store: SettingsStorage.preferencesStore)
    var bgColorOpacity: Double = 0.0

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
        default:                     return atomStylePDB
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
        default:               return nil
        }
    }
}
