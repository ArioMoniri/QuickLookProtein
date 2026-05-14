//
//  APNGEncoder.swift
//  QLThumbnail
//
//  Stitches a list of same-size PNGs into a single Animated PNG (APNG) file.
//
//  Why custom-encode: AppKit / CoreGraphics have no APNG writer, and pulling in
//  libpng / ImageMagick / a Swift package just to splice chunks is overkill.
//  The format itself is well-specified (https://wiki.mozilla.org/APNG_Specification)
//  and only adds three chunk types on top of PNG: acTL, fcTL, fdAT. We re-use
//  each frame's existing IDAT chunks verbatim, so we don't have to touch zlib.
//
//  Layout we emit:
//      PNG signature
//      IHDR (from frame 0, verbatim — all frames must share dimensions)
//      acTL (animation control)
//      fcTL #0 (must come before the default image's IDAT)
//      IDAT(s) of frame 0
//      For each subsequent frame i ∈ [1, N):
//          fcTL #i
//          fdAT(s) — IDAT bytes prefixed by 4-byte sequence number
//      IEND
//
//  Finder does not animate APNG thumbnails in stock macOS builds; the first
//  frame is what users see. We ship this anyway so users on platforms that DO
//  honour the format (Safari, Preview app in some configurations, third-party
//  viewers) get the rotating render.
//

import Foundation

enum APNGEncoder {

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Encode N same-size PNGs into a single APNG. Returns nil if any frame
    /// can't be parsed (e.g. lacks IHDR / IDAT).
    ///
    /// - Parameters:
    ///   - frames: PNG-encoded frame data (must all share the same IHDR).
    ///   - frameDelayMs: per-frame delay in milliseconds (we encode as N/1000).
    ///   - loop: 0 = loop forever (APNG default), >0 = play `loop` times.
    static func encode(frames: [Data],
                       frameDelayMs: Int = 60,
                       loop: Int = 0) -> Data? {
        guard !frames.isEmpty else { return nil }
        guard let first = parseChunks(frames[0]) else { return nil }
        guard let ihdr = first.first(where: { $0.type == "IHDR" }) else { return nil }
        let firstIDATs = first.filter { $0.type == "IDAT" }
        guard !firstIDATs.isEmpty else { return nil }

        // IHDR data: width (4) + height (4) + bitDepth (1) + colorType (1) + ...
        let width  = readUInt32BE(ihdr.data, offset: 0)
        let height = readUInt32BE(ihdr.data, offset: 4)

        var out = Data(pngSignature)

        // IHDR — pass through verbatim
        appendChunk(&out, type: "IHDR", data: ihdr.data)

        // acTL — 8 bytes: num_frames (4) + num_plays (4)
        var acTL = Data()
        appendUInt32BE(&acTL, UInt32(frames.count))
        appendUInt32BE(&acTL, UInt32(loop))
        appendChunk(&out, type: "acTL", data: acTL)

        var sequence: UInt32 = 0

        // fcTL for frame 0 — must come before the default image's IDAT(s)
        appendChunk(&out, type: "fcTL", data: makeFCTL(
            sequence: sequence,
            width: width, height: height,
            delayMs: frameDelayMs))
        sequence += 1

        // IDATs of frame 0 — pass through verbatim. The default image of an APNG
        // is also the first animation frame (we don't set the no-display bit).
        for chunk in firstIDATs {
            appendChunk(&out, type: "IDAT", data: chunk.data)
        }

        // Subsequent frames: fcTL + fdAT*
        for frame in frames.dropFirst() {
            guard let chunks = parseChunks(frame) else { return nil }
            let idats = chunks.filter { $0.type == "IDAT" }
            guard !idats.isEmpty else { return nil }

            appendChunk(&out, type: "fcTL", data: makeFCTL(
                sequence: sequence,
                width: width, height: height,
                delayMs: frameDelayMs))
            sequence += 1

            for chunk in idats {
                var fdAT = Data()
                appendUInt32BE(&fdAT, sequence)
                fdAT.append(chunk.data)
                appendChunk(&out, type: "fdAT", data: fdAT)
                sequence += 1
            }
        }

        appendChunk(&out, type: "IEND", data: Data())
        return out
    }

    // MARK: - Chunk parsing / writing

    private struct Chunk {
        let type: String
        let data: Data
    }

    /// Walk a PNG buffer, returning each chunk's type + data slice.
    private static func parseChunks(_ png: Data) -> [Chunk]? {
        guard png.count >= 8 else { return nil }
        var i = 8  // skip signature
        var chunks: [Chunk] = []
        while i + 8 <= png.count {
            let length = Int(readUInt32BE(png, offset: i))
            i += 4
            let typeBytes = png.subdata(in: i..<(i + 4))
            guard let type = String(data: typeBytes, encoding: .ascii) else { return nil }
            i += 4
            guard i + length + 4 <= png.count else { return nil }
            let data = png.subdata(in: i..<(i + length))
            i += length
            // 4-byte CRC, we don't validate (each chunk is well-formed because
            // we just generated it ourselves via NSBitmapImageRep).
            i += 4
            chunks.append(Chunk(type: type, data: data))
            if type == "IEND" { break }
        }
        return chunks
    }

    /// Append a length + type + data + CRC32 chunk.
    private static func appendChunk(_ out: inout Data, type: String, data: Data) {
        appendUInt32BE(&out, UInt32(data.count))
        let typeBytes = Array(type.utf8)
        out.append(contentsOf: typeBytes)
        out.append(data)
        var crcInput = Data()
        crcInput.append(contentsOf: typeBytes)
        crcInput.append(data)
        appendUInt32BE(&out, crc32(crcInput))
    }

    /// fcTL data layout per APNG spec (26 bytes):
    ///   sequence (4) + width (4) + height (4) + x_offset (4) + y_offset (4)
    ///   + delay_num (2) + delay_den (2) + dispose_op (1) + blend_op (1)
    private static func makeFCTL(sequence: UInt32,
                                 width: UInt32, height: UInt32,
                                 delayMs: Int) -> Data {
        var d = Data()
        appendUInt32BE(&d, sequence)
        appendUInt32BE(&d, width)
        appendUInt32BE(&d, height)
        appendUInt32BE(&d, 0)
        appendUInt32BE(&d, 0)
        // delay_num / delay_den — we encode as N/1000 (millisecond precision).
        appendUInt16BE(&d, UInt16(min(max(delayMs, 1), 65535)))
        appendUInt16BE(&d, 1000)
        // dispose_op = APNG_DISPOSE_OP_NONE (0): leave the output buffer as-is.
        // Acceptable since every frame writes the whole canvas.
        d.append(0)
        // blend_op = APNG_BLEND_OP_SOURCE (1): overwrite (no alpha blending).
        d.append(1)
        return d
    }

    // MARK: - Byte helpers

    private static func appendUInt32BE(_ out: inout Data, _ v: UInt32) {
        out.append(UInt8((v >> 24) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8(v & 0xFF))
    }

    private static func appendUInt16BE(_ out: inout Data, _ v: UInt16) {
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8(v & 0xFF))
    }

    private static func readUInt32BE(_ d: Data, offset: Int) -> UInt32 {
        return  (UInt32(d[d.startIndex + offset]) << 24) |
                (UInt32(d[d.startIndex + offset + 1]) << 16) |
                (UInt32(d[d.startIndex + offset + 2]) << 8) |
                 UInt32(d[d.startIndex + offset + 3])
    }

    // MARK: - CRC32 (PNG polynomial)

    private static let crc32Table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[n] = c
        }
        return table
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data {
            c = crc32Table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFFFFFF
    }
}
