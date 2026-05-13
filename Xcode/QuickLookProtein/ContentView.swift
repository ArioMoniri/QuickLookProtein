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

        VStack(spacing: 0) {
            // Top — settings + about, scrollable so it never starves the previews.
            // The settings column genuinely doesn't fit in <360 px once all
            // toggles + the "Additional formats" disclosure expand; rather than
            // shoving them off-screen we let the column scroll.
            ScrollView(.vertical, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {

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

                    // MARK: About — kept compact so the live previews below have room
                    VStack(alignment: .leading, spacing: 6) {
                        Text("About").font(.title).padding(.bottom, 2)

                        Text("Originally by Jethro Hemmann (2021–2022).")
                            .font(.callout)
                        Text("Extended by Ariorad Moniri (2026) — multi-format, smart styling, surface, thumbnails, Spotlight, auto-update.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Link("github.com/ArioMoniri/QuickLookProtein",
                             destination: URL(string: "https://github.com/ArioMoniri/QuickLookProtein")!)
                            .font(.callout)

                        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                            HStack(spacing: 8) {
                                Text("Installed version: \(appVersion)")
                                    .font(.callout)
                                Button("Check for updates") { updater.checkForUpdates() }
                                    .controlSize(.small)
                                    .disabled(!updater.canCheck)
                            }
                            .padding(.top, 2)
                        }

                        if !updater.lastCheckStatus.isEmpty {
                            Text(updater.lastCheckStatus)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Text("Tip: click any atom in a preview to see its residue and chain.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)

                        // Quick Look troubleshooting — common after upgrading from
                        // upstream because the old extension's bundle ID differs
                        // and macOS keeps both registered until the old app is
                        // deleted + caches cleared.
                        DisclosureGroup("Quick Look not updating?") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Run this in Terminal to flush macOS's Quick Look caches and re-register the new extension:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack {
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
                                Text("If the wrong preview still appears, delete the previously installed QuickLookProtein.app from /Applications and rebuild.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .font(.caption)
                        .padding(.top, 6)

                        Spacer(minLength: 0)

                        Text("Rendered by 3Dmol.js (Rego & Koes, 2015).")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Link("3dmol.csb.pitt.edu",
                             destination: URL(string: "https://3dmol.csb.pitt.edu")!)
                            .font(.caption2)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(.horizontal, 8)
            }
            .frame(maxHeight: 360)   // hard cap so the previews always get 360+ px

            Divider()

            // MARK: Live previews — WebGL canvases that spin at the user's chosen
            //       rotation speed. Min-height ensures the canvases have enough
            //       pixels to render even on small windows; without this the
            //       molecules don't show even though 3Dmol parses them.
            HStack(spacing: 8) {
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
            .frame(minHeight: 320, maxHeight: .infinity)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
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
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .foregroundColor(isDropTargeted ? .accentColor : .secondary)
                        .overlay(
                            VStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 26))
                                Text("Drop a structure file").font(.callout)
                                Text("PDB · CIF · SDF · MOL · MOL2\nXYZ · GRO · CUBE · PDBQT")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(8)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    Text("Drag to preview your own file")
                } else {
                    Text("Dropped file")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .padding(.bottom, 4)
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
