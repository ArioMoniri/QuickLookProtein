//
//  ContentView.swift
//  QuickLookProtein
//
//  Created by Jethro Hemmann on 15.08.21.
//

import SwiftUI
import WebKit
import AppKit
import UniformTypeIdentifiers

/// Extensions we know 3Dmol can render — used by the drag-and-drop tile.
private let supportedExtensions: Set<String> = [
    "pdb", "ent", "pdbqt", "pqr", "cif", "mmcif", "sdf", "mol", "mol2",
    "xyz", "gro", "cube", "cub", "vasp", "poscar", "cdjson"
]

/// Drop-path size cap: same 25 MB ceiling the Quick Look extension uses. Preview the
/// SwiftUI app is generous on memory but a 1 GB PDB still blocks the main thread for
/// long enough to feel like a hang.
private let maxDropBytes: Int = 25 * 1024 * 1024

/// Sidebar sections — matches the macOS System Settings layout introduced
/// in v1.7.47. Order is the same as the design's chat-iterated sidebar:
/// General → Formats → Appearance → Rendering → Toolbar → Info → Multi
/// → Updates → About.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general    = "General"
    case formats    = "File Formats"
    case appearance = "Appearance"
    case rendering  = "Rendering"
    case toolbar    = "Toolbar"
    case info       = "Info Overlay"
    case multi      = "Multi-file"
    case updates    = "Software Update"
    case about      = "About"

    var id: String { rawValue }

    /// SF Symbol used in the sidebar — picked to be reasonably faithful to
    /// the design's filled-glyph icons while staying within the system set.
    var symbol: String {
        switch self {
        case .general:    return "gearshape.fill"
        case .formats:    return "doc.on.doc.fill"
        case .appearance: return "paintbrush.fill"
        case .rendering:  return "cube.transparent.fill"
        case .toolbar:    return "square.grid.2x2.fill"
        case .info:       return "info.bubble.fill"
        case .multi:      return "square.grid.3x2.fill"
        case .updates:    return "arrow.triangle.2.circlepath"
        case .about:      return "atom"
        }
    }

    /// Tint per section — used on the icon tile and the panel header.
    var tint: Color {
        switch self {
        case .general:    return Color(red: 0.36, green: 0.43, blue: 0.54)
        case .formats:    return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .appearance: return Color(red: 0.64, green: 0.35, blue: 0.85)
        case .rendering:  return Color(red: 0.16, green: 0.55, blue: 0.33)
        case .toolbar:    return Color(red: 0.23, green: 0.51, blue: 0.90)
        case .info:       return Color(red: 0.04, green: 0.52, blue: 1.00)
        case .multi:      return Color(red: 0.48, green: 0.36, blue: 0.90)
        case .updates:    return Color(red: 0.04, green: 0.52, blue: 1.00)
        case .about:      return Color(red: 0.43, green: 0.47, blue: 0.52)
        }
    }
}

struct ContentView: View {

