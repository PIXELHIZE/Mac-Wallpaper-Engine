//
//  PKGParser.swift
//  Open Wallpaper Engine
//
//  Parse Wallpaper Engine PKGV archive files.
//  Format: length-prefixed "PKGVxxxx" header, entry count,
//  then per entry: length-prefixed path + offset + length.
//  File data follows contiguously after the header table.
//

import Foundation

struct PKGEntry {
    let path: String
    let offset: UInt32
    let length: UInt32
}

class PKGParser {
    private let data: Data
    private let entries: [PKGEntry]
    private let dataBaseOffset: Int

    init(data: Data) throws {
        self.data = data

        var cursor = 0

        func readUInt32() throws -> UInt32 {
            guard cursor + 4 <= data.count else {
                throw PKGError.unexpectedEndOfFile
            }
            let value = UInt32(data[cursor])
                | (UInt32(data[cursor + 1]) << 8)
                | (UInt32(data[cursor + 2]) << 16)
                | (UInt32(data[cursor + 3]) << 24)
            cursor += 4
            return value
        }

        func readString(length: Int) throws -> String {
            guard length >= 0, cursor + length <= data.count else {
                throw PKGError.unexpectedEndOfFile
            }
            let slice = data.subdata(in: cursor..<cursor + length)
            cursor += length
            return String(data: slice, encoding: .utf8)
                ?? String(data: slice, encoding: .isoLatin1)
                ?? ""
        }

        // Read header string (e.g. "PKGV0013")
        let headerLen = try readUInt32()
        guard headerLen < 100 else { throw PKGError.invalidMagic("(header too long: \(headerLen))") }
        let header = try readString(length: Int(headerLen))
        guard header.hasPrefix("PKGV") else {
            throw PKGError.invalidMagic(header)
        }

        // Read entry count
        let entryCount = try readUInt32()
        guard entryCount < 100_000 else { throw PKGError.unexpectedEndOfFile }

        // Read file table
        var parsedEntries: [PKGEntry] = []
        parsedEntries.reserveCapacity(Int(entryCount))
        for _ in 0..<entryCount {
            let pathLen = try readUInt32()
            guard pathLen < 10_000 else { throw PKGError.unexpectedEndOfFile }
            let path = try readString(length: Int(pathLen))
            let offset = try readUInt32()
            let length = try readUInt32()
            parsedEntries.append(PKGEntry(path: path, offset: offset, length: length))
        }

        self.entries = parsedEntries
        self.dataBaseOffset = cursor
    }

    convenience init(url: URL) throws {
        let data = try Data(contentsOf: url)
        try self.init(data: data)
    }

    var fileList: [String] {
        entries.map(\.path)
    }

    func extractFile(named name: String) -> Data? {
        guard let entry = entries.first(where: { $0.path == name }) else {
            return nil
        }
        let start = dataBaseOffset + Int(entry.offset)
        let end = start + Int(entry.length)
        guard end <= data.count else { return nil }
        return data[start..<end]
    }

    func extractJSON<T: Decodable>(named name: String, as type: T.Type) throws -> T? {
        guard let fileData = extractFile(named: name) else { return nil }
        return try JSONDecoder().decode(type, from: fileData)
    }
}

enum PKGError: Error, LocalizedError {
    case invalidMagic(String)
    case unexpectedEndOfFile

    var errorDescription: String? {
        switch self {
        case .invalidMagic(let got):
            return "Invalid PKG header: expected PKGV*, got '\(got)'"
        case .unexpectedEndOfFile:
            return "Unexpected end of PKG file"
        }
    }
}
