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

struct ContentView: View {

    @StateObject private var userSettings = SettingsStorage()
    @ObservedObject private var updater = Updater.shared
    /// File the user has dragged into the "Custom" tile.
    @State private var droppedFile: URL? = nil
    @State private var droppedFileError: String? = nil
    @State private var isDropTargeted: Bool = false
    /// Whether the "Quick Look not updating?" card is expanded. Drives a
    /// custom DisclosureGroup so the *entire* header row (icon + title +
    /// subtitle + chevron) is the tap target, not just the chevron.
    @State private var troubleshootingExpanded: Bool = false

    var body: some View {
        let htmlPath = Bundle.main.path(forResource: "3Dmol_viewer", ofType: "html")!
        let pdbPath  = Bundle.main.path(forResource: "6oc6",          ofType: "pdb")!
        let cifPath  = Bundle.main.path(forResource: "1565673",       ofType: "cif")!
        let sdfPath  = Bundle.main.path(forResource: "PQQ",           ofType: "sdf")!
        let molPath  = Bundle.main.path(forResource: "methane",       ofType: "mol")!
        let mol2Path = Bundle.main.path(forResource: "caffeine",      ofType: "mol2")!
        let xyzPath  = Bundle.main.path(forResource: "benzene",       ofType: "xyz")!
        let groPath  = Bundle.main.path(forResource: "water",         ofType: "gro")!
        let cubePath = Bundle.main.path(forResource: "water",         ofType: "cube")!
        let pqrPath    = Bundle.main.path(forResource: "methane",     ofType: "pqr")!
        let vaspPath   = Bundle.main.path(forResource: "diamond",     ofType: "vasp")!
        // CDJSON intentionally has no demo tile: 3Dmol's bundled cdjson
        // parser produces atoms but no usable bond data even on textbook
        // ChemDoodle JSON input, so the tile would always render blank.
        // The format is still registered (UTI, Settings Picker, file-drop
        // support) so users with .cdjson files that DO render can use them.

        let baseUrl = URL(fileURLWithPath: htmlPath)

        let htmlPDB    = previewHTML(htmlPath: htmlPath, filePath: pdbPath,    ext: "pdb")
        let htmlCIF    = previewHTML(htmlPath: htmlPath, filePath: cifPath,    ext: "cif")
        let htmlSDF    = previewHTML(htmlPath: htmlPath, filePath: sdfPath,    ext: "sdf")
        let htmlMOL    = previewHTML(htmlPath: htmlPath, filePath: molPath,    ext: "mol")
        let htmlMOL2   = previewHTML(htmlPath: htmlPath, filePath: mol2Path,   ext: "mol2")
        let htmlXYZ    = previewHTML(htmlPath: htmlPath, filePath: xyzPath,    ext: "xyz")
        let htmlGRO    = previewHTML(htmlPath: htmlPath, filePath: groPath,    ext: "gro")
        let htmlCUBE   = previewHTML(htmlPath: htmlPath, filePath: cubePath,   ext: "cube")
        let htmlPQR    = previewHTML(htmlPath: htmlPath, filePath: pqrPath,    ext: "pqr")
        let htmlVASP   = previewHTML(htmlPath: htmlPath, filePath: vaspPath,   ext: "vasp")

        // Single scrollable page — settings + about at the top, previews below.
        // No fixed split, no clamped scroll region. The whole thing scrolls if
        // the window gets too short for everything; otherwise it just lays out
        // naturally and the previews grow with the available width.
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {

                HStack(alignment: .top, spacing: 24) {

                    // MARK: Settings — every format in one list, every menu row
                    //                 is fully clickable (label included).
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Settings").font(.title)

                        Text("Atom display style").font(.headline)
                        // Standard Form-wrapped Pickers: the entire row including
                        // the "PDB:" label is the popup button's hit area on macOS,
                        // so clicking the label opens the dropdown. The fancy
                        // custom Menu styling we tried earlier collapsed to a
                        // tiny chevron because .menuStyle stripped the default
                        // popup-button frame — use the standard control instead.
                        Form {
                            Picker("PDB:",    selection: $userSettings.atomStylePDB)    { atomStyleOptions }
                            Picker("CIF:",    selection: $userSettings.atomStyleCIF)    { atomStyleOptions }
                            Picker("SDF:",    selection: $userSettings.atomStyleSDF)    { atomStyleOptions }
                            Picker("MOL:",    selection: $userSettings.atomStyleMOL)    { atomStyleOptions }
                            Picker("MOL2:",   selection: $userSettings.atomStyleMOL2)   { atomStyleOptions }
                            Picker("XYZ:",    selection: $userSettings.atomStyleXYZ)    { atomStyleOptions }
                            Picker("GRO:",    selection: $userSettings.atomStyleGRO)    { atomStyleOptions }
                            Picker("CUBE:",   selection: $userSettings.atomStyleCUBE)   { atomStyleOptions }
                            Picker("PQR:",    selection: $userSettings.atomStylePQR)    { atomStyleOptions }
                            Picker("VASP:",   selection: $userSettings.atomStyleVASP)   { atomStyleOptions }
                            Picker("CDJSON:", selection: $userSettings.atomStyleCDJSON) { atomStyleOptions }
                            Picker("MMTF:",   selection: $userSettings.atomStyleMMTF)   { atomStyleOptions }
                        }
                        .frame(maxWidth: 340)

                        Text("Appearance").font(.headline).padding(.top, 6)
                        Form {
                            Picker("Color scheme:", selection: $userSettings.colorScheme) {
                                ForEach(Settings.ColorScheme.allCases) { Text($0.rawValue).tag($0) }
                            }
                            Picker("Rotation:", selection: $userSettings.rotationSpeed) {
                                ForEach(Settings.RotationSpeed.allCases) { Text($0.rawValue).tag($0) }
                            }
                            Picker("Default zoom:", selection: $userSettings.defaultZoom) {
                                ForEach(Settings.DefaultZoom.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .help("Applied to every preview after 3Dmol's auto-fit. Also affects the Quick Look extension.")
                            HStack {
                                ColorPicker("Background:", selection: $userSettings.bgColor, supportsOpacity: true)
                                    .help("#" + convertColorToRGB(color: userSettings.bgColor).rgbHex
                                          + ", alpha: " + convertColorToRGB(color: userSettings.bgColor).alpha)
                                Button("Transparent", action: resetColor)
                            }
                        }
                        .frame(maxWidth: 340)

                        Text("Rendering options").font(.headline).padding(.top, 6)
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Smart protein + ligand styling", isOn: $userSettings.autoStyleHetero)
                                .help("When a file contains both a protein and a ligand, render the protein with the chosen style and ligands as sticks.")
                            Toggle("Show molecular surface",          isOn: $userSettings.showSurface)
                            Toggle("Hide hydrogens",                  isOn: $userSettings.hideHydrogens)
                            Toggle("Show unit cell (CIF)",            isOn: $userSettings.showUnitCell)
                            Toggle("Show info overlay",               isOn: $userSettings.showInfoOverlay)
                            Toggle("Show interactive controls",       isOn: $userSettings.showControlsInPreview)
                                .help("Adds a small bottom-right toolbar in every Quick Look preview with one-click buttons for Stick / Line / Sphere / Cartoon style, Surface, Color SS, Label αC, and Recenter.")
                            Toggle("Outline shading",                 isOn: $userSettings.outlineShading)
                                .help("Adds a thin dark border around every atom/bond. Makes the preview pop on light backgrounds.")
                            Toggle("Auto-orient (longest axis horizontal)", isOn: $userSettings.autoOrient)
                                .help("Rotate the molecule so its longest principal axis is horizontal. Useful for screenshots; gives every preview a deterministic canonical pose.")
                            Toggle("Cube isosurface",                 isOn: $userSettings.cubeIsosurface)
                                .help("Render Gaussian Cube files as ±isovalue isosurfaces (blue/red) instead of bare atoms. Useful for orbital / electron-density plots.")
                            Toggle("Biological assembly",             isOn: $userSettings.bioAssembly)
                                .help("Expand PDB / CIF files into their full biological assembly using REMARK 350 (PDB) or _pdbx_struct_oper_list (CIF) transformations. Off: show only the asymmetric unit.")
                            Toggle("Cryo-EM density isosurface",      isOn: $userSettings.cryoEMRender)
                                .help("Render .ccp4 / .mrc / .map files as a volumetric isosurface. Off: those files fall back to the host's text viewer.")
                            Toggle("Share button in preview",         isOn: $userSettings.showShareButton)
                                .help("Adds a Share button to the in-preview toolbar that captures the current rendering as PNG and presents the system Sharing picker.")
                            Toggle("Animated thumbnails (experimental)", isOn: $userSettings.animatedThumbnails)
                                .help("Encode Finder thumbnails as 12-frame spinning APNGs (≥128 px only). Renders ~12x slower per thumbnail. macOS Finder displays the first frame statically — visible animation requires third-party viewers that honour APNG.")
                            Picker("Thumbnail style", selection: $userSettings.thumbnailStyle) {
                                ForEach(Settings.ThumbnailStyle.allCases) { style in
                                    Text(style.rawValue).tag(style)
                                }
                            }
                            .help("Pin the Finder thumbnail render style. Auto picks ribbon for proteins (≥25 Cα) and CPK spheres for everything else.")
                        }

                        // Per-button toolbar visibility - gated on the master
                        // "Show interactive controls" toggle above. When that
                        // toggle is off, the whole bar is hidden so flipping
                        // these has no immediate effect; we still keep the UI
                        // alive so users can pre-configure their selection.
                        Text("Toolbar buttons").font(.headline).padding(.top, 8)
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Stick",     isOn: $userSettings.ctlShowStick)
                            Toggle("Line",      isOn: $userSettings.ctlShowLine)
                            Toggle("Sphere",    isOn: $userSettings.ctlShowSphere)
                            Toggle("Cartoon",   isOn: $userSettings.ctlShowCartoon)
                            Toggle("Surface",   isOn: $userSettings.ctlShowSurface)
                            Toggle("Color SS",  isOn: $userSettings.ctlShowColorSS)
                            Toggle("Label αC",  isOn: $userSettings.ctlShowLabelCA)
                            Toggle("Recenter",  isOn: $userSettings.ctlShowRecenter)
                        }
                        .disabled(!userSettings.showControlsInPreview)
                        .opacity(userSettings.showControlsInPreview ? 1 : 0.4)

                        // MARK: Info-overlay fields - which bits of info appear
                        //       in the info pill at the top-left of every
                        //       preview. Gated on the master "Show info
                        //       overlay" toggle above so users can hide the
                        //       whole strip without re-checking each field.
                        Text("Info overlay fields").font(.headline).padding(.top, 8)
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("File name",          isOn: $userSettings.infoShowFileName)
                            Toggle("Atom count",         isOn: $userSettings.infoShowAtomCount)
                            Toggle("Chain count",        isOn: $userSettings.infoShowChainCount)
                            Toggle("Residue count",      isOn: $userSettings.infoShowResidueCount)
                            Toggle("Element breakdown",  isOn: $userSettings.infoShowElementBreakdown)
                                .help("Top four most abundant elements with counts, e.g. \"C:120 N:36 O:30 H:24\".")
                            Toggle("Molecular weight",   isOn: $userSettings.infoShowMolWeight)
                                .help("Sum of standard atomic masses (Daltons / kDa above 1000).")
                            Toggle("Bond count",         isOn: $userSettings.infoShowBondCount)
                            Toggle("PDB title",          isOn: $userSettings.infoShowPDBTitle)
                                .help("First TITLE record from the PDB header. Only meaningful for .pdb / .ent files.")
                            Toggle("File format",        isOn: $userSettings.infoShowFormat)
                        }
                        .disabled(!userSettings.showInfoOverlay)
                        .opacity(userSettings.showInfoOverlay ? 1 : 0.4)

                        // MARK: Multi-file Quick Look behaviour.
                        //       Quick Look's `<` `>` navigation between
                        //       selected files is built into macOS and
                        //       can't be disabled from a Quick Look
                        //       extension. The "Merge in same folder"
                        //       option is honoured by the preview
                        //       extension - it reads sibling structures
                        //       and stacks them in one 3Dmol scene.
                        Text("Multiple-file preview").font(.headline).padding(.top, 8)
                        Form {
                            Picker("When previewing many files:",
                                   selection: $userSettings.multiFilePreviewMode) {
                                ForEach(Settings.MultiFilePreviewMode.allCases) {
                                    Text($0.rawValue).tag($0)
                                }
                            }
                        }
                        .frame(maxWidth: 340)
                    }
                    .padding()

                    // MARK: About — three card-style sections (Updates, Credits,
                    //               Troubleshooting). The big shift from the old layout
                    //               is that "Check for updates" is now the primary CTA
                    //               in its own card, with a colored icon + version line
                    //               + prominent button, rather than a tiny right-aligned
                    //               control next to "Installed version:".
                    VStack(alignment: .leading, spacing: 14) {
                        Text("About").font(.title).padding(.bottom, 2)

                        updatesCard
                        creditsCard
                        troubleshootingCard
                        footerCredit
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(.horizontal, 8)

                Divider()
                    .padding(.horizontal, 8)

                // MARK: Live previews — one tile per supported format, plus the
                //       custom drag/click-to-upload tile. 3-column LazyVGrid so
                //       all nine fit in a reasonably-sized window without
                //       shrinking individual tiles below readability.
                let previewColumns: [GridItem] = [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ]
                LazyVGrid(columns: previewColumns, spacing: 12) {
                    previewTile(html: htmlPDB,  base: baseUrl,
                                title: "PDB",
                                caption: { (Text("XoxF from ") + Text("M. extorquens").italic() + Text(" (6OC6)")) })
                    previewTile(html: htmlCIF,  base: baseUrl,
                                title: "CIF",
                                caption: { Text("Bioinspired Fe complex (1565673)") })
                    previewTile(html: htmlSDF,  base: baseUrl,
                                title: "SDF",
                                caption: { Text("Pyrroloquinoline quinone (CID 1024)") })

                    previewTile(html: htmlMOL,  base: baseUrl,
                                title: "MOL",
                                caption: { Text("Methane (V2000)") })
                    previewTile(html: htmlMOL2, base: baseUrl,
                                title: "MOL2",
                                caption: { Text("Caffeine") })
                    previewTile(html: htmlXYZ,  base: baseUrl,
                                title: "XYZ",
                                caption: { Text("Benzene (XMol XYZ)") })

                    previewTile(html: htmlGRO,  base: baseUrl,
                                title: "GRO",
                                caption: { Text("Water (GROMACS)") })
                    previewTile(html: htmlCUBE, base: baseUrl,
                                title: "CUBE",
                                caption: { Text("Water (Gaussian Cube)") })
                    previewTile(html: htmlPQR,  base: baseUrl,
                                title: "PQR",
                                caption: { Text("Methane (PDB + charge/radius)") })

                    previewTile(html: htmlVASP, base: baseUrl,
                                title: "VASP",
                                caption: { Text("Diamond cubic carbon (POSCAR)") })

                    customDropTile(htmlPath: htmlPath, baseUrl: baseUrl)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
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
// `.regularMaterial` / `.background(.thinMaterial)` would require macOS 12
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
