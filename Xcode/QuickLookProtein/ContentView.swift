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

/// NumberFormatter for the preview-size text fields. Integer only,
/// no thousands separator (so "1024" parses cleanly), bounded to
/// reasonable values so a typo can't size a preview to one pixel or
/// a million.
private let previewSizeFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .none
    f.allowsFloats = false
    f.minimum = 240
    f.maximum = 4000
    f.usesGroupingSeparator = false
    return f
}()

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
    case multi      = "Multi-file"
    case appearance = "Appearance"
    case rendering  = "Rendering"
    case toolbar    = "Toolbar"
    case info       = "Info Overlay"
    case updates    = "Software Update"
    case about      = "About"

    var id: String { rawValue }

    /// SF Symbol used in the sidebar — plain monochrome glyphs, matching
    /// the DockDoor-style design reference. No colored tile backgrounds.
    var symbol: String {
        switch self {
        case .general:    return "gearshape"
        case .formats:    return "doc.on.doc"
        case .multi:      return "rectangle.split.3x1"
        case .appearance: return "paintpalette"
        case .rendering:  return "cube.transparent"
        case .toolbar:    return "slider.horizontal.below.rectangle"
        case .info:       return "info.bubble"
        case .updates:    return "arrow.triangle.2.circlepath"
        case .about:      return "atom"
        }
    }

    /// Grouping for the sidebar's Features/Customization/System headers.
    /// `nil` means the row sits ungrouped at the top of the sidebar.
    var category: String? {
        switch self {
        case .general:                                     return nil
        case .formats, .multi:                             return "Features"
        case .appearance, .rendering, .toolbar, .info:     return "Customization"
        case .updates, .about:                             return "System"
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

/// Rounded card with subtle translucent background — the container for
/// grouped rows inside a settings panel. Uses VisualEffectView under a
/// thin tint so the magenta+blue radial backdrop bleeds through and the
/// card reads as proper liquid glass (not opaque grey).
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.vertical, 4)
            .background(
                ZStack {
                    VisualEffectView(material: .contentBackground,
                                     blending: .withinWindow)
                    Color(NSColor.controlBackgroundColor).opacity(0.55)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
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
/// Used in Rendering / Info panels where each toggle has an explanatory
/// sub-line. The checkbox is anchored at a fixed leading position so
/// adjacent rows form a clean column regardless of label width.
private struct CheckRow: View {
    let label: String
    @Binding var isOn: Bool
    var sub: String? = nil
    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // Fixed-width checkbox area, left-anchored
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(CheckboxToggleStyle())
                    .frame(width: 18, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 13))
                    if let sub = sub {
                        Text(sub).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

/// NSVisualEffectView wrapper — for the System-Settings-style sidebar
/// vibrancy that SwiftUI's `.thinMaterial` can't provide at the macOS 11
/// deployment target. Material is configurable per-instance so the same
/// type can power both the sidebar (`.sidebar`) and the window backdrop
/// (`.underWindowBackground`) variants.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var state:    NSVisualEffectView.State = .followsWindowActiveState
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = state
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
        v.state = state
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
        ZStack {
            // Clean native window backdrop — matches the DockDoor-style
            // reference design the user supplied. The earlier magenta+blue
            // radial gradients fought with the panel content and never
            // delivered the glass effect we wanted; switching to a plain
            // window-background material reads as proper native macOS
            // Settings instead of a custom-tinted skin.
            Color(NSColor.windowBackgroundColor)
                .edgesIgnoringSafeArea(.all)

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
        }
        .frame(minWidth: 920, minHeight: 640)
        // App-wide magenta accent — matches the project's icon gradient and
        // the Claude Design template's magenta switches. SwiftUI cascades
        // this through every selection background, switch tint, and
        // Picker chevron beneath.
        .accentColor(Color(red: 0.76, green: 0.10, blue: 0.36))
        // App appearance override (v1.7.81+). System → nil so SwiftUI
        // continues to follow the macOS-wide Appearance setting (the
        // default behaviour for the entire app's history). Light/Dark
        // pin the window to that scheme regardless of what System
        // Settings says.
        .preferredColorScheme(userSettings.appearanceMode.colorScheme)
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        // Native macOS Settings styling — a transparent SwiftUI layer over
        // the window's stock background color. No tints, no gradients;
        // matches the DockDoor reference design.
        sidebarContent
    }

    @ViewBuilder
    private var sidebarContent: some View {
        // Built with ScrollView + VStack instead of List so its background
        // takes on the same windowBackgroundColor as the detail pane
        // (List's sidebar style paints a slightly darker grey panel that
        // can't be overridden at macOS 11 without scrollContentBackground,
        // which is 13+).
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Ungrouped rows at the top (General).
                    ForEach(SettingsSection.allCases.filter { $0.category == nil }) { section in
                        sidebarRow(section)
                    }
                    // Grouped rows under category headers — matches the
                    // DockDoor design: Features / Customization / System.
                    ForEach(["Features", "Customization", "System"], id: \.self) { cat in
                        Text(cat)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                        ForEach(SettingsSection.allCases.filter { $0.category == cat }) { section in
                            sidebarRow(section)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack(spacing: 8) {
                appIconImage
                    .resizable()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("QuickLookProtein2").font(.system(size: 11.5, weight: .semibold))
                    Text(appVersionString).font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        // Match the right panel's background exactly so the sidebar
        // doesn't read as a separate grey tile.
        .background(Color(NSColor.windowBackgroundColor))
    }

    /// One sidebar row — plain SF Symbol + label. Selected row gets the
    /// stock List selection background (light grey on macOS); we don't
    /// repaint with a magenta accent the way the previous redesign did.
    @ViewBuilder
    private func sidebarRow(_ section: SettingsSection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: section.symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.primary)
                .frame(width: 22, height: 22)
            Text(section.rawValue).font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selection == section
                      ? Color.primary.opacity(0.10)
                      : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selection = section }
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

    // sectionIcon was the colored-tile icon used by the previous sidebar
    // layout. Removed in v1.7.58 — the new sidebarRow uses plain
    // monochrome SF Symbols inline with no tile background.

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
        // Native System-Settings-style header: monochrome icon, smaller
        // title, no colored tile background. Matches the DockDoor design
        // the user referenced.
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundColor(.secondary)
                Text(section.rawValue).font(.system(size: 18, weight: .semibold))
                Spacer(minLength: 0)
            }
            Text(subtitle).font(.system(size: 12)).foregroundColor(.secondary)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Panels

    @ViewBuilder
    private var generalPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            panelHeader(.general, subtitle: "Quick Look behavior and viewer defaults")

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Quick Look")
                Card {
                    ToggleRow(label: "Enable QuickLookProtein2",
                              isOn: $userSettings.masterEnabled,
                              accessory: userSettings.masterEnabled
                                ? "Active — previewing 12 formats"
                                : "Disabled")
                    RowDivider()
                    ToggleRow(label: "Run on first preview",
                              isOn: $userSettings.runOnFirstPreview,
                              hint: "Render immediately on the first spacebar-press. Off shows a tap-to-render placeholder on slow disks.")
                    RowDivider()
                    // Open-at-Login (1.7.76+, moved from Appearance
                    // -> General in 1.7.79 per UI feedback). Belongs
                    // here next to the "Enable QuickLookProtein2"
                    // master toggle since both control the app's
                    // baseline behaviour rather than viewer
                    // appearance.  macOS 13+ flips SMAppService;
                    // 11/12 deep-links into System Settings.
                    HStack {
                        Text("Open at login")
                            .font(.system(size: 13))
                        Spacer()
                        if LoginItemController.shared.isAutomaticToggleSupported {
                            Toggle("", isOn: Binding(
                                get: { LoginItemController.shared.isEnabled },
                                set: { LoginItemController.shared.setEnabled($0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .help("Launch QuickLookProtein2 automatically when you sign in.")
                        } else {
                            Button("Open Login Items…") {
                                LoginItemController.shared.openSystemSettingsLoginItems()
                            }
                            .controlSize(.small)
                            .help("macOS 11 and 12 don't expose a programmatic toggle. Open the Login Items pane in System Settings and add QuickLookProtein2 there.")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Performance")
                Card {
                    Text("QuickLookProtein2 renders via 3Dmol.js in a WKWebView with hardware-accelerated WebGL. There is no per-app GPU/quality toggle — render cost is set by the structure size and the Default zoom under Appearance.")
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

            // Real WKWebView preview of this format's bundled sample
            // structure rendered at the current per-format atom-style.
            // The preview reloads when `style.wrappedValue` changes (the
            // .id() modifier forces SwiftUI to rebuild the WebView).
            ZStack {
                if let html = sampleHTML(forExt: ext, style: style.wrappedValue),
                   let baseUrl = sampleBaseURL {
                    WebView(html: html, baseUrl: baseUrl)
                        .id("\(ext)-\(style.wrappedValue.rawValue)")
                        .frame(height: 140)
                } else {
                    // No bundled sample for this format (CDJSON, MMTF) —
                    // fall back to the schematic SwiftUI render.
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color(red: 0.94, green: 0.95, blue: 0.96),
                            Color(red: 0.83, green: 0.85, blue: 0.88)
                        ]),
                        startPoint: .top, endPoint: .bottom)
                        .frame(height: 140)
                    FormatViewerPlaceholder(ext: ext, style: style.wrappedValue, tint: tint)
                        .padding(8)
                }
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
                .allowsHitTesting(false)
            }
            .frame(height: 140)
            .clipped()

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
            panelHeader(.appearance, subtitle: "App theme, color, motion, and background of the preview")

            // App-wide appearance override (v1.7.81+). Defaults to
            // System so the window follows macOS Appearance settings;
            // Light/Dark pin via SwiftUI's .preferredColorScheme on
            // ContentView. The picker uses a segmented style so all
            // three options stay visible without a popover round-trip,
            // matching the Mac System-Settings "Appearance" row.
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "App appearance")
                Card {
                    FormRow(label: "Theme") {
                        Picker("", selection: $userSettings.appearanceMode) {
                            ForEach(Settings.AppearanceMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 240)
                        .help("System: follow macOS Appearance setting. Light/Dark: pin the QuickLookProtein2 window to that scheme regardless of the system setting.")
                    }
                }
            }

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
                            ForEach(Settings.RotationSpeed.allCases) { speed in
                                Text(shortRotationLabel(speed)).tag(speed)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 240)
                    }
                    RowDivider()
                    FormRow(label: "Default zoom") {
                        Picker("", selection: $userSettings.defaultZoom) {
                            ForEach(Settings.DefaultZoom.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                    RowDivider()
                    // QL preview popover starting size (1.7.75+).
                    // macOS Quick Look honours this on the FIRST
                    // preview of each UTI; after the user drag-
                    // resizes once, Finder persists the new size
                    // per-UTI and ignores this value. So adjust here
                    // on a clean install, or set the desired
                    // "starting" size before previewing a new file
                    // type for the first time.
                    FormRow(label: "Preview size") {
                        HStack(spacing: 8) {
                            TextField("W", value: $userSettings.previewWidth,
                                      formatter: previewSizeFormatter)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                                .help("Initial Quick Look popover width in pixels (240–4000).")
                            Text("×").foregroundColor(.secondary)
                            TextField("H", value: $userSettings.previewHeight,
                                      formatter: previewSizeFormatter)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                                .help("Initial Quick Look popover height in pixels (180–4000).")
                            Text("px").foregroundColor(.secondary).font(.caption)
                            Spacer()
                            Button("Default") {
                                userSettings.previewWidth  = 560
                                userSettings.previewHeight = 420
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Background")
                Card {
                    FormRow(label: "Mode") {
                        HStack(spacing: 10) {
                            backgroundSwatch("Light",
                                             style: .solid(Color.white),
                                             rgba: (1.0, 1.0, 1.0, 1.0))
                            backgroundSwatch("Dark",
                                             style: .solid(Color(red: 0.07, green: 0.07, blue: 0.08)),
                                             rgba: (0.07, 0.07, 0.08, 1.0))
                            backgroundSwatch("Transparent",
                                             style: .checkerboard,
                                             rgba: (1.0, 1.0, 1.0, 0.0))
                            backgroundSwatch("Custom",
                                             style: .custom,
                                             rgba: nil)
                        }
                    }
                    RowDivider()
                    FormRow(label: "Custom color",
                            hint: "Used when Mode is Custom; the Light / Dark / Transparent presets override this.") {
                        ColorPicker("", selection: $userSettings.bgColor, supportsOpacity: true)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    /// Short labels for the Rotation segmented control. The full
    /// rawValues ("No rotation", "Medium", …) wrap awkwardly at 240 px;
    /// we keep the rawValues for persistence and substitute shorter
    /// display strings here.
    private func shortRotationLabel(_ speed: Settings.RotationSpeed) -> String {
        switch speed {
        case .noRotation: return "Off"
        case .slow:       return "Slow"
        case .medium:     return "Medium"
        case .fast:       return "Fast"
        }
    }

    enum SwatchStyle {
        case solid(Color)
        case checkerboard   // for the "Transparent" preset
        case custom         // user-chosen color
    }

    /// Tile for the Background-Mode picker. Light / Dark / Transparent
    /// each write a specific (r,g,b,a) into the bgColor* settings. The
    /// "Custom" tile is a passthrough that just selects whatever color
    /// is already in the picker.
    private func backgroundSwatch(_ label: String,
                                  style: SwatchStyle,
                                  rgba: (Double, Double, Double, Double)?) -> some View {
        // Selection logic: match (r,g,b,a) to within 2% on each channel.
        // Custom is selected only when no preset matches.
        let r = userSettings.bgColorRed
        let g = userSettings.bgColorGreen
        let b = userSettings.bgColorBlue
        let a = userSettings.bgColorOpacity
        let isSelected: Bool = {
            if let rgba = rgba {
                return abs(r - rgba.0) < 0.02 && abs(g - rgba.1) < 0.02
                    && abs(b - rgba.2) < 0.02 && abs(a - rgba.3) < 0.02
            }
            // Custom slot: selected when none of the presets matches.
            let matchesLight = abs(r - 1) < 0.02 && abs(g - 1) < 0.02 && abs(b - 1) < 0.02 && abs(a - 1) < 0.02
            let matchesDark  = abs(r - 0.07) < 0.02 && abs(g - 0.07) < 0.02 && abs(b - 0.08) < 0.02 && abs(a - 1) < 0.02
            let matchesTrans = abs(a) < 0.02
            return !(matchesLight || matchesDark || matchesTrans)
        }()
        return VStack(spacing: 4) {
            ZStack {
                switch style {
                case .solid(let c):
                    c
                case .checkerboard:
                    // Light/grey checkerboard. macOS-11 safe (Canvas is
                    // 12+) — built with a fixed grid of small Rectangles
                    // sized to the swatch.
                    ZStack {
                        Color.white
                        VStack(spacing: 0) {
                            ForEach(0..<6, id: \.self) { row in
                                HStack(spacing: 0) {
                                    ForEach(0..<8, id: \.self) { col in
                                        Rectangle()
                                            .fill((row + col).isMultiple(of: 2)
                                                  ? Color.clear
                                                  : Color.gray.opacity(0.35))
                                            .frame(width: 8, height: 8)
                                    }
                                }
                            }
                        }
                    }
                case .custom:
                    // Live preview of the current Custom color
                    Color(.sRGB, red: r, green: g, blue: b, opacity: max(a, 0.08))
                    Image(systemName: "eyedropper")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color.primary.opacity(0.5))
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
            if let rgba = rgba {
                userSettings.bgColorRed     = rgba.0
                userSettings.bgColorGreen   = rgba.1
                userSettings.bgColorBlue    = rgba.2
                userSettings.bgColorOpacity = rgba.3
            }
            // Custom slot has no preset write — it just signals "you'll
            // configure the color via the ColorPicker below".
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
                    FormRow(label: "Thumbnail style",
                            hint: "Sets how Finder renders the file icon. Auto picks ribbon for proteins (≥25 Cα), CPK spheres for everything else.") {
                        HStack(spacing: 10) {
                            thumbnailSwatch(.auto)
                            thumbnailSwatch(.cpk)
                            thumbnailSwatch(.ribbon)
                        }
                    }
                }
            }
        }
    }

    /// One tile for the Thumbnail-style picker. Each tile draws a tiny
    /// schematic of what Finder will render for that style.
    private func thumbnailSwatch(_ style: Settings.ThumbnailStyle) -> some View {
        let isSelected = userSettings.thumbnailStyle == style
        return VStack(spacing: 4) {
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.10, green: 0.10, blue: 0.11),
                        Color(red: 0.04, green: 0.04, blue: 0.05)
                    ]),
                    startPoint: .top, endPoint: .bottom)
                Group {
                    switch style {
                    case .auto:
                        // Mixed: small ribbon arc + a sphere triplet
                        Path { p in
                            p.move(to: CGPoint(x: 8, y: 30))
                            p.addQuadCurve(to: CGPoint(x: 56, y: 30),
                                           control: CGPoint(x: 32, y: 10))
                        }
                        .stroke(LinearGradient(
                            gradient: Gradient(colors: [.blue, .red]),
                            startPoint: .leading, endPoint: .trailing),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        HStack(spacing: 2) {
                            Circle().fill(Color.gray).frame(width: 7, height: 7)
                            Circle().fill(Color.blue).frame(width: 7, height: 7)
                            Circle().fill(Color.red).frame(width: 7, height: 7)
                        }
                        .offset(y: 12)
                    case .cpk:
                        HStack(spacing: 3) {
                            Circle().fill(Color.gray).frame(width: 16, height: 16)
                            Circle().fill(Color.blue).frame(width: 18, height: 18)
                            Circle().fill(Color.red).frame(width: 14, height: 14)
                        }
                    case .ribbon:
                        Path { p in
                            p.move(to: CGPoint(x: 6, y: 24))
                            for i in 1...18 {
                                let x = 6 + CGFloat(i) * 3.0
                                let y = 24 + sin(CGFloat(i) / 2.0) * 8
                                p.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                        .stroke(LinearGradient(
                            gradient: Gradient(colors: [.blue, .green, .yellow, .red]),
                            startPoint: .leading, endPoint: .trailing),
                                style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    }
                }
            }
            .frame(width: 64, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                                  lineWidth: isSelected ? 2 : 0.5)
            )
            Text(style.rawValue)
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { userSettings.thumbnailStyle = style }
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
        // Real 3Dmol preview of caffeine.mol2 — same molecule the design
        // mocks up, but rendered live with the user's current toolbar
        // settings so toggling Stick/Cartoon/etc actually shows the
        // resulting in-preview toolbar.
        ZStack {
            if let html = sampleHTML(forExt: "mol2", style: userSettings.atomStyleMOL2),
               let baseUrl = sampleBaseURL {
                WebView(html: html, baseUrl: baseUrl)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .id("toolbar-preview-\(userSettings.atomStyleMOL2.rawValue)-\(toolbarSignature)")
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(height: 200)
            }
        }
    }

    /// Cache-busting signature for the toolbar preview WebView so it
    /// reloads when any of the toolbar button toggles changes.
    private var toolbarSignature: String {
        [userSettings.showControlsInPreview,
         userSettings.ctlShowStick, userSettings.ctlShowLine,
         userSettings.ctlShowSphere, userSettings.ctlShowCartoon,
         userSettings.ctlShowSurface, userSettings.ctlShowColorSS,
         userSettings.ctlShowLabelCA, userSettings.ctlShowRecenter,
         userSettings.ctlShowRotation, userSettings.showShareButton]
            .map { $0 ? "1" : "0" }.joined()
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

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Live preview")
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        let rows: [(String, String, Bool)] = [
                            ("File name",         "6oc6.pdb",                userSettings.infoShowFileName),
                            ("File format",       "PDB",                     userSettings.infoShowFormat),
                            ("Atom count",        "12,488 atoms",            userSettings.infoShowAtomCount),
                            ("Chain count",       "4 chains",                userSettings.infoShowChainCount),
                            ("Residue count",     "1,560 residues",          userSettings.infoShowResidueCount),
                            ("Element breakdown", "C·6.2k H·5.1k N·1.0k O·1.1k", userSettings.infoShowElementBreakdown),
                            ("Molecular weight",  "156.8 kDa",               userSettings.infoShowMolWeight),
                            ("Bond count",        "12,820 bonds",            userSettings.infoShowBondCount),
                            ("PDB title",         "XoxF from M. extorquens", userSettings.infoShowPDBTitle),
                        ]
                        let visible = rows.filter { $0.2 }
                        if visible.isEmpty {
                            Text("No fields selected.")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(visible, id: \.0) { row in
                                HStack(alignment: .top, spacing: 12) {
                                    Text(row.0)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundColor(Color.primary.opacity(0.45))
                                        .frame(width: 130, alignment: .leading)
                                    Text(row.1)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundColor(Color.primary.opacity(0.78))
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(LinearGradient(
                                gradient: Gradient(colors: [
                                    Color(red: 0.96, green: 0.96, blue: 0.97),
                                    Color(red: 0.85, green: 0.85, blue: 0.87)
                                ]),
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .padding(10)
                }
                .opacity(userSettings.showInfoOverlay ? 1 : 0.45)
            }
        }
    }

    @ViewBuilder
    private var multiFilePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            panelHeader(.multi, subtitle: "Behavior when previewing more than one structure at once")

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Layout")
                Card {
                    FormRow(label: "When previewing many files") {
                        VStack(alignment: .leading, spacing: 10) {
                            multiModeRadio(
                                .separate,
                                title: "Separate windows (default)",
                                sub: "Quick Look's standard ⌘‹/⌘› navigation — best for comparing one at a time")
                            multiModeRadio(
                                .mergeFolder,
                                title: "Merge all in same folder",
                                sub: "Overlay every readable sibling in one viewport — sandbox permitting (use Quick Actions for guaranteed merge)")
                        }
                    }
                }
                Text("Quick Look's sandbox usually hands the preview extension one file at a time, so spacebar-multi-select doesn't always trigger a merge. For a guaranteed merge: right-click 2+ files → Quick Actions → Render Molecule to PNG, then open the `<first>-merged.pdb` that appears next to them.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
        }
    }

    /// One radio row with a primary label + explanatory sub-line. Styled
    /// to match the design's bullet+description pattern.
    private func multiModeRadio(_ mode: Settings.MultiFilePreviewMode,
                                title: String,
                                sub: String) -> some View {
        let selected = userSettings.multiFilePreviewMode == mode
        return Button {
            userSettings.multiFilePreviewMode = mode
        } label: {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(selected ? Color.accentColor : Color.primary.opacity(0.3),
                                lineWidth: selected ? 5 : 1)
                        .frame(width: 14, height: 14)
                }
                .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    Text(sub).font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var updatesPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            panelHeader(.updates, subtitle: "Stay current with signed, notarised releases")

            // Hero status card — branches on whether Sparkle actually
            // started. When it didn't, the card switches to a yellow
            // "auto-updates unavailable" state with the specific reason
            // and a "Download from GitHub" CTA (instead of pretending
            // the software is up to date).
            Card {
                HStack(spacing: 14) {
                    Image(systemName: updater.sparkleAvailable
                          ? "arrow.triangle.2.circlepath"
                          : "exclamationmark.triangle.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 48, height: 48)
                        .background(updater.sparkleAvailable
                                    ? LinearGradient(
                                        gradient: Gradient(colors: [Color(red: 0.04, green: 0.52, blue: 1.00),
                                                                    Color(red: 0.37, green: 0.61, blue: 1.00)]),
                                        startPoint: .topLeading, endPoint: .bottomTrailing)
                                    : LinearGradient(
                                        gradient: Gradient(colors: [Color(red: 0.95, green: 0.62, blue: 0.18),
                                                                    Color(red: 0.92, green: 0.40, blue: 0.10)]),
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(heroUpdateTitle).font(.system(size: 15, weight: .semibold))
                        Text(heroUpdateSubtitle)
                            .font(.system(size: 12)).foregroundColor(.secondary)
                        if updater.sparkleAvailable {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(red: 0.20, green: 0.78, blue: 0.35))
                                Text("Verified with Sparkle EdDSA signature")
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                            }
                        } else {
                            Text(updater.sparkleUnavailableReason)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 6) {
                        if updater.sparkleAvailable {
                            Button("Check for Updates") { updater.checkForUpdates() }
                                .buttonStyle(PrimaryPillButtonStyle())
                            Button("Download from GitHub") { updater.openReleasesPage() }
                                .buttonStyle(SecondaryPillButtonStyle())
                        } else {
                            Button("Download from GitHub") { updater.openReleasesPage() }
                                .buttonStyle(PrimaryPillButtonStyle())
                        }
                    }
                }
                .padding(16)
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Updates")
                Card {
                    ToggleRow(label: "Check automatically",
                              isOn: $updater.automaticallyChecksForUpdates,
                              hint: "Sparkle polls the GitHub appcast at the cadence below.")
                    RowDivider()
                    FormRow(label: "Check frequency") {
                        Picker("", selection: $updater.updateCheckCadence) {
                            ForEach(Updater.UpdateCheckCadence.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Maintenance")
                Card {
                    FormRow(label: "Quick Look cache",
                            hint: "Run if previews stop refreshing after an update.") {
                        Button("Reset Quick Look cache") { updater.resetQuickLookCache() }
                    }
                }
                if !updater.lastCheckStatus.isEmpty {
                    Text(updater.lastCheckStatus)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                }
            }

            troubleshootingCard
        }
    }

    private var heroUpdateTitle: String {
        if !updater.sparkleAvailable {
            return "Auto-updates are unavailable"
        }
        if updater.lastCheckStatus.lowercased().contains("checking") {
            return "Checking for updates…"
        }
        return "Your software is up to date."
    }

    private var heroUpdateSubtitle: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "QuickLookProtein2 \(v) (build \(b))"
    }

    @ViewBuilder
    private var aboutPanel: some View {
        let v  = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b  = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let min = Bundle.main.infoDictionary?["LSMinimumSystemVersion"] as? String ?? ""

        VStack(alignment: .leading, spacing: 18) {
            // Hero: real AppIcon + name + version line
            VStack(alignment: .center, spacing: 8) {
                appIconImage
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 6)
                Text("QuickLookProtein2").font(.system(size: 24, weight: .bold))
                Text("Version \(v) (build \(b))\(min.isEmpty ? "" : " · macOS \(min) +")")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Credits")
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        // Original author gets top billing — the bold,
                        // larger-font line — to make clear that
                        // QuickLookProtein2 is an extension of Jethro's
                        // original work, not a separate project.
                        (Text("Originally built by ") +
                         Text("Jethro Hemmann").bold() +
                         Text(" (2021–2022) — the original QuickLookProtein."))
                            .font(.system(size: 13))
                        (Text("Extended by ") +
                         Text("Ariorad Moniri").bold() +
                         Text(" (2026) as QuickLookProtein2 — multi-format support, smart protein+ligand styling, molecular surfaces, Finder thumbnails, Spotlight indexing, drag-and-drop preview, Quick Actions, AR-Quick-Look USDZ, DCD/TRR/XTC trajectories, and Sparkle auto-update."))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    RowDivider()
                    // Original repo first, then this fork — same
                    // ordering principle as the credit lines above.
                    HStack(spacing: 10) {
                        Image(systemName: "link")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                        Button("github.com/JethroHemmann/QuickLookProtein (original)") {
                            if let u = URL(string: "https://github.com/JethroHemmann/QuickLookProtein") {
                                NSWorkspace.shared.open(u)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                        .font(.system(size: 12.5))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    HStack(spacing: 10) {
                        Image(systemName: "link")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                        Button("github.com/ArioMoniri/QuickLookProtein (this fork)") {
                            if let u = URL(string: "https://github.com/ArioMoniri/QuickLookProtein") {
                                NSWorkspace.shared.open(u)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                        .font(.system(size: 12.5))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .padding(.bottom, 4)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Supported formats")
                Card {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)],
                              alignment: .leading, spacing: 8) {
                        formatBadgeRow("PDB",    "Protein Data Bank",     Color(red: 0.90, green: 0.27, blue: 0.27))
                        formatBadgeRow("CIF",    "Crystallographic IF",   Color(red: 0.94, green: 0.54, blue: 0.12))
                        formatBadgeRow("SDF",    "Structure Data File",   Color(red: 0.90, green: 0.72, blue: 0.17))
                        formatBadgeRow("MOL",    "MDL Molfile",           Color(red: 0.36, green: 0.69, blue: 0.29))
                        formatBadgeRow("MOL2",   "Tripos Mol2",           Color(red: 0.15, green: 0.65, blue: 0.58))
                        formatBadgeRow("XYZ",    "XYZ Coordinates",       Color(red: 0.22, green: 0.68, blue: 0.86))
                        formatBadgeRow("GRO",    "GROMACS",               Color(red: 0.23, green: 0.51, blue: 0.90))
                        formatBadgeRow("CUBE",   "Gaussian Cube",         Color(red: 0.48, green: 0.36, blue: 0.90))
                        formatBadgeRow("PQR",    "PDB + Charge/Radius",   Color(red: 0.76, green: 0.31, blue: 0.72))
                        formatBadgeRow("VASP",   "VASP POSCAR",           Color(red: 0.43, green: 0.47, blue: 0.52))
                        formatBadgeRow("CDJSON", "ChemDraw JSON",         Color(red: 0.60, green: 0.42, blue: 0.25))
                        formatBadgeRow("MMTF",   "MacroMol Transmission", Color(red: 0.31, green: 0.42, blue: 0.76))
                    }
                    .padding(12)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Rendering engine")
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        (Text("Rendered by ") +
                         Text("3Dmol.js").bold() +
                         Text(" (Rego & Koes, 2015)"))
                            .font(.system(size: 13))
                        Button("3dmol.csb.pitt.edu →") {
                            if let u = URL(string: "https://3dmol.csb.pitt.edu") {
                                NSWorkspace.shared.open(u)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                        .font(.system(size: 12))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }

            footerCredit
        }
    }

    /// One row in the "Supported formats" grid: colored monospace badge +
    /// truncated friendly name. Mirrors the design's FormatBadge layout.
    private func formatBadgeRow(_ ext: String, _ name: String, _ tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(ext)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(name)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        // Whole-row tooltip pairs the short extension with the
        // full descriptive name so users hovering a truncated
        // entry (e.g. "Crystallographic..." in a narrow grid
        // column) get the unabridged information.  Pulled from a
        // lookup table rather than the visible `name` string so
        // the tooltip is always the full spelling even when the
        // visible label was shortened to fit the column.
        .help(Self.formatTooltip(ext: ext, shortName: name))
    }

    /// Map the short extension tag to a tooltip that includes both
    /// the file extension list and a fully-spelled description.
    /// The visible row truncates aggressively to fit the four-column
    /// grid; this is what users see when they hover.
    private static func formatTooltip(ext: String, shortName: String) -> String {
        let fullName: String
        let extensions: String
        switch ext {
        case "PDB":    fullName = "Protein Data Bank";                       extensions = ".pdb, .ent"
        case "CIF":    fullName = "Crystallographic Information File";       extensions = ".cif, .mmcif"
        case "SDF":    fullName = "MDL Structure-Data File";                 extensions = ".sdf"
        case "MOL":    fullName = "MDL Molfile";                             extensions = ".mol"
        case "MOL2":   fullName = "Tripos Mol2";                             extensions = ".mol2"
        case "XYZ":    fullName = "XYZ Coordinates";                         extensions = ".xyz"
        case "GRO":    fullName = "GROMACS structure";                       extensions = ".gro"
        case "CUBE":   fullName = "Gaussian Cube";                           extensions = ".cube, .cub"
        case "PQR":    fullName = "PDB with Charge and Radius (APBS/PDB2PQR)"; extensions = ".pqr"
        case "VASP":   fullName = "VASP POSCAR";                             extensions = ".vasp, .poscar"
        case "CDJSON": fullName = "ChemDraw JSON";                           extensions = ".cdjson"
        case "MMTF":   fullName = "Macromolecular Transmission Format";       extensions = ".mmtf"
        default:       fullName = shortName;                                 extensions = "." + ext.lowercased()
        }
        return "\(fullName) — \(extensions)"
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

                    // Last install error (1.7.80+). Populated by
                    // Updater's didAbortWithError SPUUpdaterDelegate
                    // method. Shows the actual NSError domain + code
                    // + reason rather than Sparkle's generic
                    // "An error occurred while launching the
                    // installer" modal so users can paste the real
                    // failure into a bug report.
                    if let installErr = updater.lastInstallError {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                                Text("Last update attempt failed")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                            }
                            // .textSelection requires macOS 12+. Gate
                            // so the build still targets 11.0 cleanly.
                            Group {
                                if #available(macOS 12.0, *) {
                                    Text(installErr)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(4)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                } else {
                                    Text(installErr)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(4)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
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

                        // Open update log — surfaces the file Updater
                        // writes every state transition to. Cheap
                        // diagnostic for users who keep hitting "An
                        // error occurred while launching the
                        // installer" so they can paste the actual
                        // SUError domain + code into a bug report.
                        Button(action: { updater.openUpdateLog() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text.magnifyingglass")
                                Text("Open update log")
                            }
                        }
                        .buttonStyle(SecondaryPillButtonStyle())
                        .help("Open the rolling update log written by Sparkle's delegate. Every check / install / abort lands here with the underlying NSError - useful for diagnosing repeated Update Error dialogs.")
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

                    // Lead with the original author. The "2" rebrand is
                    // a friendly extension, not a replacement, and we
                    // want first-time users to recognise that the core
                    // QuickLookProtein concept is Jethro's work.
                    (Text("Originally built by ")
                        + Text("Jethro Hemmann").fontWeight(.semibold)
                        + Text(" (2021–2022) — the original QuickLookProtein."))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .foregroundColor(.secondary)
                        Link("github.com/JethroHemmann/QuickLookProtein",
                             destination: URL(string: "https://github.com/JethroHemmann/QuickLookProtein")!)
                            .font(.callout)
                    }
                    .padding(.top, 2)

                    Divider()
                        .padding(.vertical, 2)

                    Text("Extended by Ariorad Moniri (2026) as QuickLookProtein2 — multi-format support, smart protein+ligand styling, molecular surfaces, Finder thumbnails, Spotlight indexing, drag-and-drop preview, and Sparkle auto-update.")
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

                    // Homebrew install hint. Surfaces the cask path
                    // for users who'd rather brew-install than drag
                    // the .app from a DMG; the in-app Sparkle updater
                    // continues to handle subsequent upgrades either
                    // way (auto_updates true in the cask).
                    HStack(spacing: 6) {
                        Image(systemName: "mug.fill")
                            .foregroundColor(.orange)
                        // .textSelection is macOS 12+; the app's
                        // LSMinimumSystemVersion is 11.0 so we
                        // gate the modifier per-platform. Older
                        // systems still see the formatted text,
                        // just without copy-on-drag selection.
                        Group {
                            if #available(macOS 12.0, *) {
                                Text("brew install --cask quicklookprotein")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                            } else {
                                Text("brew install --cask quicklookprotein")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
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

    /// baseURL passed to every WKWebView preview — required so the
    /// viewer template can resolve its bundled `<script src="3Dmol.js">`.
    private var sampleBaseURL: URL? {
        Bundle.main.path(forResource: "3Dmol_viewer", ofType: "html")
            .map { URL(fileURLWithPath: $0) }
    }

    /// Resolve `ext` to a bundled sample structure and build the HTML
    /// that renders it at the requested atom-style. Returns nil when
    /// no sample exists for this format (CDJSON / MMTF) — the caller
    /// falls back to a schematic SwiftUI placeholder.
    private func sampleHTML(forExt ext: String, style: Settings.AtomStyle) -> String? {
        guard let htmlPath = Bundle.main.path(forResource: "3Dmol_viewer", ofType: "html") else {
            return nil
        }
        let lower = ext.lowercased()
        let resource: (name: String, type: String)?
        switch lower {
        case "pdb":    resource = ("6oc6",     "pdb")
        case "cif":    resource = ("1565673",  "cif")
        case "sdf":    resource = ("PQQ",      "sdf")
        case "mol":    resource = ("methane",  "mol")
        case "mol2":   resource = ("caffeine", "mol2")
        case "xyz":    resource = ("benzene",  "xyz")
        case "gro":    resource = ("water",    "gro")
        case "cube":   resource = ("water",    "cube")
        case "pqr":    resource = ("methane",  "pqr")
        case "vasp":   resource = ("diamond",  "vasp")
        case "cdjson": resource = ("methane",  "cdjson")
        // MMTF goes through prepare3DmolHTML's binary-base64 branch
        // (added in v1.7.57) — bytes are read as Data, base64-encoded,
        // and the viewer's JS layer does atob → Uint8Array → addModel.
        case "mmtf":   resource = ("methane",  "mmtf")
        default:       resource = nil
        }
        guard let r = resource,
              let p = Bundle.main.path(forResource: r.name, ofType: r.type)
        else { return nil }
        // Build a ViewerOptions that mirrors the user's settings but pins
        // the atom-style to the one this card displays, so all 12 cards
        // can preview different styles simultaneously.
        var opts = ViewerOptions.from(userSettings,
                                      fileExtension: r.type,
                                      fileName: "\(r.name).\(r.type)")
        opts.atomStyle = style
        return prepare3DmolHTML(htmlPath: htmlPath,
                                pdbPath: p,
                                dataFormat: Settings.dataFormat(forExtension: r.type) ?? "pdb",
                                options: opts)
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
