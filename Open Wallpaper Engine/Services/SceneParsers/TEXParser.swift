//
//  TEXParser.swift
//  Open Wallpaper Engine
//
//  Parse Wallpaper Engine TEXV texture container files.
//  Structure: TEXV0005 > TEXI (metadata) > TEXB (image data).
//  Supports embedded JPEG/PNG and uncompressed R8 masks compressed with LZ4.
//

import Cocoa
import Foundation

struct TEXMetadata {
    let format: UInt32
    let width: UInt32
    let height: UInt32
    let textureWidth: UInt32  // power-of-2 padded
    let textureHeight: UInt32
}

class TEXParser {
    private let data: Data

    init(data: Data) {
        self.data = data
    }

    /// Extract the image from this TEX container.
    /// Returns nil if the format is unsupported (e.g. DXT).
    func extractImage(cropVisibleBounds: Bool = true) -> NSImage? {
        let texiMeta = readTEXIMetadata()
        if let image = extractR8Image(metadata: texiMeta) {
            return image
        }

        // Skip compressed GPU formats. R8/RG88 are handled separately above.
        if let meta = texiMeta, [3, 4, 5, 6, 7, 12].contains(meta.format) {
            NSLog("[TEXParser] TEXI format %d (compressed %dx%d), skipping image scan (%d bytes)", meta.format, meta.width, meta.height, data.count)
            return nil
        }

        // Check TEXB format — format 2+ is DXT compressed, no extractable image
        let texbFmt = readTEXBFormat()
        if texbFmt >= 2 {
            NSLog("[TEXParser] TEXB format %d (DXT), skipping image scan (%d bytes)", texbFmt, data.count)
            return nil
        }

        // Find TEXB section which contains the actual image data
        guard let texbRange = findSection("TEXB") else {
            NSLog("[TEXParser] TEXB section not found in %d bytes", data.count)
            return nil
        }

        let texbData = data[texbRange]
        NSLog("[TEXParser] TEXB found: range=%d..%d (%d bytes) fmt=%d", texbRange.lowerBound, texbRange.upperBound, texbData.count, texbFmt)

        // Look for JPEG magic bytes (FFD8) within TEXB
        if let jpegOffset = findJPEGMagic(in: texbData) {
            // Try to find the JPEG end marker (FFD9) to avoid trailing garbage
            let jpegData: Data
            if let endOffset = findJPEGEnd(in: texbData, from: jpegOffset) {
                jpegData = Data(texbData[jpegOffset...endOffset])
            } else {
                jpegData = Data(texbData[jpegOffset...])
            }
            NSLog("[TEXParser] JPEG found at offset %d, size=%d", jpegOffset - texbData.startIndex, jpegData.count)
            if let image = NSImage(data: jpegData) {
                return cropVisibleBounds ? cropToVisibleBounds(image, metadata: texiMeta) : image
            }
            // If trimmed JPEG failed, try with all remaining data
            if let image = NSImage(data: Data(texbData[jpegOffset...])) {
                return cropVisibleBounds ? cropToVisibleBounds(image, metadata: texiMeta) : image
            }
        }

        // Look for PNG magic bytes (89504E47) within TEXB
        if let pngOffset = findPNGMagic(in: texbData) {
            let pngData = Data(texbData[pngOffset...])
            if let image = NSImage(data: pngData) {
                return cropVisibleBounds ? cropToVisibleBounds(image, metadata: texiMeta) : image
            }
        }

        // Fallback: scan entire data for JPEG/PNG (some TEX files have non-standard layout)
        if let jpegOffset = findJPEGMagic(in: data) {
            let jpegData: Data
            if let endOffset = findJPEGEnd(in: data, from: jpegOffset) {
                jpegData = Data(data[jpegOffset...endOffset])
            } else {
                jpegData = Data(data[jpegOffset...])
            }
            if let image = NSImage(data: jpegData) {
                return cropVisibleBounds ? cropToVisibleBounds(image, metadata: texiMeta) : image
            }
        }

        NSLog("[TEXParser] No supported image format found in TEXB (%d bytes, may be DXT)", texbData.count)
        return nil
    }

    /// Extract raw JPEG/PNG data without creating NSImage
    func extractImageData() -> Data? {
        guard let texbRange = findSection("TEXB") else { return nil }
        let texbData = data[texbRange]

        if let jpegOffset = findJPEGMagic(in: texbData) {
            return Data(texbData[jpegOffset...])
        }
        if let pngOffset = findPNGMagic(in: texbData) {
            return Data(texbData[pngOffset...])
        }
        return nil
    }

