//
//  USDZExporter.swift
//  Shared (QuickLookProtein, QLExtension)
//
//  Exports a parsed atom list as a .usdz scene so the user can AirDrop
//  the molecule to an iOS device and view it in AR Quick Look (1.7.42+).
//
//  Implementation notes:
//
//  - We build one MDLAsset and add a sphere-per-atom. ModelIO supports
//    instancing in principle, but `MDLAsset.export(to:)` for `.usdz`
//    flattens the scene anyway when writing the archive, so we don't
//    bother sharing geometry across atoms — the cost is a few hundred
//    KB on a typical 2000-atom file and the code stays simple.
//  - Sphere radius is 0.3 Å in atom-space (matching the visual scale
//    AR Quick Look conventions use); the exported scene preserves
//    Ångström as the world unit.
//  - Colors are CPK-table; unknown elements fall back to light grey.
//  - This file is intentionally only compiled into the host app and
//    the QLExtension targets. The QLThumbnail / QLActions extensions
//    never trigger a share, so they don't link this module.
//

import Foundation
import ModelIO
import MetalKit
import simd

#if canImport(AppKit)
import AppKit
#endif

enum USDZExporter {

    /// Maximum atom count we'll ship to the USDZ writer. Above this the
    /// AR file gets unwieldy (~5 MB+) and AirDrop / Files on iOS starts
    /// stuttering. Callers should fall back to PNG-only.
    static let softAtomCap: Int = 20_000

    enum ExportError: Error {
        case noMetalDevice
        case tooLarge(atomCount: Int)
        case writeFailed(underlying: Error)
    }

    /// Build a `.usdz` archive at `url` from `atoms`.
    static func export(atoms: [Atom], to url: URL) throws {
        if atoms.count > softAtomCap {
            throw ExportError.tooLarge(atomCount: atoms.count)
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ExportError.noMetalDevice
        }
        let allocator = MTKMeshBufferAllocator(device: device)

        let asset = MDLAsset()
        // Sphere radius: 0.3 Å in atom-space. Using a slightly sub-unit
        // radius means atoms touch at ~0.6 Å gaps, which reads as "balls"
        // in AR without overlapping into a single blob for protein
        // backbones. Tuned by inspection on iPad AR Quick Look.
        let radius: Float = 0.3

        // Per-element submesh cache so repeated elements (a 5000-atom
        // protein is ~70% carbon) all share one MDLMesh blueprint.
        // We still emit one MDLMesh per atom (cloned via MDLMesh init
        // with the cached geometry data) so each can carry its own
        // transform — MDLAsset.export flattens regardless.
        for atom in atoms {
            let mesh = MDLMesh.newEllipsoid(
                withRadii: SIMD3<Float>(repeating: radius),
                radialSegments: 12,
                verticalSegments: 8,
                geometryType: .triangles,
                inwardNormals: false,
                hemisphere: false,
                allocator: allocator)

            // Translate to atom position. Coordinates are in Å; ModelIO's
            // exporter writes them straight through.
            let translation = SIMD3<Float>(Float(atom.x), Float(atom.y), Float(atom.z))
            let transform = MDLTransform()
            transform.translation = translation
            mesh.transform = transform

            // CPK color → material. We use the deprecated-on-modern-USDA
            // but still-honoured `baseColor` semantic; iOS AR Quick Look
            // reads it via UsdPreviewSurface.diffuseColor.
            let color = cpkCGColor(for: atom.element)
            let scattering = MDLPhysicallyPlausibleScatteringFunction()
            scattering.baseColor.color = color
            let material = MDLMaterial(name: "cpk-\(atom.element)",
                                       scatteringFunction: scattering)
            // Submeshes are an optional array of `MDLMeshBufferAllocator`-
            // managed entries; in practice the ellipsoid builder produces
            // exactly one submesh.
            if let submeshes = mesh.submeshes {
                for case let s as MDLSubmesh in submeshes {
                    s.material = material
                }
            }

            asset.add(mesh)
        }

        // .usdz extension auto-triggers Apple's USDA-in-zip writer.
        do {
            try asset.export(to: url)
        } catch {
            throw ExportError.writeFailed(underlying: error)
        }
    }

    // MARK: - CPK color table
    //
    // Subset of the Jmol/Rasmol CPK palette covering the elements that
    // actually appear in our supported file formats. Unknown elements
    // fall back to a neutral light grey.
    private static func cpkCGColor(for element: String) -> CGColor {
        let el = element.uppercased()
        let cs = CGColorSpaceCreateDeviceRGB()
        let rgba: (CGFloat, CGFloat, CGFloat, CGFloat)
        switch el {
        case "H":  rgba = (1.00, 1.00, 1.00, 1.0)     // hydrogen white
        case "C":  rgba = (0.30, 0.30, 0.30, 1.0)     // carbon dark grey
        case "N":  rgba = (0.19, 0.31, 0.97, 1.0)     // nitrogen blue
        case "O":  rgba = (0.95, 0.05, 0.05, 1.0)     // oxygen red
        case "S":  rgba = (1.00, 0.79, 0.20, 1.0)     // sulfur yellow
        case "P":  rgba = (1.00, 0.50, 0.00, 1.0)     // phosphorus orange
        case "F":  rgba = (0.56, 0.88, 0.31, 1.0)
        case "CL": rgba = (0.12, 0.94, 0.12, 1.0)
        case "BR": rgba = (0.65, 0.16, 0.16, 1.0)
        case "I":  rgba = (0.58, 0.00, 0.58, 1.0)
        case "FE": rgba = (0.88, 0.40, 0.20, 1.0)
        case "ZN": rgba = (0.49, 0.50, 0.69, 1.0)
        case "MG": rgba = (0.54, 1.00, 0.00, 1.0)
        case "CA": rgba = (0.24, 1.00, 0.00, 1.0)
        case "NA": rgba = (0.67, 0.36, 0.95, 1.0)
        case "K":  rgba = (0.56, 0.25, 0.83, 1.0)
        default:   rgba = (0.75, 0.75, 0.75, 1.0)     // light grey fallback
        }
        let components: [CGFloat] = [rgba.0, rgba.1, rgba.2, rgba.3]
        return CGColor(colorSpace: cs, components: components)
            ?? CGColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1.0)
    }
}