    @StateObject private var userSettings = SettingsStorage()
    @ObservedObject private var updater = Updater.shared
    @State private var selection: SettingsSection = .general
    /// File the user has dragged into the "Custom" tile.
    @State private var droppedFile: URL? = nil
    @State private var droppedFileError: String? = nil
    @State private var isDropTargeted: Bool = false
    /// Whether the "Quick Look not updating?" card is expanded. Drives a
    /// custom DisclosureGroup so the *entire* header row (icon + title +
    /// subtitle + chevron) is the tap target, not just the chevron.
    @State private var troubleshootingExpanded: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 218)
            Divider()
            ScrollView {
                panelContent
                    .padding(.horizontal, 28)
                    .padding(.vertical, 18)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(minWidth: 920, minHeight: 640)
        // App-wide magenta accent — matches the project's icon gradient and
        // the Claude Design template's magenta switches. SwiftUI cascades
        // this through every selection background, switch tint, and
        // Picker chevron beneath.
        .accentColor(Color(red: 0.76, green: 0.10, blue: 0.36))
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            List {
                ForEach(SettingsSection.allCases) { section in
                    HStack(spacing: 8) {
                        sectionIcon(section)
                        Text(section.rawValue).font(.system(size: 13))
                            .foregroundColor(selection == section ? .white : .primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selection == section ? Color.accentColor : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selection = section }
                    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 1, trailing: 6))
                }
            }
            .listStyle(SidebarListStyle())

            Divider()
            HStack(spacing: 8) {
                Image(systemName: "atom")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 22, height: 22)
                    .background(LinearGradient(
                        gradient: Gradient(colors: [
                            Color(red: 0.76, green: 0.10, blue: 0.36),
                            Color(red: 0.48, green: 0.12, blue: 0.64)
                        ]),
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("QuickLookProtein").font(.system(size: 11.5, weight: .semibold))
                    Text(appVersionString).font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func sectionIcon(_ section: SettingsSection) -> some View {
        Image(systemName: section.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 20, height: 20)
            .background(section.tint)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var appVersionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return "v\(v)"
    }

    // MARK: - Routing

    @ViewBuilder
    private var panelContent: some View {
        switch selection {
        case .general:    generalPanel
        case .formats:    formatsPanel
        case .appearance: appearancePanel
        case .rendering:  renderingPanel
        case .toolbar:    toolbarPanel
        case .info:       infoOverlayPanel
        case .multi:      multiFilePanel
        case .updates:    updatesPanel
        case .about:      aboutPanel
        }
    }

    @ViewBuilder
    private func panelHeader(_ section: SettingsSection, subtitle: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: section.symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(section.tint)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(section.rawValue).font(.system(size: 22, weight: .bold))
                Text(subtitle).font(.system(size: 12.5)).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 10)
    }

    // MARK: - Panels

    @ViewBuilder
    private var generalPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            panelHeader(.general, subtitle: "Quick Look behavior and viewer defaults")

            GroupBox(label: Text("Quick Look").font(.headline)) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Enable QuickLookProtein", isOn: $userSettings.masterEnabled)
                        .help("Master switch. When OFF, the QL extension shows a 'paused' placeholder instead of rendering molecules — useful for troubleshooting without uninstalling the extension.")
                    Toggle("Run on first preview", isOn: $userSettings.runOnFirstPreview)
                        .help("When ON (default), the WebView renders immediately on the first spacebar-press for a file. When OFF, large files show a tap-to-render placeholder first to avoid stalling Finder on slow disks.")
                }
                .padding(.vertical, 2)
            }

            GroupBox(label: Text("Defaults").font(.headline)) {
                Form {
                    Picker("Color scheme:", selection: $userSettings.colorScheme) {
                        ForEach(Settings.ColorScheme.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox(label: Text("Performance").font(.headline)) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("QuickLookProtein renders via 3Dmol.js in a WKWebView with hardware-accelerated WebGL — there is no per-app GPU toggle. Performance is governed by the structure size and your global Default zoom.")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var formatsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            panelHeader(.formats, subtitle: "Each format gets its own renderer. Change the style to preview live.")

            let cols = [GridItem(.adaptive(minimum: 280), spacing: 14)]
            LazyVGrid(columns: cols, spacing: 14) {
                formatCard("PDB",    style: $userSettings.atomStylePDB,    enabled: $userSettings.formatEnabledPDB,    tint: Color(red: 0.90, green: 0.27, blue: 0.27), description: "Protein Data Bank")
                formatCard("CIF",    style: $userSettings.atomStyleCIF,    enabled: $userSettings.formatEnabledCIF,    tint: Color(red: 0.94, green: 0.54, blue: 0.12), description: "Crystallographic IF")
                formatCard("SDF",    style: $userSettings.atomStyleSDF,    enabled: $userSettings.formatEnabledSDF,    tint: Color(red: 0.90, green: 0.72, blue: 0.17), description: "Structure Data File")
                formatCard("MOL",    style: $userSettings.atomStyleMOL,    enabled: $userSettings.formatEnabledMOL,    tint: Color(red: 0.36, green: 0.69, blue: 0.29), description: "MDL Molfile")
                formatCard("MOL2",   style: $userSettings.atomStyleMOL2,   enabled: $userSettings.formatEnabledMOL2,   tint: Color(red: 0.15, green: 0.65, blue: 0.58), description: "Tripos Mol2")
                formatCard("XYZ",    style: $userSettings.atomStyleXYZ,    enabled: $userSettings.formatEnabledXYZ,    tint: Color(red: 0.22, green: 0.68, blue: 0.86), description: "XYZ Coordinates")
                formatCard("GRO",    style: $userSettings.atomStyleGRO,    enabled: $userSettings.formatEnabledGRO,    tint: Color(red: 0.23, green: 0.51, blue: 0.90), description: "GROMACS")
                formatCard("CUBE",   style: $userSettings.atomStyleCUBE,   enabled: $userSettings.formatEnabledCUBE,   tint: Color(red: 0.48, green: 0.36, blue: 0.90), description: "Gaussian Cube")
                formatCard("PQR",    style: $userSettings.atomStylePQR,    enabled: $userSettings.formatEnabledPQR,    tint: Color(red: 0.76, green: 0.31, blue: 0.72), description: "PDB + Charge/Radius")
                formatCard("VASP",   style: $userSettings.atomStyleVASP,   enabled: $userSettings.formatEnabledVASP,   tint: Color(red: 0.43, green: 0.47, blue: 0.52), description: "VASP POSCAR")
                formatCard("CDJSON", style: $userSettings.atomStyleCDJSON, enabled: $userSettings.formatEnabledCDJSON, tint: Color(red: 0.60, green: 0.42, blue: 0.25), description: "ChemDraw JSON")
                formatCard("MMTF",   style: $userSettings.atomStyleMMTF,   enabled: $userSettings.formatEnabledMMTF,   tint: Color(red: 0.31, green: 0.42, blue: 0.76), description: "MacroMol Transmission")
            }
        }
    }

    @ViewBuilder
    private func formatCard(_ ext: String,
                            style: Binding<Settings.AtomStyle>,
                            enabled: Binding<Bool>,
                            tint: Color,
                            description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(tint).frame(height: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
                .padding(.top, 1)

            HStack(spacing: 10) {
                Text(ext)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(tint)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(description).font(.system(size: 13, weight: .semibold))
                    Text(".\(ext.lowercased())")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: enabled)
                    .labelsHidden()
                    .help("Disable .\(ext.lowercased()) previews. The QL extension shows a 'paused' placeholder for this format until you re-enable it.")
            }
            .padding(.horizontal, 14)

            Picker("", selection: style) {
                ForEach(Settings.AtomStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .disabled(!enabled.wrappedValue)
            .opacity(enabled.wrappedValue ? 1.0 : 0.45)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .padding(.top, 2)
        }
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var appearancePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            panelHeader(.appearance, subtitle: "Color, motion, and background of the preview")

            GroupBox(label: Text("Color").font(.headline)) {
                Form {
                    Picker("Color scheme:", selection: $userSettings.colorScheme) {
                        ForEach(Settings.ColorScheme.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Highlight ligands (smart styling)", isOn: $userSettings.autoStyleHetero)
                }
            }

            GroupBox(label: Text("Motion").font(.headline)) {
                Form {
                    Picker("Rotation:", selection: $userSettings.rotationSpeed) {
                        ForEach(Settings.RotationSpeed.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Default zoom:", selection: $userSettings.defaultZoom) {
                        ForEach(Settings.DefaultZoom.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            }

            GroupBox(label: Text("Background").font(.headline)) {
                HStack {
                    ColorPicker("Background:", selection: $userSettings.bgColor, supportsOpacity: true)
                        .help("#" + convertColorToRGB(color: userSettings.bgColor).rgbHex
                              + ", alpha: " + convertColorToRGB(color: userSettings.bgColor).alpha)
                    Button("Transparent", action: resetColor)
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var renderingPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            panelHeader(.rendering, subtitle: "What to draw and how to draw it")

            GroupBox(label: Text("Geometry").font(.headline)) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Smart protein + ligand styling", isOn: $userSettings.autoStyleHetero)
                    Toggle("Show molecular surface", isOn: $userSettings.showSurface)
                    Toggle("Hide hydrogens", isOn: $userSettings.hideHydrogens)
                    Toggle("Show unit cell (PDB CRYST1 / CIF _cell)", isOn: $userSettings.showUnitCell)
                }
            }

            GroupBox(label: Text("Overlays & Shading").font(.headline)) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show info overlay", isOn: $userSettings.showInfoOverlay)
                    Toggle("Show interactive controls", isOn: $userSettings.showControlsInPreview)
                    Toggle("Outline shading", isOn: $userSettings.outlineShading)
                    Toggle("Ambient occlusion (vignette)", isOn: $userSettings.ambientOcclusion)
                    Toggle("Auto-orient (longest axis horizontal)", isOn: $userSettings.autoOrient)
                }
            }

            GroupBox(label: Text("Advanced").font(.headline)) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Cube isosurface (.cube)", isOn: $userSettings.cubeIsosurface)
                    Toggle("Biological assembly (PDB REMARK 350 / CIF oper_list)", isOn: $userSettings.bioAssembly)
                    Toggle("Cryo-EM density isosurface (.ccp4/.mrc/.map)", isOn: $userSettings.cryoEMRender)
                    HStack(spacing: 8) {
                        Text("Cryo-EM σ threshold:")
                            .font(.system(size: 12))
                        Slider(value: $userSettings.cryoEMSigma, in: 0.5...6.0, step: 0.1)
                            .frame(maxWidth: 220)
                        Text(String(format: "%.1f σ", userSettings.cryoEMSigma))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .disabled(!userSettings.cryoEMRender)
                    .opacity(userSettings.cryoEMRender ? 1 : 0.45)
                    .help("Threshold for the cryo-EM isosurface contour — higher σ shows only the densest features (sharp helices, ligand binding sites); lower σ reveals the full envelope. Typical range 1.5–3.0σ.")
                    Toggle("Share button in preview", isOn: $userSettings.showShareButton)
                    Toggle("Include USDZ in Share (AR Quick Look)", isOn: $userSettings.includeUSDZInShare)
                    Toggle("Animated thumbnails (experimental APNG)", isOn: $userSettings.animatedThumbnails)
                    Picker("Thumbnail style:", selection: $userSettings.thumbnailStyle) {
                        ForEach(Settings.ThumbnailStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var toolbarPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            panelHeader(.toolbar, subtitle: "Buttons shown on the in-preview toolbar")

            GroupBox(label: Text("Master").font(.headline)) {
                Toggle("Show interactive controls", isOn: $userSettings.showControlsInPreview)
                    .padding(.vertical, 2)
            }

            GroupBox(label: Text("Buttons").font(.headline)) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                          alignment: .leading, spacing: 6) {
                    Toggle("Stick",     isOn: $userSettings.ctlShowStick)
                    Toggle("Line",      isOn: $userSettings.ctlShowLine)
                    Toggle("Sphere",    isOn: $userSettings.ctlShowSphere)
                    Toggle("Cartoon",   isOn: $userSettings.ctlShowCartoon)
                    Toggle("Surface",   isOn: $userSettings.ctlShowSurface)
                    Toggle("Color SS",  isOn: $userSettings.ctlShowColorSS)
                    Toggle("Label αC",  isOn: $userSettings.ctlShowLabelCA)
                    Toggle("Recenter",  isOn: $userSettings.ctlShowRecenter)
                    Toggle("Spin",      isOn: $userSettings.ctlShowRotation)
                }
                .disabled(!userSettings.showControlsInPreview)
                .opacity(userSettings.showControlsInPreview ? 1 : 0.45)
            }
        }
    }

    @ViewBuilder
    private var infoOverlayPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            panelHeader(.info, subtitle: "Metadata to display on top of the preview")

            GroupBox(label: Text("Master").font(.headline)) {
                Toggle("Show info overlay", isOn: $userSettings.showInfoOverlay)
                    .padding(.vertical, 2)
            }

            GroupBox(label: Text("Fields").font(.headline)) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("File name",          isOn: $userSettings.infoShowFileName)
                    Toggle("File format",        isOn: $userSettings.infoShowFormat)
                    Toggle("Atom count",         isOn: $userSettings.infoShowAtomCount)
                    Toggle("Chain count",        isOn: $userSettings.infoShowChainCount)
                    Toggle("Residue count",      isOn: $userSettings.infoShowResidueCount)
                    Toggle("Element breakdown",  isOn: $userSettings.infoShowElementBreakdown)
                    Toggle("Molecular weight",   isOn: $userSettings.infoShowMolWeight)
                    Toggle("Bond count",         isOn: $userSettings.infoShowBondCount)
                    Toggle("PDB title (HEADER)", isOn: $userSettings.infoShowPDBTitle)
                }
                .disabled(!userSettings.showInfoOverlay)
                .opacity(userSettings.showInfoOverlay ? 1 : 0.45)
            }
        }
    }

    @ViewBuilder
    private var multiFilePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            panelHeader(.multi, subtitle: "Behavior when previewing more than one structure")

            GroupBox(label: Text("Layout").font(.headline)) {
                Form {
                    Picker("When previewing many files:",
                           selection: $userSettings.multiFilePreviewMode) {
                        ForEach(Settings.MultiFilePreviewMode.allCases) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .help("""
                    Quick Look's sandbox hands the preview extension one file at a time, so spacebar-multi-select rarely triggers a merge.

                    For a guaranteed merge:
                    1. Select two or more compatible files in Finder.
                    2. Right-click → Quick Actions → Render Molecule to PNG.
                    3. Open <first>-merged.pdb that appears next to them.
                    """)
                }
            }
        }
    }

    @ViewBuilder
    private var updatesPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            panelHeader(.updates, subtitle: "Stay current with signed, notarised releases")
            updatesCard
            troubleshootingCard
        }
    }

    @ViewBuilder
    private var aboutPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.76, green: 0.10, blue: 0.36),
                                     Color(red: 0.48, green: 0.12, blue: 0.64)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 96, height: 96)
                        .shadow(color: Color(red: 0.48, green: 0.12, blue: 0.64).opacity(0.3),
                                radius: 12, x: 0, y: 8)
                    Image(systemName: "atom")
                        .font(.system(size: 50, weight: .regular))
                        .foregroundColor(.white)
                }
                Text("QuickLookProtein").font(.system(size: 22, weight: .bold))
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)

            creditsCard
            footerCredit
        }
    }

    /// Shared option list for every per-format atom-style Picker.
    @ViewBuilder
    private var atomStyleOptions: some View {
        ForEach(Settings.AtomStyle.allCases) { Text($0.rawValue).tag($0) }
    }

    // MARK: - About card sections

    /// Top card — version, last-check status, and the two big update buttons.
    /// "Check for Updates" is the primary action (filled blue pill); the
    /// fallback "Download Latest Release" is a quieter secondary action that
    /// still works when Sparkle isn't configured for this build.
    @ViewBuilder
    private var updatesCard: some View {
        let installedVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
        let buildNumber      = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? ""

        AboutCard {
            HStack(alignment: .top, spacing: 14) {
                CardIcon(systemName: "arrow.triangle.2.circlepath.circle.fill",
                         tint: .blue)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Software Updates")
                        .font(.headline)
                    Text("Get the latest signed and notarised release. Updates are verified with Sparkle's EdDSA signature before installing.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Version + status row
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        Text("Installed version: \(installedVersion)")
                            .font(.callout)
                            .fontWeight(.medium)
                        if !buildNumber.isEmpty && buildNumber != installedVersion {
                            Text("(build \(buildNumber))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 2)

                    if !updater.lastCheckStatus.isEmpty {
                        Text(updater.lastCheckStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Action row — primary CTA on the left, fallback on the right.
                    HStack(spacing: 10) {
                        Button(action: { updater.checkForUpdates() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Check for Updates")
                                    .fontWeight(.semibold)
                            }
                        }
                        .buttonStyle(PrimaryPillButtonStyle())
                        .disabled(!updater.canCheck)
                        .help("Ask Sparkle to check the appcast for a newer signed release. If one is available you'll get a standard 'Install Update' dialog.")

                        Button(action: {
                            if let url = URL(string: "https://github.com/ArioMoniri/QuickLookProtein/releases/latest") {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle")
                                Text("Download from GitHub")
                            }
                        }
                        .buttonStyle(SecondaryPillButtonStyle())
                        .help("Open the GitHub Releases page and download the latest QuickLookProtein.zip manually.")
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    /// Middle card — original author + extender credits, repo link, and a tip
    /// row. Lighter visual weight than the updates card.
    @ViewBuilder
    private var creditsCard: some View {
        AboutCard {
            HStack(alignment: .top, spacing: 14) {
                CardIcon(systemName: "person.2.crop.square.stack.fill",
                         tint: .purple)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Credits & Source")
                        .font(.headline)

                    Text("Originally built by Jethro Hemmann (2021–2022).")
                        .font(.callout)
                    Text("Extended by Ariorad Moniri (2026) — multi-format support, smart protein+ligand styling, molecular surfaces, Finder thumbnails, Spotlight indexing, drag-and-drop preview, and Sparkle auto-update.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .foregroundColor(.secondary)
                        Link("github.com/ArioMoniri/QuickLookProtein",
                             destination: URL(string: "https://github.com/ArioMoniri/QuickLookProtein")!)
                            .font(.callout)
                    }
                    .padding(.top, 2)

                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundColor(.yellow)
                        Text("Tip: click any atom in a preview to see its residue and chain.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    /// Bottom card — collapsible Quick Look troubleshooting. Most users
    /// won't need it; collapse by default so it doesn't dominate the
    /// panel. Custom header (plain Button + animated chevron) instead of
    /// `DisclosureGroup` so the *entire* row — icon, title, subtitle,
    /// chevron — is the hit area. SwiftUI's `DisclosureGroup` only makes
    /// the chevron+label tappable; an empty area beside them swallows
    /// the click silently.
    @ViewBuilder
    private var troubleshootingCard: some View {
        AboutCard {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        troubleshootingExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 10) {
                        CardIcon(systemName: "wrench.and.screwdriver.fill",
                                 tint: .orange,
                                 size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Quick Look not updating?")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text("Reset macOS's Quick Look cache after upgrading.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(troubleshootingExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())   // make empty space tappable
                }
                .buttonStyle(.plain)             // no default button chrome
                .help(troubleshootingExpanded ? "Hide troubleshooting steps"
                                              : "Show troubleshooting steps")

                if troubleshootingExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("After installing a new version, macOS may still use a previously-installed extension. Two clicks to fix:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Button("Open Extensions settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)
                            Button("Reveal /Applications") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                            }
                            .controlSize(.small)
                        }

                        Text("Then flush macOS's Quick Look caches from Terminal:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Text("qlmanage -r && qlmanage -r cache")
                                .font(.system(.caption, design: .monospaced))
                                .padding(.vertical, 4).padding(.horizontal, 6)
                                .background(Color.secondary.opacity(0.12))
                                .cornerRadius(4)
                            Button("Copy") {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString("qlmanage -r && qlmanage -r cache", forType: .string)
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.top, 10)
                    .transition(.opacity)
                }
            }
        }
    }

    /// Tiny footer below the cards — 3Dmol.js attribution.
    @ViewBuilder
    private var footerCredit: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Rendered by 3Dmol.js (Rego & Koes, 2015).")
                .font(.caption2)
                .foregroundColor(.secondary)
            Link("3dmol.csb.pitt.edu",
                 destination: URL(string: "https://3dmol.csb.pitt.edu")!)
                .font(.caption2)
        }
        .padding(.leading, 4)
        .padding(.top, 2)
    }

    /// Ninth tile — accepts a drag-and-drop *or* a click to open an
    /// NSOpenPanel for picking a file, and renders the chosen file live with
    /// the current settings. Same WebView wiring as the other tiles.
    @ViewBuilder
    private func customDropTile(htmlPath: String, baseUrl: URL) -> some View {
        VStack(spacing: 4) {
            ZStack {
                if let droppedFile = droppedFile {
                    WebView(html: previewHTML(htmlPath: htmlPath,
                                              filePath: droppedFile.path,
                                              ext: droppedFile.pathExtension),
                            baseUrl: baseUrl)
                } else {
                    Button {
                        showOpenPanel()
                    } label: {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                            .foregroundColor(isDropTargeted ? .accentColor : .secondary)
                            .overlay(
                                VStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.down")
                                        .font(.system(size: 26))
                                    Text("Drop or click to choose").font(.callout)
                                    Text("PDB · CIF · SDF · MOL · MOL2 · XYZ\nGRO · CUBE · PQR · PDBQT · VASP · CDJSON")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .padding(8)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Click to choose a structure file, or drag one here")
                }
            }
            .frame(maxWidth: .infinity, idealHeight: 200, maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }

            // Caption row — clear button for the dropped file, error message if any.
            HStack(spacing: 4) {
                Text(droppedFile?.lastPathComponent ?? "Custom")
                    .font(.callout).lineLimit(1).truncationMode(.middle)
                if droppedFile != nil {
                    Button(action: { droppedFile = nil; droppedFileError = nil }) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("Clear dropped file")
                }
            }
            Group {
                if let err = droppedFileError {
                    Text(err).foregroundColor(.red)
                } else if droppedFile == nil {
                    Text("Drag or click")
                } else {
                    Text("Custom preview")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .padding(.bottom, 4)
        }
    }

    /// Open an NSOpenPanel restricted to the file types we know how to render.
    /// The user has the same path as drag-and-drop: same validation, same
    /// 25 MB size cap, same error reporting.
    private func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a structure file to preview"
        panel.prompt = "Preview"
        panel.allowedContentTypes = supportedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        panel.allowedFileTypes = Array(supportedExtensions)   // belt-and-braces for older macOS
        if panel.runModal() == .OK, let url = panel.url {
            acceptCandidateURL(url)
        }
    }

    /// Shared validation used by both the drag-and-drop and click-to-pick code
    /// paths. Lives here so both surfaces enforce the same extension allowlist,
    /// the same 25 MB cap, and produce the same error messages.
    private func acceptCandidateURL(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if !supportedExtensions.contains(ext) {
            self.droppedFileError = "Unsupported file type: .\(ext)"
            self.droppedFile = nil
            return
        }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > maxDropBytes {
            let mb = String(format: "%.0f", Double(size) / 1_048_576)
            self.droppedFileError = "File too large for preview (\(mb) MB)"
            self.droppedFile = nil
            return
        }
        self.droppedFileError = nil
        self.droppedFile = url
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            DispatchQueue.main.async {
                guard let url = url else {
                    self.droppedFileError = "Could not read dropped item"
                    return
                }
                self.acceptCandidateURL(url)
            }
        }
        return true
    }

    private func previewHTML(htmlPath: String, filePath: String, ext: String) -> String {
        let options = ViewerOptions.from(
            userSettings,
            fileExtension: ext,
            fileName: (filePath as NSString).lastPathComponent
        )
        let format = Settings.dataFormat(forExtension: ext) ?? "pdb"
        return prepare3DmolHTML(htmlPath: htmlPath,
                                pdbPath: filePath,
                                dataFormat: format,
                                options: options)
    }

    @ViewBuilder
    private func previewTile<C: View>(html: String, base: URL, title: String,
                                      @ViewBuilder caption: () -> C) -> some View {
        // Fixed-height tile so the 3-column grid lays out as a uniform 3x3.
        // The WebView fills the body of the tile; the title + caption sit
        // beneath with consistent typography.
        VStack(spacing: 4) {
            WebView(html: html, baseUrl: base)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(title).font(.callout)
            caption().font(.caption).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .frame(height: 240)
        .padding(4)
    }

    private func resetColor() {
        userSettings.bgColor = Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

// MARK: - Reusable card chrome
//
// Single-source styling for the three About-panel cards so they share
// padding, corner radius, and background treatment. Kept simple
// (Color.secondary.opacity → cornerRadius → overlay) because
// `.regularMaterial` / `.background(Color.gray.opacity(0.06))` would require macOS 12
// and the project's deployment target is 11.

struct AboutCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.65))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
    }
}

/// Colored, rounded-square icon plate used at the leading edge of each card.
/// Mirrors the look of macOS Settings rows (e.g. iCloud, AirDrop) where each
/// section has a tinted glyph plate. `tint.opacity(0.18)` gives a soft fill,
/// `tint` colors the SF Symbol on top.
struct CardIcon: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.18))
            Image(systemName: systemName)
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundColor(tint)
        }
        .frame(width: size, height: size)
    }
}

/// Big blue filled pill — the primary "Check for Updates" CTA. Custom
/// ButtonStyle (rather than `.borderedProminent`) because that style is
/// macOS 12+, and we still target 11.
struct PrimaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor)
                    .opacity(configuration.isPressed ? 0.75 : 1.0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Quieter outlined pill — used for the secondary "Download from GitHub"
/// fallback and other neutral actions in the About panel.
struct SecondaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .foregroundColor(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(configuration.isPressed ? 0.18 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// https://stackoverflow.com/questions/60945972/why-does-my-wkwebview-not-show-up-in-a-swiftui-view
//
// Note: a value-type NSViewRepresentable is re-instantiated on every SwiftUI body
// re-render. Storing `let view = WKWebView()` as a struct property allocates a fresh
// WKWebView each time the struct is copied — a real memory leak when the parent view
// updates often (e.g. on `isDropTargeted` hover). Keep no view ownership on the struct;
// let SwiftUI cache the WKWebView via `makeNSView`, and reload only when the rendered
// HTML actually changed (tracked via the coordinator).
/// WKWebView subclass that forwards vertical scroll-wheel events to the enclosing
/// SwiftUI ScrollView instead of consuming them itself. Without this, hovering the
/// cursor over any preview tile while scrolling the main app makes the page scroll
/// stall — the WebView captures the event, 3Dmol's mouse handler interprets it as
/// a zoom gesture, and the outer ScrollView never sees it. We give up scroll-to-zoom
/// inside the in-app tiles to make the overall scroll behaviour predictable; users
/// can still zoom interactively in Quick Look previews.
final class PassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        self.nextResponder?.scrollWheel(with: event)
    }
}

struct WebView: NSViewRepresentable {

    var html: String
    var baseUrl: URL

    final class Coordinator {
        var lastLoadedHTML: String = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = PassthroughWebView()
        view.setValue(false, forKeyPath: "drawsBackground") // allow transparent background
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        // Skip the reload if SwiftUI re-applied the same HTML — avoids tearing the
        // WebGL canvas down on unrelated state changes (drop-targeted hover, etc.).
        guard context.coordinator.lastLoadedHTML != html else { return }
        context.coordinator.lastLoadedHTML = html
        view.loadHTMLString(html, baseURL: baseUrl)
    }
}
