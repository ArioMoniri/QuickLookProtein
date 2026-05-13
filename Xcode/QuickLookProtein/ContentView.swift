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
                        VStack(spacing: 4) {
                            styleMenuRow(label: "PDB",   binding: $userSettings.atomStylePDB)
                            styleMenuRow(label: "CIF",   binding: $userSettings.atomStyleCIF)
                            styleMenuRow(label: "SDF",   binding: $userSettings.atomStyleSDF)
                            styleMenuRow(label: "MOL",   binding: $userSettings.atomStyleMOL)
                            styleMenuRow(label: "MOL2",  binding: $userSettings.atomStyleMOL2)
                            styleMenuRow(label: "XYZ",   binding: $userSettings.atomStyleXYZ)
                            styleMenuRow(label: "GRO",   binding: $userSettings.atomStyleGRO)
                            styleMenuRow(label: "CUBE",  binding: $userSettings.atomStyleCUBE)
                        }
                        .frame(maxWidth: 320)

                        Text("Appearance").font(.headline).padding(.top, 6)
                        VStack(spacing: 4) {
                            schemeMenuRow(label: "Color scheme", binding: $userSettings.colorScheme)
                            rotationMenuRow(label: "Rotation",   binding: $userSettings.rotationSpeed)
                            HStack {
                                ColorPicker("Background:", selection: $userSettings.bgColor, supportsOpacity: true)
                                    .help("#" + convertColorToRGB(color: userSettings.bgColor).rgbHex
                                          + ", alpha: " + convertColorToRGB(color: userSettings.bgColor).alpha)
                                Button("Transparent", action: resetColor)
                            }
                        }
                        .frame(maxWidth: 320)

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

                // MARK: Live previews — WebGL canvases that rotate at the user's
                //       chosen speed. Aspect-ratio constraint keeps each tile a
                //       roughly 1:1 square as the window grows or shrinks, and
                //       a 180 px floor means they never disappear in narrow
                //       windows. They scale up freely when the window grows.
                HStack(spacing: 10) {
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
                .frame(minHeight: 180, idealHeight: 280)
                .aspectRatio(4.2, contentMode: .fit)
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Menu rows (entire row clickable, including the label)

    private func styleMenuRow(label: String,
                              binding: Binding<Settings.AtomStyle>) -> some View {
        menuRow(label: label, currentValue: binding.wrappedValue.rawValue) {
            ForEach(Settings.AtomStyle.allCases) { style in
                Button {
                    binding.wrappedValue = style
                } label: {
                    HStack {
                        Text(style.rawValue)
                        if binding.wrappedValue == style {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }

    private func schemeMenuRow(label: String,
                               binding: Binding<Settings.ColorScheme>) -> some View {
        menuRow(label: label, currentValue: binding.wrappedValue.rawValue) {
            ForEach(Settings.ColorScheme.allCases) { scheme in
                Button {
                    binding.wrappedValue = scheme
                } label: {
                    HStack {
                        Text(scheme.rawValue)
                        if binding.wrappedValue == scheme {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }

    private func rotationMenuRow(label: String,
                                 binding: Binding<Settings.RotationSpeed>) -> some View {
        menuRow(label: label, currentValue: binding.wrappedValue.rawValue) {
            ForEach(Settings.RotationSpeed.allCases) { speed in
                Button {
                    binding.wrappedValue = speed
                } label: {
                    HStack {
                        Text(speed.rawValue)
                        if binding.wrappedValue == speed {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }

    /// Shared row layout used by all three menu helpers. The whole row — label
    /// text included — is clickable; clicking anywhere opens the dropdown.
    @ViewBuilder
    private func menuRow<Content: View>(label: String,
                                        currentValue: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 8) {
                Text("\(label):")
                    .frame(width: 100, alignment: .leading)
                    .foregroundColor(.primary)
                Spacer()
                Text(currentValue)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
            .contentShape(Rectangle())   // makes the whole row hit-test
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
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
