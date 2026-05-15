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

/// Filter chips on the File Formats panel — matches the design's `all /
/// protein / small / sim` segmented control.
enum FormatFilter: String, CaseIterable, Identifiable {
    case all, protein, small, sim
    var id: String { rawValue }
    var label: String { rawValue }
    func matches(_ ext: String) -> Bool {
        switch self {
        case .all:     return true
        case .protein: return ["PDB", "CIF", "MMTF"].contains(ext)
        case .small:   return ["SDF", "MOL", "MOL2", "XYZ", "CDJSON"].contains(ext)
        case .sim:     return ["GRO", "CUBE", "PQR", "VASP"].contains(ext)
        }
    }
}

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

// MARK: - Reusable settings components (System Settings styling, v1.7.49+)
//
// These mirror the all-caps section labels + rounded card containers that
// macOS System Settings (and the Claude Design template) uses. Each
// component is intentionally tiny — they're just styled wrappers around
// stock SwiftUI controls so the panels read top-to-bottom as design data.

/// Small all-caps grey section header. Sits above each Card.
private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}

/// Rounded card with subtle background — the container for grouped rows
/// inside a settings panel. Uses the macOS-11-safe windowBackground color
/// instead of `.regularMaterial` so it works at the existing deployment
/// target.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }
}

/// 0.5pt hairline divider between rows inside a Card. Inset on the left
/// so it visually starts at the row's content, matching the Sonoma look.
private struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}

/// Standard form row: label on the left (optional hint underneath),
/// trailing control on the right. Mirrors the design's FormRow layout.
private struct FormRow<Trailing: View>: View {
    let label: String
    var hint: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 13))
                if let hint = hint {
                    Text(hint).font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Toggle row — switch on the right, optional trailing accessory caption.
private struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    var hint: String? = nil
    var accessory: String? = nil
    var body: some View {
        FormRow(label: label, hint: hint) {
            HStack(spacing: 10) {
                if let accessory = accessory {
                    Text(accessory).font(.system(size: 12)).foregroundColor(.secondary)
                }
                Toggle("", isOn: $isOn).labelsHidden()
            }
        }
    }
}