    // MARK: - Private

    /// Read TEXI metadata section: format, flags, width, height, textureWidth, textureHeight
    private func readTEXIMetadata() -> TEXMetadata? {
        guard let texiMagic = "TEXI".data(using: .ascii) else { return nil }
        var i = data.startIndex
        while i + 4 <= data.endIndex {
            if data[i..<i+4] == texiMagic {
                // Skip past "TEXIxxxx\0" (null-terminated name with version)
                var j = i + 4
                while j < data.endIndex && data[j] != 0 { j += 1 }
                j += 1 // skip null byte
                guard j + 24 <= data.endIndex else { return nil }
                func u32(_ off: Int) -> UInt32 {
                    UInt32(data[j+off]) | (UInt32(data[j+off+1]) << 8)
                    | (UInt32(data[j+off+2]) << 16) | (UInt32(data[j+off+3]) << 24)
                }
                return TEXMetadata(format: u32(0), width: u32(8), height: u32(12),
                                   textureWidth: u32(16), textureHeight: u32(20))
            }
            i += 1
        }
        return nil
    }

    private func cropToVisibleBounds(_ image: NSImage, metadata: TEXMetadata?) -> NSImage {
        guard let metadata,
              metadata.textureWidth > 0, metadata.textureHeight > 0,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }

        let visibleWidth = min(Int(metadata.textureWidth), cgImage.width)
        let visibleHeight = min(Int(metadata.textureHeight), cgImage.height)
        guard visibleWidth > 0, visibleHeight > 0,
              visibleWidth != cgImage.width || visibleHeight != cgImage.height else {
            return image
        }

        guard let cropped = cgImage.cropping(to: CGRect(x: 0, y: 0, width: visibleWidth, height: visibleHeight)) else {
            return image
        }

