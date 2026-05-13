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
    "pdb", "ent", "pdbqt", "cif", "mmcif", "sdf", "mol", "mol2", "xyz", "gro", "cube", "cub"
]

/// Drop-path size cap: same 25 MB ceiling the Quick Look extension uses. Preview the
/// SwiftUI app is generous on memory but a 1 GB PDB still blocks the main thread for
/// long enough to feel like a hang.
private let maxDropBytes: Int = 25 * 1024 * 1024

struct ContentView: View {

    @StateObject private var userSettings = SettingsStorage()
    /// File the user has dragged into the "Custom" tile.
    @State private var droppedFile: URL? = nil
    @State private var droppedFileError: String? = nil
    @State private var isDropTargeted: Bool = false

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

        let baseUrl = URL(fileURLWithPath: htmlPath)

        let htmlPDB  = previewHTML(htmlPath: htmlPath, filePath: pdbPath,  ext: "pdb")
        let htmlCIF  = previewHTML(htmlPath: htmlPath, filePath: cifPath,  ext: "cif")
        let htmlSDF  = previewHTML(htmlPath: htmlPath, filePath: sdfPath,  ext: "sdf")
        let htmlMOL  = previewHTML(htmlPath: htmlPath, filePath: molPath,  ext: "mol")
        let htmlMOL2 = previewHTML(htmlPath: htmlPath, filePath: mol2Path, ext: "mol2")
        let htmlXYZ  = previewHTML(htmlPath: htmlPath, filePath: xyzPath,  ext: "xyz")
        let htmlGRO  = previewHTML(htmlPath: htmlPath, filePath: groPath,  ext: "gro")
        let htmlCUBE = previewHTML(htmlPath: htmlPath, filePath: cubePath, ext: "cube")

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
                        // so clicking the label opens the dropdown natively.
                        Form {
                            Picker("PDB:",  selection: $userSettings.atomStylePDB)  { atomStyleOptions }
                            Picker("CIF:",  selection: $userSettings.atomStyleCIF)  { atomStyleOptions }
                            Picker("SDF:",  selection: $userSettings.atomStyleSDF)  { atomStyleOptions }
                            Picker("MOL:",  selection: $userSettings.atomStyleMOL)  { atomStyleOptions }
                            Picker("MOL2:", selection: $userSettings.atomStyleMOL2) { atomStyleOptions }
                            Picker("XYZ:",  selection: $userSettings.atomStyleXYZ)  { atomStyleOptions }
                            Picker("GRO:",  selection: $userSettings.atomStyleGRO)  { atomStyleOptions }
                            Picker("CUBE:", selection: $userSettings.atomStyleCUBE) { atomStyleOptions }
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
                        }
                    }
                    .padding()

                    // MARK: About
                    VStack(alignment: .leading, spacing: 6) {
                        Text("About").font(.title).padding(.bottom, 2)
                        Text("Developed 2021–2022 by Jethro Hemmann.").font(.callout)
                        Link("https://github.com/JethroHemmann/QuickLookProtein",
                             destination: URL(string: "https://github.com/JethroHemmann/QuickLookProtein")!)
                            .font(.callout)

                        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                            Text("Installed version: \(appVersion)").font(.callout).padding(.top, 2)
                            let appVersionArr = appVersion.split(separator: ".")
                            if appVersionArr.count >= 2,
                               let appMajor = Int(appVersionArr[0]),
                               let appMinor = Int(appVersionArr[1]),
                               let mostRecentVersion = getNewestVersion() {
                                if newerVersion(installedVersion: (major: appMajor, minor: appMinor),
                                                mostRecentVersion: mostRecentVersion) {
                                    HStack {
                                        Text("New version \(mostRecentVersion.major).\(mostRecentVersion.minor) available.")
                                        Link("Update", destination: URL(string: "https://github.com/JethroHemmann/QuickLookProtein/releases")!)
                                    }
                                    .font(.callout)
                                } else {
                                    Text("You are on the latest released version.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Text("Tip: click any atom in a preview to see its residue and chain.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)

                        Text("Rendered by 3Dmol.js (Rego & Koes, 2015).")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                        Link("3dmol.csb.pitt.edu",
                             destination: URL(string: "https://3dmol.csb.pitt.edu")!)
                            .font(.caption2)
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

    /// Fifth tile that accepts a dragged file and renders it live with the current
    /// settings — useful for previewing your own structures without round-tripping
    /// through Finder + Quick Look.
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
                                    Text("PDB · CIF · SDF · MOL · MOL2\nXYZ · GRO · CUBE · PDBQT")
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
        panel.allowedFileTypes = Array(supportedExtensions)
        if panel.runModal() == .OK, let url = panel.url {
            acceptCandidateURL(url)
        }
    }

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

// https://stackoverflow.com/questions/60945972/why-does-my-wkwebview-not-show-up-in-a-swiftui-view
//
// Note: a value-type NSViewRepresentable is re-instantiated on every SwiftUI body
// re-render. Storing `let view = WKWebView()` as a struct property allocates a fresh
// WKWebView each time the struct is copied — a real memory leak when the parent view
// updates often (e.g. on `isDropTargeted` hover). Keep no view ownership on the struct;
// let SwiftUI cache the WKWebView via `makeNSView`, and reload only when the rendered
// HTML actually changed (tracked via the coordinator).
struct WebView: NSViewRepresentable {

    var html: String
    var baseUrl: URL

    final class Coordinator {
        var lastLoadedHTML: String = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
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