/// Checkbox row with a primary label + optional sub-label underneath.
/// Used in Rendering panel where each toggle has an explanatory sub-line.
private struct CheckRow: View {
    let label: String
    @Binding var isOn: Bool
    var sub: String? = nil
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 13))
                if let sub = sub {
                    Text(sub).font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
        }
        .toggleStyle(CheckboxToggleStyle())
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Segmented chip strip for the per-format atom-style picker. Matches the
/// design's StyleStrip — a row of small chips that highlight the active
/// style in the magenta accent. Used inside each formatCard.
private struct StyleStrip: View {
    @Binding var style: Settings.AtomStyle
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Settings.AtomStyle.allCases) { opt in
                Button { style = opt } label: {
                    Text(opt.rawValue == "Ball & Stick" ? "B&S" : opt.rawValue)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(style == opt ? .white : .primary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .frame(maxWidth: .infinity)
                        .background(style == opt ? Color.accentColor : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }
}

/// Schematic placeholder painted inside each format card's viewer area.
/// We don't run 3Dmol inside the settings app (12 WKWebViews would melt
/// the Settings window), so each card shows a stylised SwiftUI rendering
/// that conveys the style: ribbon waves for Cartoon, sphere triplet for
/// Sphere, lines for Stick, etc. The design uses the same "placeholder"
/// convention.
private struct FormatViewerPlaceholder: View {
    let ext: String
    let style: Settings.AtomStyle
    let tint: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            switch style {
            case .cartoon:
                // Ribbon — sinusoid path in tint color
                Path { p in
                    p.move(to: CGPoint(x: 8, y: h / 2))
                    let steps = 24
                    for i in 1...steps {
                        let x = 8 + (w - 16) * CGFloat(i) / CGFloat(steps)
                        let y = h / 2 + sin(CGFloat(i) / 2.0) * (h / 4)
                        p.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
            case .sphere:
                HStack(spacing: 8) {
                    Circle().fill(tint).frame(width: h * 0.55, height: h * 0.55)
                    Circle().fill(Color(red: 0.5, green: 0.5, blue: 0.55))
                        .frame(width: h * 0.45, height: h * 0.45)
                    Circle().fill(Color(red: 0.8, green: 0.45, blue: 0.4))
                        .frame(width: h * 0.5, height: h * 0.5)
                }
                .frame(width: w, height: h)
            case .line:
                Path { p in
                    p.move(to: CGPoint(x: 12, y: h / 2))
                    let pts = [(0.25, 0.3), (0.5, 0.6), (0.75, 0.35), (0.95, 0.55)]
                    for (fx, fy) in pts {
                        p.addLine(to: CGPoint(x: w * fx, y: h * fy))
                    }
                }
                .stroke(Color.primary.opacity(0.65), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            default: // .stick (and any added style)
                ZStack {
                    // Sticks
                    Path { p in
                        let pts: [(Double, Double)] = [
                            (0.20, 0.45), (0.40, 0.35), (0.55, 0.55),
                            (0.40, 0.35), (0.65, 0.30), (0.80, 0.50),
                        ]
                        for i in stride(from: 0, to: pts.count, by: 2) {
                            p.move(to: CGPoint(x: w * pts[i].0, y: h * pts[i].1))
                            p.addLine(to: CGPoint(x: w * pts[i+1].0, y: h * pts[i+1].1))
                        }
                    }
                    .stroke(Color.primary.opacity(0.7), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    // Atoms
                    ForEach(0..<5, id: \.self) { i in
                        Circle()
                            .fill([Color.gray, Color.blue, Color.red, Color.gray, Color.red][i])
                            .frame(width: h * 0.18, height: h * 0.18)
                            .position(x: w * [0.20, 0.40, 0.55, 0.65, 0.80][i],
                                      y: h * [0.45, 0.35, 0.55, 0.30, 0.50][i])
                    }
                }
            }
        }
    }
}

/// Background preset for the previewer. Persists as a string preference
/// because the @Published bgColorRed/Green/Blue/Opacity stay as the source
/// of truth — the preset just writes those four values when chosen.
enum BackgroundPreset: String, CaseIterable, Identifiable {
    case light, dark, gradient, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .light:    return "Light"
        case .dark:     return "Dark"
        case .gradient: return "Gradient"
        case .custom:   return "Custom"
        }
    }
}

struct ContentView: View {

    @StateObject private var userSettings = SettingsStorage()
    @ObservedObject private var updater = Updater.shared
    @State private var selection: SettingsSection = .general
    @State private var formatFilter: FormatFilter = .all
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
                appIconImage
                    .resizable()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

    /// Resolve the bundle's AppIcon — same image Finder shows for the .app.
    /// Falls back to a gradient SF Symbol if the asset catalog hasn't built
    /// the icon for some reason.
    private var appIconImage: Image {
        if let ns = NSImage(named: NSImage.applicationIconName) ?? NSImage(named: "AppIcon") {
            return Image(nsImage: ns)
        }
        return Image(systemName: "atom")
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
        VStack(alignment: .leading, spacing: 18) {
            panelHeader(.general, subtitle: "Quick Look behavior and viewer defaults")

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Quick Look")
                Card {
                    ToggleRow(label: "Enable QuickLookProtein",
                              isOn: $userSettings.masterEnabled,
                              accessory: userSettings.masterEnabled
                                ? "Active — previewing 12 formats"
                                : "Disabled")
                    RowDivider()
                    ToggleRow(label: "Run on first preview",
                              isOn: $userSettings.runOnFirstPreview,
                              hint: "Render immediately on the first spacebar-press. Off shows a tap-to-render placeholder on slow disks.")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Defaults")
                Card {
                    FormRow(label: "Color scheme") {
                        Picker("", selection: $userSettings.colorScheme) {
                            ForEach(Settings.ColorScheme.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                }
                Text("Per-format display style is set in File Formats. Color scheme applies everywhere.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Performance")
                Card {
                    Text("QuickLookProtein renders via 3Dmol.js in a WKWebView with hardware-accelerated WebGL. There is no per-app GPU/quality toggle — render cost is set by the structure size and the Default zoom under Appearance.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    @ViewBuilder
    private var formatsPanel: some View {
        let allFormats: [(ext: String, name: String, tint: Color, style: Binding<Settings.AtomStyle>, enabled: Binding<Bool>)] = [
            ("PDB",    "Protein Data Bank",       Color(red: 0.90, green: 0.27, blue: 0.27), $userSettings.atomStylePDB,    $userSettings.formatEnabledPDB),
            ("CIF",    "Crystallographic IF",     Color(red: 0.94, green: 0.54, blue: 0.12), $userSettings.atomStyleCIF,    $userSettings.formatEnabledCIF),
            ("SDF",    "Structure Data File",     Color(red: 0.90, green: 0.72, blue: 0.17), $userSettings.atomStyleSDF,    $userSettings.formatEnabledSDF),
            ("MOL",    "MDL Molfile",             Color(red: 0.36, green: 0.69, blue: 0.29), $userSettings.atomStyleMOL,    $userSettings.formatEnabledMOL),
            ("MOL2",   "Tripos Mol2",             Color(red: 0.15, green: 0.65, blue: 0.58), $userSettings.atomStyleMOL2,   $userSettings.formatEnabledMOL2),
            ("XYZ",    "XYZ Coordinates",         Color(red: 0.22, green: 0.68, blue: 0.86), $userSettings.atomStyleXYZ,    $userSettings.formatEnabledXYZ),
            ("GRO",    "GROMACS",                 Color(red: 0.23, green: 0.51, blue: 0.90), $userSettings.atomStyleGRO,    $userSettings.formatEnabledGRO),
            ("CUBE",   "Gaussian Cube",           Color(red: 0.48, green: 0.36, blue: 0.90), $userSettings.atomStyleCUBE,   $userSettings.formatEnabledCUBE),
            ("PQR",    "PDB + Charge/Radius",     Color(red: 0.76, green: 0.31, blue: 0.72), $userSettings.atomStylePQR,    $userSettings.formatEnabledPQR),
            ("VASP",   "VASP POSCAR",             Color(red: 0.43, green: 0.47, blue: 0.52), $userSettings.atomStyleVASP,   $userSettings.formatEnabledVASP),
            ("CDJSON", "ChemDraw JSON",           Color(red: 0.60, green: 0.42, blue: 0.25), $userSettings.atomStyleCDJSON, $userSettings.formatEnabledCDJSON),
            ("MMTF",   "MacroMol Transmission",   Color(red: 0.31, green: 0.42, blue: 0.76), $userSettings.atomStyleMMTF,   $userSettings.formatEnabledMMTF),
        ]
        let visible = allFormats.filter { formatFilter.matches($0.ext) }

        VStack(alignment: .leading, spacing: 14) {
            panelHeader(.formats, subtitle: "Each format gets its own renderer. Change the style to preview live.")

            HStack {
                HStack(spacing: 0) {
                    ForEach(FormatFilter.allCases) { f in
                        Button { formatFilter = f } label: {
                            Text(f.label)
                                .font(.system(size: 12, weight: formatFilter == f ? .semibold : .regular))
                                .foregroundColor(formatFilter == f ? .white : .primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(formatFilter == f ? Color.accentColor : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                Spacer()
                Text("\(visible.count) \(visible.count == 1 ? "format" : "formats")")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)

            let cols = [GridItem(.adaptive(minimum: 290), spacing: 14)]
            LazyVGrid(columns: cols, spacing: 14) {
                ForEach(visible, id: \.ext) { f in
                    formatCard(f.ext,
                               style: f.style,
                               enabled: f.enabled,
                               tint: f.tint,
                               description: f.name)
                }
            }
        }
    }

    @ViewBuilder
    private func formatCard(_ ext: String,
                            style: Binding<Settings.AtomStyle>,
                            enabled: Binding<Bool>,
                            tint: Color,
                            description: String) -> some View {
        VStack(spacing: 0) {
            // Colored accent rail along the top
            Rectangle().fill(tint).frame(height: 3)

            // Viewer placeholder — a stylised preview of the structure-in-style
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.94, green: 0.95, blue: 0.96),
                        Color(red: 0.83, green: 0.85, blue: 0.88)
                    ]),
                    startPoint: .top, endPoint: .bottom)
                FormatViewerPlaceholder(ext: ext, style: style.wrappedValue, tint: tint)
                    .padding(8)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(style.wrappedValue.rawValue)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.black.opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                .padding(8)
            }
            .frame(height: 140)

            // Header row: badge + name + ext + enable toggle
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
                    .help("Disable .\(ext.lowercased()) previews. The QL extension shows a 'paused' placeholder until you re-enable it.")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Style strip: segmented chip row
            StyleStrip(style: style)
                .disabled(!enabled.wrappedValue)
                .opacity(enabled.wrappedValue ? 1.0 : 0.45)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .opacity(enabled.wrappedValue ? 1.0 : 0.55)
    }

    @ViewBuilder
    private var appearancePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            panelHeader(.appearance, subtitle: "Color, motion, and background of the preview")

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Color")
                Card {
                    FormRow(label: "Color scheme") {
                        Picker("", selection: $userSettings.colorScheme) {
                            ForEach(Settings.ColorScheme.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    RowDivider()
                    ToggleRow(label: "Highlight ligands",
                              isOn: $userSettings.autoStyleHetero,
                              hint: "Detect heteroatoms and render them in ball-and-stick over the cartoon backbone.")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Motion")
                Card {
                    FormRow(label: "Rotation") {
                        Picker("", selection: $userSettings.rotationSpeed) {
                            ForEach(Settings.RotationSpeed.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 220)
                    }
                    RowDivider()
                    FormRow(label: "Default zoom") {
                        Picker("", selection: $userSettings.defaultZoom) {
                            ForEach(Settings.DefaultZoom.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Background")
                Card {
                    FormRow(label: "Mode") {
                        HStack(spacing: 10) {
                            backgroundSwatch("Light",
                                             gradient: Gradient(colors: [.white, Color(red: 0.91, green: 0.91, blue: 0.92)]),
                                             rgb: (1.0, 1.0, 1.0))
                            backgroundSwatch("Dark",
                                             gradient: Gradient(colors: [Color(red: 0.22, green: 0.22, blue: 0.24), Color(red: 0.11, green: 0.11, blue: 0.13)]),
                                             rgb: (0.07, 0.07, 0.08))
                            backgroundSwatch("Gradient",
                                             gradient: Gradient(colors: [Color(red: 0.75, green: 0.52, blue: 0.99), Color(red: 0.38, green: 0.65, blue: 0.98)]),
                                             rgb: (0.55, 0.58, 0.95))
                            backgroundSwatch("Custom",
                                             gradient: nil,
                                             rgb: nil)
                        }
                    }
                    RowDivider()
                    FormRow(label: "Custom color",
                            hint: "Used when Mode is Custom; otherwise the preset overrides this.") {
                        HStack(spacing: 8) {
                            ColorPicker("", selection: $userSettings.bgColor, supportsOpacity: true)
                                .labelsHidden()
                            Button("Transparent", action: resetColor)
                        }
                    }
                }
            }
        }
    }

    /// Tile for the Background-Mode picker. Setting `rgb = nil` makes the
    /// swatch render a transparent checkerboard (the "Custom" slot).
    private func backgroundSwatch(_ label: String,
                                  gradient: Gradient?,
                                  rgb: (Double, Double, Double)?) -> some View {
        let isSelected: Bool = {
            guard let rgb = rgb else { return false }
            return abs(userSettings.bgColorRed   - rgb.0) < 0.02 &&
                   abs(userSettings.bgColorGreen - rgb.1) < 0.02 &&
                   abs(userSettings.bgColorBlue  - rgb.2) < 0.02
        }()
        return VStack(spacing: 4) {
            ZStack {
                if let gradient = gradient {
                    LinearGradient(gradient: gradient, startPoint: .top, endPoint: .bottom)
                } else {
                    // Checkerboard for "Custom"/transparent
                    Color.white
                    Image(systemName: "square.grid.4x3.fill")
                        .resizable().scaledToFit()
                        .foregroundColor(Color.gray.opacity(0.25))
                }
            }
            .frame(width: 64, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                                  lineWidth: isSelected ? 2 : 0.5)
            )
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let rgb = rgb {
                userSettings.bgColorRed     = rgb.0
                userSettings.bgColorGreen   = rgb.1
                userSettings.bgColorBlue    = rgb.2
                userSettings.bgColorOpacity = 1.0
            }
        }
    }

    @ViewBuilder
    private var renderingPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            panelHeader(.rendering, subtitle: "What to draw and how to draw it")

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Geometry")
                Card {
                    CheckRow(label: "Smart protein + ligand styling",
                             isOn: $userSettings.autoStyleHetero,
                             sub: "Detect ligands and render them in ball-and-stick over a cartoon backbone")
                    RowDivider()
                    CheckRow(label: "Show molecular surface",
                             isOn: $userSettings.showSurface,
                             sub: "Solvent-excluded surface, ~50% opacity")
                    RowDivider()
                    CheckRow(label: "Hide hydrogens",
                             isOn: $userSettings.hideHydrogens,
                             sub: "Useful for large structures")
                    RowDivider()
                    CheckRow(label: "Show unit cell (PDB CRYST1 / CIF _cell)",
                             isOn: $userSettings.showUnitCell)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Overlays & Shading")
                Card {
                    CheckRow(label: "Show info overlay",
                             isOn: $userSettings.showInfoOverlay,
                             sub: "File name, atom count, etc. on the preview")
                    RowDivider()
                    CheckRow(label: "Show interactive controls",
                             isOn: $userSettings.showControlsInPreview,
                             sub: "Style buttons, recenter, share")
                    RowDivider()
                    CheckRow(label: "Outline shading",
                             isOn: $userSettings.outlineShading,
                             sub: "Cel-style outline like Mol* default")
                    RowDivider()
                    CheckRow(label: "Ambient occlusion",
                             isOn: $userSettings.ambientOcclusion,
                             sub: "Vignette that deepens crevices in cartoon/surface renders")
                    RowDivider()
                    CheckRow(label: "Auto-orient (longest axis horizontal)",
                             isOn: $userSettings.autoOrient)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Advanced")
                Card {
                    CheckRow(label: "Cube isosurface",
                             isOn: $userSettings.cubeIsosurface,
                             sub: "Render .cube grids as isosurface")
                    RowDivider()
                    CheckRow(label: "Biological assembly",
                             isOn: $userSettings.bioAssembly,
                             sub: "Apply BIOMT / oper_list transforms when present")
                    RowDivider()
                    CheckRow(label: "Cryo-EM density isosurface",
                             isOn: $userSettings.cryoEMRender,
                             sub: ".ccp4 / .mrc / .map files render volumetrically")
                    FormRow(label: "σ threshold",
                            hint: "Typical 1.5–3.0σ. Higher = denser features only.") {
                        HStack(spacing: 8) {
                            Slider(value: $userSettings.cryoEMSigma, in: 0.5...6.0, step: 0.1)
                                .frame(width: 180)
                            Text(String(format: "%.1f σ", userSettings.cryoEMSigma))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                    .disabled(!userSettings.cryoEMRender)
                    .opacity(userSettings.cryoEMRender ? 1 : 0.45)
                    RowDivider()
                    CheckRow(label: "Share button in preview",
                             isOn: $userSettings.showShareButton)
                    RowDivider()
                    CheckRow(label: "Include USDZ in Share (AR Quick Look)",
                             isOn: $userSettings.includeUSDZInShare,
                             sub: "Generate USDZ alongside PNG for AirDrop → AR preview")
                    RowDivider()
                    CheckRow(label: "Animated thumbnails (experimental)",
                             isOn: $userSettings.animatedThumbnails,
                             sub: "Encode Finder thumbnails as 12-frame spinning APNGs")
                    RowDivider()
                    FormRow(label: "Thumbnail style") {
                        Picker("", selection: $userSettings.thumbnailStyle) {
                            ForEach(Settings.ThumbnailStyle.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var toolbarPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            panelHeader(.toolbar, subtitle: "Buttons shown on the preview overlay")

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Master")
                Card {
                    ToggleRow(label: "Show interactive controls",
                              isOn: $userSettings.showControlsInPreview,
                              hint: "Off hides the whole toolbar regardless of the per-button toggles below.")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Buttons")
                Card {
                    let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                    LazyVGrid(columns: cols, alignment: .leading, spacing: 6) {
                        toolbarPill("Stick",    color: Color(red: 0.36, green: 0.69, blue: 0.29), isOn: $userSettings.ctlShowStick)
                        toolbarPill("Line",     color: Color(red: 0.22, green: 0.68, blue: 0.86), isOn: $userSettings.ctlShowLine)
                        toolbarPill("Sphere",   color: Color(red: 0.90, green: 0.27, blue: 0.27), isOn: $userSettings.ctlShowSphere)
                        toolbarPill("Cartoon",  color: Color(red: 0.64, green: 0.35, blue: 0.85), isOn: $userSettings.ctlShowCartoon)
                        toolbarPill("Surface",  color: Color(red: 0.15, green: 0.65, blue: 0.58), isOn: $userSettings.ctlShowSurface)
                        toolbarPill("Color SS", color: Color(red: 0.94, green: 0.54, blue: 0.12), isOn: $userSettings.ctlShowColorSS)
                        toolbarPill("Label αC", color: Color(red: 0.36, green: 0.43, blue: 0.54), isOn: $userSettings.ctlShowLabelCA)
                        toolbarPill("Recenter", color: Color(red: 0.48, green: 0.36, blue: 0.90), isOn: $userSettings.ctlShowRecenter)
                        toolbarPill("Spin",     color: Color(red: 0.23, green: 0.51, blue: 0.90), isOn: $userSettings.ctlShowRotation)
                    }
                    .padding(8)
                }
                .disabled(!userSettings.showControlsInPreview)
                .opacity(userSettings.showControlsInPreview ? 1 : 0.45)
                Text("Live preview reflects the current selection.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Preview")
                Card {
                    toolbarPreviewPane
                        .padding(14)
                }
            }
        }
    }

    private func toolbarPill(_ name: String, color: Color, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundColor(isOn.wrappedValue ? Color.accentColor : .secondary)
                Circle().fill(color).frame(width: 6, height: 6)
                Text(name).font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isOn.wrappedValue ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isOn.wrappedValue ? Color.accentColor.opacity(0.35) : Color.clear,
                                  lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var toolbarPreviewPane: some View {
        let activeLabels: [String] = [
            (userSettings.ctlShowStick,    "Stick"),
            (userSettings.ctlShowLine,     "Line"),
            (userSettings.ctlShowSphere,   "Sphere"),
            (userSettings.ctlShowCartoon,  "Cartoon"),
            (userSettings.ctlShowSurface,  "Surface"),
            (userSettings.ctlShowColorSS,  "Color SS"),
            (userSettings.ctlShowLabelCA,  "Label αC"),
            (userSettings.ctlShowRecenter, "Recenter"),
            (userSettings.ctlShowRotation, "Spin"),
        ].filter { $0.0 }.map { $0.1 }

        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(RadialGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.91, green: 0.92, blue: 0.93),
                        Color(red: 0.78, green: 0.79, blue: 0.82)
                    ]),
                    center: .center, startRadius: 30, endRadius: 220))
                .frame(height: 180)
            VStack {
                HStack {
                    Text("caffeine.mol2 · 24 atoms · C₈H₁₀N₄O₂")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color.primary.opacity(0.65))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.75)))
                    Spacer()
                }
                Spacer()
                if !activeLabels.isEmpty && userSettings.showControlsInPreview {
                    HStack(spacing: 2) {
                        ForEach(activeLabels, id: \.self) { l in
                            Text(l).font(.system(size: 10.5, weight: .medium))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                        }
                    }
                    .padding(3)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.78))
                        .shadow(color: Color.black.opacity(0.1), radius: 6, y: 2))
                }
            }
            .padding(10)
            .frame(height: 180)
        }
    }

    @ViewBuilder
    private var infoOverlayPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            panelHeader(.info, subtitle: "Metadata to display on top of the preview")

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Master")
                Card {
                    ToggleRow(label: "Show info overlay",
                              isOn: $userSettings.showInfoOverlay)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Fields")
                Card {
                    CheckRow(label: "File name",          isOn: $userSettings.infoShowFileName)
                    RowDivider()
                    CheckRow(label: "File format",        isOn: $userSettings.infoShowFormat)
                    RowDivider()
                    CheckRow(label: "Atom count",         isOn: $userSettings.infoShowAtomCount)
                    RowDivider()
                    CheckRow(label: "Chain count",        isOn: $userSettings.infoShowChainCount)
                    RowDivider()
                    CheckRow(label: "Residue count",      isOn: $userSettings.infoShowResidueCount)
                    RowDivider()
                    CheckRow(label: "Element breakdown",  isOn: $userSettings.infoShowElementBreakdown)
                    RowDivider()
                    CheckRow(label: "Molecular weight",   isOn: $userSettings.infoShowMolWeight)
                    RowDivider()
                    CheckRow(label: "Bond count",         isOn: $userSettings.infoShowBondCount)
                    RowDivider()
                    CheckRow(label: "PDB title (HEADER)", isOn: $userSettings.infoShowPDBTitle)
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
