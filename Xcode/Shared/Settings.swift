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
        let groupID = "FF68N39FU5.group.com.ariomoniri.QuickLookProtein"
        guard let group = UserDefaults(suiteName: groupID) else { return .standard }
        let probeKey = "_qlp_probe_v1"
        group.set(true, forKey: probeKey)
        let readBack = group.bool(forKey: probeKey)
        group.removeObject(forKey: probeKey)
        return readBack ? group : .standard
    }()

    // MARK: - Per-format atom display style
    @Published var atomStyleCIF:    Settings.AtomStyle { didSet { Self.write(atomStyleCIF,    forKey: "atomStyleCIF")    } }
    @Published var atomStylePDB:    Settings.AtomStyle { didSet { Self.write(atomStylePDB,    forKey: "atomStylePDB")    } }
    @Published var atomStyleSDF:    Settings.AtomStyle { didSet { Self.write(atomStyleSDF,    forKey: "atomStyleSDF")    } }
    @Published var atomStyleMOL2:   Settings.AtomStyle { didSet { Self.write(atomStyleMOL2,   forKey: "atomStyleMOL2")   } }
    @Published var atomStyleXYZ:    Settings.AtomStyle { didSet { Self.write(atomStyleXYZ,    forKey: "atomStyleXYZ")    } }
    @Published var atomStyleMOL:    Settings.AtomStyle { didSet { Self.write(atomStyleMOL,    forKey: "atomStyleMOL")    } }
    @Published var atomStyleGRO:    Settings.AtomStyle { didSet { Self.write(atomStyleGRO,    forKey: "atomStyleGRO")    } }
    @Published var atomStyleCUBE:   Settings.AtomStyle { didSet { Self.write(atomStyleCUBE,   forKey: "atomStyleCUBE")   } }
    @Published var atomStylePQR:    Settings.AtomStyle { didSet { Self.write(atomStylePQR,    forKey: "atomStylePQR")    } }
    @Published var atomStyleVASP:   Settings.AtomStyle { didSet { Self.write(atomStyleVASP,   forKey: "atomStyleVASP")   } }
    @Published var atomStyleCDJSON: Settings.AtomStyle { didSet { Self.write(atomStyleCDJSON, forKey: "atomStyleCDJSON") } }
    @Published var atomStyleMMTF:   Settings.AtomStyle { didSet { Self.write(atomStyleMMTF,   forKey: "atomStyleMMTF")   } }

    // MARK: - App appearance (v1.7.81+)
    // Defaults to .system so first-launch tracks the user's macOS
    // Appearance setting. .preferredColorScheme(nil) is the SwiftUI
    // "follow system" sentinel and is what the ContentView applies
    // when this is .system.
    @Published var appearanceMode:  Settings.AppearanceMode { didSet { Self.write(appearanceMode,  forKey: "appearanceMode")  } }

    // MARK: - Global rendering
    @Published var rotationSpeed:   Settings.RotationSpeed { didSet { Self.write(rotationSpeed,   forKey: "rotationSpeed")   } }
    @Published var colorScheme:     Settings.ColorScheme   { didSet { Self.write(colorScheme,     forKey: "colorScheme")     } }
    @Published var autoStyleHetero: Bool                   { didSet { Self.preferencesStore.set(autoStyleHetero, forKey: "autoStyleHetero") } }
    @Published var showSurface:     Bool                   { didSet { Self.preferencesStore.set(showSurface,     forKey: "showSurface")     } }
    @Published var hideHydrogens:   Bool                   { didSet { Self.preferencesStore.set(hideHydrogens,   forKey: "hideHydrogens")   } }
    @Published var showUnitCell:    Bool                   { didSet { Self.preferencesStore.set(showUnitCell,    forKey: "showUnitCell")    } }
    @Published var showInfoOverlay: Bool                   { didSet { Self.preferencesStore.set(showInfoOverlay, forKey: "showInfoOverlay") } }

    // MARK: - Info overlay fields
    //
    // The overlay was always "filename · atoms · chains · format" -
    // users asked for finer control over what shows. Each field
    // below is a separate toggle so they can build whatever info
    // strip they want. All default to the previous behaviour for
    // back-compat: filename / atoms / chains / format ON, everything
    // else OFF.
    @Published var infoShowFileName:        Bool { didSet { Self.preferencesStore.set(infoShowFileName,        forKey: "infoShowFileName") } }
    @Published var infoShowAtomCount:       Bool { didSet { Self.preferencesStore.set(infoShowAtomCount,       forKey: "infoShowAtomCount") } }
    @Published var infoShowChainCount:      Bool { didSet { Self.preferencesStore.set(infoShowChainCount,      forKey: "infoShowChainCount") } }
    @Published var infoShowFormat:          Bool { didSet { Self.preferencesStore.set(infoShowFormat,          forKey: "infoShowFormat") } }
    @Published var infoShowResidueCount:    Bool { didSet { Self.preferencesStore.set(infoShowResidueCount,    forKey: "infoShowResidueCount") } }
    @Published var infoShowElementBreakdown:Bool { didSet { Self.preferencesStore.set(infoShowElementBreakdown,forKey: "infoShowElementBreakdown") } }
    @Published var infoShowMolWeight:       Bool { didSet { Self.preferencesStore.set(infoShowMolWeight,       forKey: "infoShowMolWeight") } }
    @Published var infoShowBondCount:       Bool { didSet { Self.preferencesStore.set(infoShowBondCount,       forKey: "infoShowBondCount") } }
    @Published var infoShowPDBTitle:        Bool { didSet { Self.preferencesStore.set(infoShowPDBTitle,        forKey: "infoShowPDBTitle") } }

    // Interactive 3Dmol control toolbar shown bottom-right of every
    // Quick Look preview (1.7.27+). Lets the user re-style, toggle
    // surface, color by secondary structure, label alpha-carbons, or
    // recenter without leaving Quick Look. Default ON.
    @Published var showControlsInPreview: Bool { didSet { Self.preferencesStore.set(showControlsInPreview, forKey: "showControlsInPreview") } }

    // Per-button toolbar visibility (1.7.29+). User can hide any
    // individual button so the toolbar stays compact on small
    // previews. All default ON.
    @Published var ctlShowStick:    Bool { didSet { Self.preferencesStore.set(ctlShowStick,    forKey: "ctlShowStick") } }
    @Published var ctlShowLine:     Bool { didSet { Self.preferencesStore.set(ctlShowLine,     forKey: "ctlShowLine") } }
    @Published var ctlShowSphere:   Bool { didSet { Self.preferencesStore.set(ctlShowSphere,   forKey: "ctlShowSphere") } }
    @Published var ctlShowCartoon:  Bool { didSet { Self.preferencesStore.set(ctlShowCartoon,  forKey: "ctlShowCartoon") } }
    @Published var ctlShowSurface:  Bool { didSet { Self.preferencesStore.set(ctlShowSurface,  forKey: "ctlShowSurface") } }
    @Published var ctlShowColorSS:  Bool { didSet { Self.preferencesStore.set(ctlShowColorSS,  forKey: "ctlShowColorSS") } }
    @Published var ctlShowLabelCA:  Bool { didSet { Self.preferencesStore.set(ctlShowLabelCA,  forKey: "ctlShowLabelCA") } }
    @Published var ctlShowRecenter: Bool { didSet { Self.preferencesStore.set(ctlShowRecenter, forKey: "ctlShowRecenter") } }
    @Published var ctlShowRotation: Bool { didSet { Self.preferencesStore.set(ctlShowRotation, forKey: "ctlShowRotation") } }

    // Master enable (1.7.48+). When OFF, the QL extension renders an info
    // panel instead of running the WebView preview pipeline. Useful while
    // troubleshooting a misbehaving 3Dmol render without uninstalling.
    @Published var masterEnabled: Bool { didSet { Self.preferencesStore.set(masterEnabled, forKey: "masterEnabled") } }
    // "Run on first preview" — when OFF, skip the rendering pipeline for the
    // very first Finder-spacebar of a new file path (show a tap-to-render
    // placeholder instead). Most users want ON; OFF helps on slow disks /
    // large files where the initial parse can stall the QL window.
    @Published var runOnFirstPreview: Bool { didSet { Self.preferencesStore.set(runOnFirstPreview, forKey: "runOnFirstPreview") } }

    // Per-format enable flags (1.7.48+). When a format's flag is OFF, the
    // QL extension still claims the UTI (we can't unregister at runtime —
    // UTIs are baked into Info.plist) but renders a "disabled in Settings"
    // info panel instead of the molecule. Lets power users selectively
    // disable formats that conflict with other tools.
    @Published var formatEnabledPDB:    Bool { didSet { Self.preferencesStore.set(formatEnabledPDB,    forKey: "formatEnabledPDB") } }
    @Published var formatEnabledCIF:    Bool { didSet { Self.preferencesStore.set(formatEnabledCIF,    forKey: "formatEnabledCIF") } }
    @Published var formatEnabledSDF:    Bool { didSet { Self.preferencesStore.set(formatEnabledSDF,    forKey: "formatEnabledSDF") } }
    @Published var formatEnabledMOL:    Bool { didSet { Self.preferencesStore.set(formatEnabledMOL,    forKey: "formatEnabledMOL") } }
    @Published var formatEnabledMOL2:   Bool { didSet { Self.preferencesStore.set(formatEnabledMOL2,   forKey: "formatEnabledMOL2") } }
    @Published var formatEnabledXYZ:    Bool { didSet { Self.preferencesStore.set(formatEnabledXYZ,    forKey: "formatEnabledXYZ") } }
    @Published var formatEnabledGRO:    Bool { didSet { Self.preferencesStore.set(formatEnabledGRO,    forKey: "formatEnabledGRO") } }
    @Published var formatEnabledCUBE:   Bool { didSet { Self.preferencesStore.set(formatEnabledCUBE,   forKey: "formatEnabledCUBE") } }
    @Published var formatEnabledPQR:    Bool { didSet { Self.preferencesStore.set(formatEnabledPQR,    forKey: "formatEnabledPQR") } }
    @Published var formatEnabledVASP:   Bool { didSet { Self.preferencesStore.set(formatEnabledVASP,   forKey: "formatEnabledVASP") } }
    @Published var formatEnabledCDJSON: Bool { didSet { Self.preferencesStore.set(formatEnabledCDJSON, forKey: "formatEnabledCDJSON") } }
    @Published var formatEnabledMMTF:   Bool { didSet { Self.preferencesStore.set(formatEnabledMMTF,   forKey: "formatEnabledMMTF") } }

    /// Returns whether the given filename extension's format is enabled.
    /// Used by the QL extension to gate rendering. Unknown extensions
    /// default to enabled so the cryo-EM / trajectory / .gjf paths still
    /// work without separate flags.
    func formatEnabled(forExtension ext: String) -> Bool {
        switch ext.lowercased() {
        case "pdb", "ent", "pdbqt":      return formatEnabledPDB
        case "cif", "mmcif":             return formatEnabledCIF
        case "sdf":                      return formatEnabledSDF
        case "mol":                      return formatEnabledMOL
        case "mol2":                     return formatEnabledMOL2
        case "xyz":                      return formatEnabledXYZ
        case "gro":                      return formatEnabledGRO
        case "cube", "cub":              return formatEnabledCUBE
        case "pqr":                      return formatEnabledPQR
        case "vasp", "poscar":           return formatEnabledVASP
        case "cdjson":                   return formatEnabledCDJSON
        case "mmtf":                     return formatEnabledMMTF
        default:                         return true
        }
    }

    // Outline shading: 3Dmol's `style: { outline: true }` flag. Adds a
    // thin black border around each atom/bond, makes the preview
    // pop on light backgrounds. Default OFF.
    @Published var outlineShading:  Bool { didSet { Self.preferencesStore.set(outlineShading,  forKey: "outlineShading") } }

    // Ambient occlusion (1.7.39+). A radial-gradient CSS inset shadow
    // over the WebGL canvas that darkens edges, giving a pseudo-AO
    // effect that visually deepens crevices in protein surfaces without
    // a real postprocess pass. Cheap; degrades to a no-op overlay on
    // small molecules. Default ON.
    @Published var ambientOcclusion: Bool { didSet { Self.preferencesStore.set(ambientOcclusion, forKey: "ambientOcclusion") } }

    // Auto-orient (1.7.30+): rotate the molecule so its longest
    // principal axis is horizontal. Computed from the atom-coord
    // covariance matrix via a small 3x3 power-iteration eigendecomp
    // in viewer.html. Default OFF (3Dmol's zoomTo() picks an OK
    // default orientation; this is for users who want a deterministic
    // canonical pose, e.g. for screenshots).
    @Published var autoOrient:      Bool { didSet { Self.preferencesStore.set(autoOrient,      forKey: "autoOrient") } }

    // Cube isosurface (1.7.30+): render .cube files as a real
    // volumetric isosurface instead of just the atom skeleton.
    // Pretty when on; expensive at the iso-level if the cube is
    // dense. Default OFF.
    @Published var cubeIsosurface:  Bool { didSet { Self.preferencesStore.set(cubeIsosurface,  forKey: "cubeIsosurface") } }

    // Biological assembly (1.7.31+): expand PDB / CIF asymmetric
    // units into their biological assembly using REMARK 350 (PDB)
    // or _pdbx_struct_assembly_gen / _pdbx_struct_oper_list (CIF)
    // transformation records. Default ON - matches what RCSB and
    // most molecular viewers show by default for entries with a
    // documented biological assembly.
    @Published var bioAssembly:     Bool { didSet { Self.preferencesStore.set(bioAssembly,     forKey: "bioAssembly") } }

    // Cryo-EM density isosurface (1.7.32+). When ON, .ccp4/.mrc/.map
    // files render as a volumetric isosurface (the user-set sigma
    // level below) instead of failing to open. Default ON.
    @Published var cryoEMRender:    Bool   { didSet { Self.preferencesStore.set(cryoEMRender, forKey: "cryoEMRender") } }
    /// Isosurface level in units of the map's σ (one standard
    /// deviation above the mean grid value). EMDB recommends σ ≈ 2.5
    /// for typical maps; users can override.
    @Published var cryoEMSigma:     Double { didSet { Self.preferencesStore.set(cryoEMSigma,  forKey: "cryoEMSigma") } }

    // Share button in the preview (1.7.33+). When ON, the toolbar
    // grows a 📤 button that hands the current render to macOS's
    // NSSharingServicePicker (so users can airdrop / mail / save the
    // PNG without leaving QuickLook). Default ON.
    @Published var showShareButton: Bool { didSet { Self.preferencesStore.set(showShareButton, forKey: "showShareButton") } }

    // Include USDZ in the share payload (1.7.42+). When ON and the
    // share button is used, we also export a `.usdz` file alongside
    // the PNG so AirDropping to an iPad lets the recipient open the
    // molecule in AR Quick Look. Skipped automatically for structures
    // above USDZExporter.softAtomCap to keep file size sane. Default
    // ON — the USDZ file is small (a few hundred KB for typical
    // small molecules / protein chains) and the AR demo is the
    // marquee 1.7.42 feature.
    @Published var includeUSDZInShare: Bool { didSet { Self.preferencesStore.set(includeUSDZInShare, forKey: "includeUSDZInShare") } }

    // Animated APNG thumbnails (1.7.35+). Default OFF. macOS Finder does NOT
    // animate APNG thumbnails in stock builds, so this is shipped as an
    // experimental toggle: the file is a valid APNG (animates anywhere that
    // honours the format), the still preview Finder shows is the first
    // rotated frame. Rendering 12 frames takes ~12x as long as a single
    // thumbnail, so the user should opt in deliberately.
    @Published var animatedThumbnails: Bool { didSet { Self.preferencesStore.set(animatedThumbnails, forKey: "animatedThumbnails") } }

    // Thumbnail style override (1.7.37+). Default `.auto` preserves the
    // existing heuristic; users can pin to CPK or ribbon for every file.
    @Published var thumbnailStyle: Settings.ThumbnailStyle {
        didSet { Self.write(thumbnailStyle, forKey: "thumbnailStyle") }
    }

    // MARK: - Multi-file Quick Look behaviour
    //
    // Persisted preference for what to do when the user spacebars
    // multiple files in Finder. Quick Look's `<` `>` navigation is
    // built in - we can't disable it - but we *can* offer a "merge
    // siblings in same folder" mode where the QL extension reads
    // sibling structures and loads them all into one 3Dmol scene.
    // Default is .separate (current behaviour, native QL nav).
    @Published var multiFilePreviewMode: Settings.MultiFilePreviewMode {
        didSet { Self.write(multiFilePreviewMode, forKey: "multiFilePreviewMode") }
    }

    /// Initial zoom factor applied after 3Dmol's `viewer.zoomTo()` auto-fit.
    @Published var defaultZoom: Settings.DefaultZoom { didSet { Self.write(defaultZoom, forKey: "defaultZoom") } }

    // MARK: - Background color components
    @Published var bgColorRed:     Double { didSet { Self.preferencesStore.set(bgColorRed,     forKey: "bgColorRed")     } }
    @Published var bgColorGreen:   Double { didSet { Self.preferencesStore.set(bgColorGreen,   forKey: "bgColorGreen")   } }
    @Published var bgColorBlue:    Double { didSet { Self.preferencesStore.set(bgColorBlue,    forKey: "bgColorBlue")    } }
    @Published var bgColorOpacity: Double { didSet { Self.preferencesStore.set(bgColorOpacity, forKey: "bgColorOpacity") } }

    // MARK: - QL extension preview window size (1.7.75+)
    //
    // Apple's Quick Look uses preferredContentSize on the
    // QLPreviewProvider as a *hint* for the first time a UTI is
    // previewed on a fresh user account. After that, Finder
    // persists the user's last drag-resize per-UTI and ignores
    // this value (by design). So these settings are:
    //   1. The "first time" geometry on a clean install.
    //   2. The value Finder falls back to if its per-UTI state
    //      gets cleared (a user account migration, a system reset,
    //      etc.).
    // Defaults 560 x 420 match the Windows-side default so the
    // cross-platform first-launch experience is identical.
    @Published var previewWidth:  Double { didSet { Self.preferencesStore.set(previewWidth,  forKey: "previewWidth")  } }
    @Published var previewHeight: Double { didSet { Self.preferencesStore.set(previewHeight, forKey: "previewHeight") } }

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
        self.atomStylePQR    = Self.read(forKey: "atomStylePQR",    default: .stick)
        self.atomStyleVASP   = Self.read(forKey: "atomStyleVASP",   default: .sphere)
        self.atomStyleCDJSON = Self.read(forKey: "atomStyleCDJSON", default: .stick)
        self.atomStyleMMTF   = Self.read(forKey: "atomStyleMMTF",   default: .cartoon)
        self.appearanceMode  = Self.read(forKey: "appearanceMode",  default: .system)
        self.rotationSpeed   = Self.read(forKey: "rotationSpeed",   default: .medium)
        self.colorScheme     = Self.read(forKey: "colorScheme",     default: .spectrum)
        self.defaultZoom     = Self.read(forKey: "defaultZoom",     default: .auto)
        self.autoStyleHetero = store.object(forKey: "autoStyleHetero") as? Bool ?? true
        self.showSurface     = store.bool(forKey: "showSurface")
        self.hideHydrogens   = store.bool(forKey: "hideHydrogens")
        self.showUnitCell    = store.bool(forKey: "showUnitCell")
        self.showInfoOverlay = store.object(forKey: "showInfoOverlay") as? Bool ?? true

        // Info-overlay field toggles. Existing fields default ON
        // (preserves pre-1.7.19 overlay content); new fields default
        // OFF (avoids surprising existing users with extra clutter).
        self.infoShowFileName         = store.object(forKey: "infoShowFileName")         as? Bool ?? true
        self.infoShowAtomCount        = store.object(forKey: "infoShowAtomCount")        as? Bool ?? true
        self.infoShowChainCount       = store.object(forKey: "infoShowChainCount")       as? Bool ?? true
        self.infoShowFormat           = store.object(forKey: "infoShowFormat")           as? Bool ?? true
        self.infoShowResidueCount     = store.object(forKey: "infoShowResidueCount")     as? Bool ?? false
        self.infoShowElementBreakdown = store.object(forKey: "infoShowElementBreakdown") as? Bool ?? false
        self.infoShowMolWeight        = store.object(forKey: "infoShowMolWeight")        as? Bool ?? false
        self.infoShowBondCount        = store.object(forKey: "infoShowBondCount")        as? Bool ?? false
        self.infoShowPDBTitle         = store.object(forKey: "infoShowPDBTitle")         as? Bool ?? false
        self.showControlsInPreview    = store.object(forKey: "showControlsInPreview")    as? Bool ?? true
        self.ctlShowStick     = store.object(forKey: "ctlShowStick")     as? Bool ?? true
        self.ctlShowLine      = store.object(forKey: "ctlShowLine")      as? Bool ?? true
        self.ctlShowSphere    = store.object(forKey: "ctlShowSphere")    as? Bool ?? true
        self.ctlShowCartoon   = store.object(forKey: "ctlShowCartoon")   as? Bool ?? true
        self.ctlShowSurface   = store.object(forKey: "ctlShowSurface")   as? Bool ?? true
        self.ctlShowColorSS   = store.object(forKey: "ctlShowColorSS")   as? Bool ?? true
        self.ctlShowLabelCA   = store.object(forKey: "ctlShowLabelCA")   as? Bool ?? true
        self.ctlShowRecenter  = store.object(forKey: "ctlShowRecenter")  as? Bool ?? true
        self.ctlShowRotation  = store.object(forKey: "ctlShowRotation")  as? Bool ?? true
        self.masterEnabled      = store.object(forKey: "masterEnabled")      as? Bool ?? true
        self.runOnFirstPreview  = store.object(forKey: "runOnFirstPreview")  as? Bool ?? true
        self.formatEnabledPDB    = store.object(forKey: "formatEnabledPDB")    as? Bool ?? true
        self.formatEnabledCIF    = store.object(forKey: "formatEnabledCIF")    as? Bool ?? true
        self.formatEnabledSDF    = store.object(forKey: "formatEnabledSDF")    as? Bool ?? true
        self.formatEnabledMOL    = store.object(forKey: "formatEnabledMOL")    as? Bool ?? true
        self.formatEnabledMOL2   = store.object(forKey: "formatEnabledMOL2")   as? Bool ?? true
        self.formatEnabledXYZ    = store.object(forKey: "formatEnabledXYZ")    as? Bool ?? true
        self.formatEnabledGRO    = store.object(forKey: "formatEnabledGRO")    as? Bool ?? true
        self.formatEnabledCUBE   = store.object(forKey: "formatEnabledCUBE")   as? Bool ?? true
        self.formatEnabledPQR    = store.object(forKey: "formatEnabledPQR")    as? Bool ?? true
        self.formatEnabledVASP   = store.object(forKey: "formatEnabledVASP")   as? Bool ?? true
        self.formatEnabledCDJSON = store.object(forKey: "formatEnabledCDJSON") as? Bool ?? true
        self.formatEnabledMMTF   = store.object(forKey: "formatEnabledMMTF")   as? Bool ?? true
        self.outlineShading   = store.object(forKey: "outlineShading")   as? Bool ?? false
        self.ambientOcclusion = store.object(forKey: "ambientOcclusion") as? Bool ?? true
        self.autoOrient       = store.object(forKey: "autoOrient")       as? Bool ?? false
        self.cubeIsosurface   = store.object(forKey: "cubeIsosurface")   as? Bool ?? false
        self.bioAssembly      = store.object(forKey: "bioAssembly")      as? Bool ?? true
        self.cryoEMRender     = store.object(forKey: "cryoEMRender")     as? Bool ?? true
        self.cryoEMSigma      = (store.object(forKey: "cryoEMSigma")     as? Double) ?? 2.5
        self.showShareButton  = store.object(forKey: "showShareButton")  as? Bool ?? true
        self.includeUSDZInShare = store.object(forKey: "includeUSDZInShare") as? Bool ?? true
        self.animatedThumbnails = store.object(forKey: "animatedThumbnails") as? Bool ?? false
        self.thumbnailStyle     = Self.read(forKey: "thumbnailStyle", default: .auto)

        self.multiFilePreviewMode = Self.read(forKey: "multiFilePreviewMode", default: .separate)

        self.bgColorRed      = store.double(forKey: "bgColorRed")
        self.bgColorGreen    = store.double(forKey: "bgColorGreen")
        self.bgColorBlue     = store.double(forKey: "bgColorBlue")
        self.bgColorOpacity  = store.double(forKey: "bgColorOpacity")

        // Preview window size (1.7.75+). UserDefaults.double returns
        // 0.0 for unset keys, which would size the QL preview to
        // nothing; substitute the in-tree default in that case.
        // Min/max clamp prevents nonsense values from a manually
        // edited preferences plist.
        let pw = store.double(forKey: "previewWidth")
        let ph = store.double(forKey: "previewHeight")
        self.previewWidth  = pw < 240 ? 560 : min(pw, 4000)
        self.previewHeight = ph < 180 ? 420 : min(ph, 4000)
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
        case "pqr":                  return atomStylePQR
        case "vasp", "poscar":       return atomStyleVASP
        case "cdjson", "json":       return atomStyleCDJSON
        case "mmtf":                 return atomStyleMMTF
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
        // B-factor coloring. For X-ray structures this is thermal
        // motion (blue = stiff, red = flexible). For AlphaFold-style
        // predicted models, B-factor holds the pLDDT confidence
        // score (0..100, higher = more confident), so this
        // doubles as a confidence-coloring mode.
        case bfactor  = "By B-factor / pLDDT"

        var id: ColorScheme { return self }

        /// Token read by the JS in 3Dmol_viewer.html — keep in sync with the switch there.
        var jsValue: String {
            switch self {
            case .spectrum: return "spectrum"
            case .chain:    return "chain"
            case .element:  return "element"
            case .ssJmol:   return "ssJmol"
            case .residue:  return "residue"
            case .bfactor:  return "bfactor"
            }
        }
    }

    /// Initial zoom factor applied *after* 3Dmol's auto-fit `zoomTo()`. A value
    /// > 1 zooms in (closer to the molecule); < 1 zooms out. `auto` skips the
    /// extra zoom call so 3Dmol's fitting heuristic decides framing alone.
    /// What to do when the user spacebars several files in Finder.
    /// `separate` is the native Quick Look behaviour: each file gets
    /// its own preview, with `<` `>` arrows in the QL chrome to
    /// navigate between them. `mergeFolder` tells the QL extension
    /// to ALSO load every other supported structure in the same
    /// folder into the current preview, overlaying them in one
    /// 3Dmol scene. Useful when comparing related structures (e.g.
    /// a set of docking poses).
    enum MultiFilePreviewMode: String, CaseIterable, Identifiable {
        case separate     = "Separate windows (default)"
        case mergeFolder  = "Merge all in same folder"

        var id: MultiFilePreviewMode { return self }
    }

    /// Thumbnail render style override. `.auto` keeps the existing Cα-count
    /// heuristic (ribbon for ≥25 Cα, otherwise CPK spheres). The explicit
    /// modes let power users pick what shows in Finder for every structure.
    enum ThumbnailStyle: String, CaseIterable, Identifiable {
        case auto   = "Auto (detect)"
        case cpk    = "CPK spheres"
        case ribbon = "Cartoon ribbon"

        var id: ThumbnailStyle { return self }
    }

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

    /// App appearance preference (v1.7.81+). "System" follows the
    /// macOS dark/light setting via SwiftUI's default behaviour;
    /// Light/Dark override unconditionally via .preferredColorScheme.
    /// Stored as a RawRepresentable enum so the userdefaults round-
    /// trip survives a string-typed write.
    enum AppearanceMode: String, CaseIterable, Identifiable {
        case system = "System"
        case light  = "Light"
        case dark   = "Dark"

        var id: AppearanceMode { return self }

        /// Maps to the SwiftUI value: nil ⇒ "follow system".
        var colorScheme: SwiftUI.ColorScheme? {
            switch self {
            case .system: return nil
            case .light:  return .light
            case .dark:   return .dark
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
    /// The full list of 3Dmol-supported structural formats per its docs is:
    /// pdb, sdf, mol2, xyz, cif, cdjson, mmtf, prmtop, gro, pqr, cube, vasp.
    /// Every one of those is wired up below (mmtf is binary so it's hidden
    /// behind the Custom drop-tile rather than getting its own demo).
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
        // Comp-chem outputs/inputs (1.7.30+) get pre-parsed to XYZ
        // in SharedFunctions; the dispatch here is a sentinel so
        // CanHandle returns true. The actual viewer-side format
        // becomes "xyz" after the pre-parse.
        case "gjf", "com":     return "xyz"
        case "orcaout", "gauout", "qchemout": return "xyz"
        // Cryo-EM density (1.7.32+) - rerouted to cube text in
        // prepare3DmolHTML via convertCCP4ToCube.
        case "ccp4", "mrc", "map": return "cube"
        default:               return nil
        }
    }
}
