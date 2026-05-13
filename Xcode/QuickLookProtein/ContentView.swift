//
//  ContentView.swift
//  QuickLookProtein
//
//  Created by Jethro Hemmann on 15.08.21.
//

import SwiftUI
import WebKit
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
    @ObservedObject private var updater = Updater.shared
    /// File the user has dragged into the "Custom" tile.
    @State private var droppedFile: URL? = nil
    @State private var droppedFileError: String? = nil
    @State private var isDropTargeted: Bool = false

    var body: some View {
        let htmlPath = Bundle.main.path(forResource: "3Dmol_viewer", ofType: "html")!
        let pdbPath  = Bundle.main.path(forResource: "6oc6",          ofType: "pdb")!
        let cifPath  = Bundle.main.path(forResource: "1565673",       ofType: "cif")!
        let sdfPath  = Bundle.main.path(forResource: "PQQ",           ofType: "sdf")!
        let mol2Path = Bundle.main.path(forResource: "caffeine",      ofType: "mol2")!

        let baseUrl = URL(fileURLWithPath: htmlPath)

        let htmlPDB  = previewHTML(htmlPath: htmlPath, filePath: pdbPath,  ext: "pdb")
        let htmlCIF  = previewHTML(htmlPath: htmlPath, filePath: cifPath,  ext: "cif")
        let htmlSDF  = previewHTML(htmlPath: htmlPath, filePath: sdfPath,  ext: "sdf")
        let htmlMOL2 = previewHTML(htmlPath: htmlPath, filePath: mol2Path, ext: "mol2")

        GeometryReader { _ in
            VStack {
                HStack(alignment: .firstTextBaseline) {

                    // MARK: Settings
                    VStack(alignment: .leading) {
                        Text("Settings").font(.title).padding(.bottom, 4)

                        Text("Atom display style").font(.headline).padding(.top, 4)
                        Form {
                            Picker("PDB:",  selection: $userSettings.atomStylePDB) {
                                ForEach(Settings.AtomStyle.allCases) { Text($0.rawValue) }
                            }
                            Picker("CIF:",  selection: $userSettings.atomStyleCIF) {
                                ForEach(Settings.AtomStyle.allCases) { Text($0.rawValue) }
                            }
                            Picker("SDF:",  selection: $userSettings.atomStyleSDF) {
                                ForEach(Settings.AtomStyle.allCases) { Text($0.rawValue) }
                            }
                            Picker("MOL2:", selection: $userSettings.atomStyleMOL2) {
                                ForEach(Settings.AtomStyle.allCases) { Text($0.rawValue) }
                            }
                        }

                        DisclosureGroup("Additional formats (XYZ, MOL, GRO, CUBE)") {
                            Form {
                                Picker("XYZ:",  selection: $userSettings.atomStyleXYZ) {
                                    ForEach(Settings.AtomStyle.allCases) { Text($0.rawValue) }
                                }
                                Picker("MOL:",  selection: $userSettings.atomStyleMOL) {
                                    ForEach(Settings.AtomStyle.allCases) { Text($0.rawValue) }
                                }
                                Picker("GRO:",  selection: $userSettings.atomStyleGRO) {
                                    ForEach(Settings.AtomStyle.allCases) { Text($0.rawValue) }
                                }
                                Picker("CUBE:", selection: $userSettings.atomStyleCUBE) {
                                    ForEach(Settings.AtomStyle.allCases) { Text($0.rawValue) }
                                }
                            }
                        }.padding(.top, 4)

                        Text("Appearance").font(.headline).padding(.top, 12)
                        Form {
                            Picker("Color scheme:", selection: $userSettings.colorScheme) {
                                ForEach(Settings.ColorScheme.allCases) { Text($0.rawValue) }
                            }
                            Picker("Rotation:", selection: $userSettings.rotationSpeed) {
                                ForEach(Settings.RotationSpeed.allCases) { Text($0.rawValue) }
                            }
                            HStack {
                                ColorPicker("Background:", selection: $userSettings.bgColor, supportsOpacity: true)
                                    .help("#" + convertColorToRGB(color: userSettings.bgColor).rgbHex
                                          + ", alpha: " + convertColorToRGB(color: userSettings.bgColor).alpha)
                                Button("Transparent", action: resetColor)
                            }
                        }

                        Text("Rendering options").font(.headline).padding(.top, 12)
                        Form {
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
                    VStack(alignment: .leading) {
                        Text("About").font(.title).padding(.bottom, 4)
                        Text("Originally developed 2021–2022 by Jethro Hemmann.")
                            .font(.callout)
                        Link("Upstream: github.com/JethroHemmann/QuickLookProtein",
                             destination: URL(string: "https://github.com/JethroHemmann/QuickLookProtein")!)
                            .font(.callout)

                        Divider().padding(.vertical, 6)

                        Text("This build").font(.headline)
                        Text("Extended in 2026 by Ario Moniri with multi-format support "
                             + "(MOL2, XYZ, MOL, GRO, CUBE, PDBQT), smart protein-ligand "
                             + "styling, surface rendering, drag-and-drop, Spotlight "
                             + "indexing and per-file Finder thumbnails.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Link("github.com/ArioMoniri/QuickLookProtein",
                             destination: URL(string: "https://github.com/ArioMoniri/QuickLookProtein")!)
                            .font(.callout)

                        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                            HStack(spacing: 8) {
                                Text("Installed version: " + appVersion)
                                if updater.isChecking {
                                    ProgressView().controlSize(.small)
                                }
                                Button("Check for updates") {
                                    updater.check(silent: false)
                                }
                                .controlSize(.small)
                            }
                            .padding(.top, 4)

                            if let release = updater.latestRelease,
                               release.tag != appVersion, release.tag != "v" + appVersion {
                                HStack(spacing: 4) {
                                    Text("Newer release \(release.tag) available.")
                                    Link("Open", destination: release.url)
                                }
                                .font(.callout)
                                .foregroundColor(.accentColor)
                            }
                            if let err = updater.lastError {
                                Text("Update check error: \(err)")
                                    .font(.caption2).foregroundColor(.red)
                            }
                        }

                        Text("Supported formats").font(.headline).padding(.top, 12)
                        Text("PDB · CIF / mmCIF · SDF · MOL · MOL2 · XYZ · GRO · CUBE")
                            .font(.callout)

                        Text("Tip").font(.headline).padding(.top, 12)
                        Text("Click any atom in a preview to see its identity (residue, chain, atom name).")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Credits — 3Dmol.js").font(.title2).padding(.top, 12)
                        Text("Rendering is performed by the 3Dmol.js library by Nicholas Rego and David Koes.")
                            .fixedSize(horizontal: false, vertical: true)
                        Link("https://3dmol.csb.pitt.edu",
                             destination: URL(string: "https://3dmol.csb.pitt.edu")!)
                    }
                    .padding()
                }

                Divider()

                // MARK: Live previews
                HStack {
                    previewTile(html: htmlPDB,  base: baseUrl,
                                title: "PDB",
                                caption: { (Text("XoxF from ") + Text("M. extorquens").italic() + Text(" (6OC6)")) })

                    previewTile(html: htmlCIF,  base: baseUrl,
                                title: "CIF",
                                caption: { Text("Bioinspired Fe complex (1565673)") })

                    previewTile(html: htmlSDF,  base: baseUrl,
                                title: "SDF",
                                caption: { Text("Pyrroloquinoline quinone (CID 1024)") })

                    previewTile(html: htmlMOL2, base: baseUrl,
                                title: "MOL2",
                                caption: { Text("Caffeine") })

                    customDropTile(htmlPath: htmlPath, baseUrl: baseUrl)
                }
            }
        }
    }

    /// Fifth tile that accepts a dragged file and renders it live with the current
    /// settings — useful for previewing your own structures without round-tripping
    /// through Finder + Quick Look.
    @ViewBuilder
    private func customDropTile(htmlPath: String, baseUrl: URL) -> some View {
        VStack {
            ZStack {
                if let droppedFile = droppedFile {
                    WebView(html: previewHTML(htmlPath: htmlPath,
                                              filePath: droppedFile.path,
                                              ext: droppedFile.pathExtension),
                            baseUrl: baseUrl)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .foregroundColor(isDropTargeted ? .accentColor : .secondary)
                        .overlay(
                            VStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 28))
                                Text("Drop a structure file")
                                    .font(.callout)
                                Text("PDB, CIF, SDF, MOL, MOL2, XYZ, GRO, CUBE")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }

            HStack(spacing: 4) {
                Text(droppedFile?.lastPathComponent ?? "Custom").lineLimit(1).truncationMode(.middle)
                if droppedFile != nil {
                    Button(action: { droppedFile = nil; droppedFileError = nil }) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("Clear dropped file")
                }
            }
            if let err = droppedFileError {
                Text(err).font(.caption2).foregroundColor(.red).lineLimit(1)
            } else if droppedFile == nil {
                Text("Drag to preview your own file").font(.caption).padding(.bottom)
            } else {
                Text("Dropped file").font(.caption).padding(.bottom)
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            DispatchQueue.main.async {
                guard let url = url else {
                    self.droppedFileError = "Could not read dropped item"
                    return
                }
                let ext = url.pathExtension.lowercased()
                if !supportedExtensions.contains(ext) {
                    self.droppedFileError = "Unsupported file type: .\(ext)"
                    self.droppedFile = nil
                    return
                }
                // Size-cap the drop path so a 1 GB PDB doesn't hang the UI while it's
                // parsed synchronously inside `prepare3DmolHTML` on the main thread.
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
        VStack {
            WebView(html: html, baseUrl: base)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            Text(title)
            caption().font(.caption).padding(.bottom)
        }
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