        return NSImage(cgImage: cropped, size: CGSize(width: visibleWidth, height: visibleHeight))
    }

    /// Read the TEXB format field (first uint32 after the null-terminated section name).
    /// Format 1 = image-extractable, Format 2 = DXT5, etc.
    private func readTEXBFormat() -> Int {
        guard let texbMagic = "TEXB".data(using: .ascii) else { return -1 }
        var i = data.startIndex
        while i + 4 <= data.endIndex {
            if data[i..<i+4] == texbMagic {
                // Skip past "TEXBxxxx\0" (null-terminated name with version)
                var j = i + 4
                while j < data.endIndex && data[j] != 0 { j += 1 }
                j += 1 // skip null byte
                guard j + 4 <= data.endIndex else { return -1 }
                return Int(UInt32(data[j])
                    | (UInt32(data[j+1]) << 8)
                    | (UInt32(data[j+2]) << 16)
                    | (UInt32(data[j+3]) << 24))
            }
            i += 1
        }
        return -1
    }

    private func extractR8Image(metadata: TEXMetadata?) -> NSImage? {
        guard let metadata, metadata.format == 9 else { return nil }
        guard let payloadOffset = findVersionedSectionPayload("TEXB") else { return nil }

        func u32(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        }

        let width = Int(u32(payloadOffset + 12) ?? metadata.width)
        let height = Int(u32(payloadOffset + 16) ?? metadata.height)
        let outputByteCount = Int(u32(payloadOffset + 24) ?? UInt32(width * height))
        let compressedByteCount = Int(u32(payloadOffset + 28) ?? 0)
        let dataOffset = payloadOffset + 32
        let pixelByteCount = width * height

        guard width > 0, height > 0,
              outputByteCount >= pixelByteCount,
              compressedByteCount > 0,
              dataOffset + compressedByteCount <= data.count else {
            return nil
        }

        let compressed = [UInt8](data[dataOffset..<dataOffset + compressedByteCount])
        let decoded: [UInt8]
        if compressedByteCount == outputByteCount {
            decoded = compressed
        } else if let decompressed = decodeLZ4Block(compressed, outputSize: outputByteCount) {
            decoded = decompressed
        } else {
            return nil
        }

        guard decoded.count >= pixelByteCount else { return nil }
        let pixels = Data(decoded[0..<pixelByteCount])
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return nil
        }

        return NSImage(cgImage: image, size: CGSize(width: width, height: height))
    }

    private func findVersionedSectionPayload(_ name: String) -> Int? {
        guard let nameData = name.data(using: .ascii) else { return nil }
        let marker = [UInt8](nameData)
        var index = 0
        while index + marker.count <= data.count {
            var matches = true
            for markerIndex in marker.indices where data[index + markerIndex] != marker[markerIndex] {
                matches = false
                break
            }
            if matches {
                var payload = index + marker.count
                while payload < data.count && data[payload] != 0 {
                    payload += 1
                }
                guard payload < data.count else { return nil }
                return payload + 1
            }
            index += 1
        }
        return nil
    }

    private func decodeLZ4Block(_ input: [UInt8], outputSize: Int) -> [UInt8]? {
        guard outputSize > 0 else { return [] }
        var output = Array(repeating: UInt8(0), count: outputSize)
        var inputIndex = 0
        var outputIndex = 0

        func readLength(_ base: Int) -> Int? {
            var length = base
            if base == 15 {
                while inputIndex < input.count {
                    let byte = Int(input[inputIndex])
                    inputIndex += 1
                    length += byte
                    if byte != 255 { break }
                }
            }
            return length
        }

        while inputIndex < input.count && outputIndex < outputSize {
            let token = Int(input[inputIndex])
            inputIndex += 1

            guard let literalLength = readLength(token >> 4),
                  inputIndex + literalLength <= input.count,
                  outputIndex + literalLength <= outputSize else {
                return nil
            }

            if literalLength > 0 {
                output[outputIndex..<outputIndex + literalLength] = input[inputIndex..<inputIndex + literalLength]
                inputIndex += literalLength
                outputIndex += literalLength
            }

            if inputIndex >= input.count { break }
            guard inputIndex + 2 <= input.count else { return nil }
            let offset = Int(input[inputIndex]) | (Int(input[inputIndex + 1]) << 8)
            inputIndex += 2
            guard offset > 0, offset <= outputIndex else { return nil }

            guard let matchBaseLength = readLength(token & 0x0f) else { return nil }
            let matchLength = matchBaseLength + 4
            guard outputIndex + matchLength <= outputSize else { return nil }

            for _ in 0..<matchLength {
                output[outputIndex] = output[outputIndex - offset]
                outputIndex += 1
            }
        }

        return outputIndex == outputSize ? output : nil
    }

    /// Find a named section (e.g. "TEXI", "TEXB") in the TEX data
    private func findSection(_ name: String) -> Range<Data.Index>? {
        guard let nameData = name.data(using: .ascii) else { return nil }
        let nameLen = nameData.count

        var i = data.startIndex
        while i + nameLen + 4 <= data.endIndex {
            if data[i..<i+nameLen] == nameData {
                // Section found — next 4 bytes after name are section length
                let lenStart = i + nameLen
                guard lenStart + 4 <= data.endIndex else { return nil }
                let sectionLen = UInt32(data[lenStart])
                    | (UInt32(data[lenStart+1]) << 8)
                    | (UInt32(data[lenStart+2]) << 16)
                    | (UInt32(data[lenStart+3]) << 24)
                let contentStart = lenStart + 4
                let contentEnd = contentStart + Int(sectionLen)
                guard contentEnd <= data.endIndex else {
                    return contentStart..<data.endIndex
                }
                return contentStart..<contentEnd
            }
            i += 1
        }
        return nil
    }

    /// Find JPEG end marker (FFD9) scanning from a given start position
    private func findJPEGEnd(in slice: Data, from start: Data.Index) -> Data.Index? {
        var i = start
        while i + 1 < slice.endIndex {
            if slice[i] == 0xFF && slice[i+1] == 0xD9 {
                return i + 1  // Include the D9 byte
            }
            i += 1
        }
        return nil
    }

    private func findJPEGMagic(in slice: Data) -> Data.Index? {
        var i = slice.startIndex
        while i + 1 < slice.endIndex {
            if slice[i] == 0xFF && slice[i+1] == 0xD8 {
                return i
            }
            i += 1
        }
        return nil
    }

    private func findPNGMagic(in slice: Data) -> Data.Index? {
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        var i = slice.startIndex
        while i + 3 < slice.endIndex {
            if slice[i] == pngMagic[0] && slice[i+1] == pngMagic[1]
                && slice[i+2] == pngMagic[2] && slice[i+3] == pngMagic[3] {
                return i
            }
            i += 1
        }
        return nil
    }
}
