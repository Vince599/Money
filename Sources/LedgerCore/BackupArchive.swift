import Foundation

/// The deliberately small ZIP profile used for Ledger CSV backups.
///
/// PKWARE APPNOTE 6.3.10, sections 4.3.7, 4.3.12 and 4.3.16:
/// https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
/// Writes deterministic, unencrypted, stored (method 0) entries. This is not a
/// general ZIP extractor: recompression, ZIP64, descriptors, extra fields,
/// comments, split archives and non-regular files are unsupported. CRC detects
/// accidental damage; it does not authenticate a backup or replace CSV validation.
public enum BackupArchive {
    public enum ArchiveError: Error, Equatable, Sendable {
        case invalidArchive(String)
        case unsupportedFeature(String)
        case invalidFileName(String)
        case duplicateFileName(String)
        case invalidUTF8(String)
        case checksumMismatch(String)
        case limitExceeded(String)
    }

    public static let maximumFileCount = 64
    public static let maximumFileBytes = 32 * 1024 * 1024
    public static let maximumTotalBytes = 64 * 1024 * 1024
    public static let maximumNameBytes = 255
    private static let maximumArchiveBytes = maximumTotalBytes
        + maximumFileCount * (30 + 46 + 2 * maximumNameBytes) + 22
    private static let utf8Flag: UInt16 = 0x0800

    /// Only root-level, UTF-8 CSV files are accepted. Empty files/archives are
    /// valid containers; whether a complete backup is present is a higher layer's job.
    public static func encode(_ files: [String: Data]) throws -> Data {
        guard files.count <= maximumFileCount else { throw ArchiveError.limitExceeded("file count") }
        var names = Set<String>()
        var total = 0
        // Validate the complete input before allocating the output archive.
        for (name, payload) in files {
            try validateName(name, seen: &names)
            try addSize(payload.count, total: &total)
            guard String(data: payload, encoding: .utf8) != nil else { throw ArchiveError.invalidUTF8(name) }
        }
        let sortedNames = files.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var writer = Writer(capacity: total + files.count * (76 + 2 * maximumNameBytes) + 22)
        var entries: [Entry] = []
        for name in sortedNames {
            // Each key came from this immutable dictionary.
            guard let payload = files[name] else { throw ArchiveError.invalidArchive("missing input") }
            let encodedName = Data(name.utf8)
            let entry = Entry(name: name, nameBytes: encodedName, version: 20, flags: utf8Flag,
                              time: 0, date: 33, crc: crc32(payload), size: payload.count,
                              localOffset: writer.data.count)
            entries.append(entry)
            writer.u32(0x04034b50)
            writer.u16(entry.version); writer.u16(entry.flags); writer.u16(0)
            writer.u16(entry.time); writer.u16(entry.date); writer.u32(entry.crc)
            writer.u32(UInt32(entry.size)); writer.u32(UInt32(entry.size))
            writer.u16(UInt16(encodedName.count)); writer.u16(0)
            writer.data.append(encodedName); writer.data.append(payload)
        }
        let directoryOffset = writer.data.count
        for entry in entries {
            writer.u32(0x02014b50)
            writer.u16(0x0314) // Unix creator, ZIP specification 2.0.
            writer.u16(entry.version); writer.u16(entry.flags); writer.u16(0)
            writer.u16(entry.time); writer.u16(entry.date); writer.u32(entry.crc)
            writer.u32(UInt32(entry.size)); writer.u32(UInt32(entry.size))
            writer.u16(UInt16(entry.nameBytes.count)); writer.u16(0); writer.u16(0)
            writer.u16(0); writer.u16(0)
            writer.u32(0o100600 << 16) // Ordinary owner-readable/writable file.
            writer.u32(UInt32(entry.localOffset)); writer.data.append(entry.nameBytes)
        }
        let directorySize = writer.data.count - directoryOffset
        writer.u32(0x06054b50); writer.u16(0); writer.u16(0)
        writer.u16(UInt16(entries.count)); writer.u16(UInt16(entries.count))
        writer.u32(UInt32(directorySize)); writer.u32(UInt32(directoryOffset)); writer.u16(0)
        return writer.data
    }

    /// Returns all files only after structural, limit, UTF-8 and CRC checks pass.
    /// No paths are created and no partially decoded files escape on failure.
    public static func decode(_ data: Data) throws -> [String: Data] {
        guard data.count <= maximumArchiveBytes else { throw ArchiveError.limitExceeded("archive bytes") }
        guard data.count >= 22 else { throw ArchiveError.invalidArchive("truncated end record") }
        let reader = Reader(data: data)
        let end = data.count - 22
        guard try reader.u32(end) == 0x06054b50 else {
            throw ArchiveError.invalidArchive("missing end record, comment or trailing bytes")
        }
        guard try reader.u16(end + 20) == 0 else { throw ArchiveError.unsupportedFeature("archive comment") }
        guard try reader.u16(end + 4) == 0, try reader.u16(end + 6) == 0 else {
            throw ArchiveError.unsupportedFeature("split archive")
        }
        let count = Int(try reader.u16(end + 10))
        let diskCount = Int(try reader.u16(end + 8))
        let rawDirectorySize = try reader.u32(end + 12)
        let rawDirectoryOffset = try reader.u32(end + 16)
        guard count != 0xffff, diskCount != 0xffff,
              rawDirectorySize != .max, rawDirectoryOffset != .max else {
            throw ArchiveError.unsupportedFeature("ZIP64")
        }
        guard count == diskCount else { throw ArchiveError.invalidArchive("entry count mismatch") }
        guard count <= maximumFileCount else { throw ArchiveError.limitExceeded("file count") }
        let directoryOffset = Int(rawDirectoryOffset)
        let directorySize = Int(rawDirectorySize)
        // Subtraction avoids adding untrusted offsets/lengths before checking them.
        guard directoryOffset <= end, directorySize == end - directoryOffset else {
            throw ArchiveError.invalidArchive("central directory extent")
        }
        var cursor = directoryOffset
        var entries: [Entry] = []
        var names = Set<String>()
        var total = 0
        for _ in 0..<count {
            try reader.require(46, at: cursor, before: end)
            guard try reader.u32(cursor) == 0x02014b50 else { throw ArchiveError.invalidArchive("central signature") }
            let creator = try reader.u16(cursor + 4)
            let version = try reader.u16(cursor + 6)
            let flags = try reader.u16(cursor + 8)
            try validateFeatures(version: version, flags: flags, method: reader.u16(cursor + 10))
            let packed = try reader.u32(cursor + 20)
            let unpacked = try reader.u32(cursor + 24)
            let rawOffset = try reader.u32(cursor + 42)
            guard packed != .max, unpacked != .max, rawOffset != .max else {
                throw ArchiveError.unsupportedFeature("ZIP64")
            }
            guard packed == unpacked else { throw ArchiveError.invalidArchive("stored size mismatch") }
            try addSize(Int(unpacked), total: &total)
            let nameLength = Int(try reader.u16(cursor + 28))
            guard try reader.u16(cursor + 30) == 0 else { throw ArchiveError.unsupportedFeature("extra fields, including ZIP64") }
            guard try reader.u16(cursor + 32) == 0 else { throw ArchiveError.unsupportedFeature("entry comment") }
            guard try reader.u16(cursor + 34) == 0 else { throw ArchiveError.unsupportedFeature("split archive") }
            try validateAttributes(creator: creator, internalAttributes: reader.u16(cursor + 36),
                                   externalAttributes: reader.u32(cursor + 38))
            guard nameLength > 0, nameLength <= maximumNameBytes else { throw ArchiveError.limitExceeded("name bytes") }
            try reader.require(nameLength, at: cursor + 46, before: end)
            let nameBytes = try reader.bytes(at: cursor + 46, count: nameLength)
            guard let name = String(data: nameBytes, encoding: .utf8) else { throw ArchiveError.invalidUTF8("file name") }
            // ASCII has the same bytes in legacy ZIP encodings. Non-ASCII names
            // need the UTF-8 flag, otherwise their interpretation is ambiguous.
            guard flags & utf8Flag != 0 || nameBytes.allSatisfy({ $0 < 128 }) else {
                throw ArchiveError.unsupportedFeature("non-ASCII name without UTF-8 flag")
            }
            try validateName(name, seen: &names)
            entries.append(Entry(name: name, nameBytes: nameBytes, version: version, flags: flags,
                                 time: try reader.u16(cursor + 12), date: try reader.u16(cursor + 14),
                                 crc: try reader.u32(cursor + 16), size: Int(unpacked), localOffset: Int(rawOffset)))
            cursor += 46 + nameLength
        }
        guard cursor == end else { throw ArchiveError.invalidArchive("unlisted central records") }

        var nextOffset = 0
        var output: [String: Data] = [:]
        // The central directory may list entries in a different order. Local
        // records must nevertheless cover the entire data region exactly once.
        for entry in entries.sorted(by: { $0.localOffset < $1.localOffset }) {
            guard entry.localOffset == nextOffset else { throw ArchiveError.invalidArchive("overlap, gap or hidden local entry") }
            let local = entry.localOffset
            try reader.require(30, at: local, before: directoryOffset)
            guard try reader.u32(local) == 0x04034b50 else { throw ArchiveError.invalidArchive("local signature") }
            let localVersion = try reader.u16(local + 4)
            let localFlags = try reader.u16(local + 6)
            try validateFeatures(version: localVersion, flags: localFlags, method: reader.u16(local + 8))
            guard try reader.u16(local + 28) == 0 else { throw ArchiveError.unsupportedFeature("local extra fields, including ZIP64") }
            guard localVersion == entry.version, localFlags == entry.flags,
                  try reader.u16(local + 10) == entry.time, try reader.u16(local + 12) == entry.date,
                  try reader.u32(local + 14) == entry.crc,
                  try reader.u32(local + 18) == UInt32(entry.size), try reader.u32(local + 22) == UInt32(entry.size),
                  try reader.u16(local + 26) == UInt16(entry.nameBytes.count) else {
                throw ArchiveError.invalidArchive("local/central metadata mismatch")
            }
            let payloadOffset = local + 30 + entry.nameBytes.count
            try reader.require(entry.nameBytes.count, at: local + 30, before: directoryOffset)
            guard try reader.bytes(at: local + 30, count: entry.nameBytes.count) == entry.nameBytes else {
                throw ArchiveError.invalidArchive("local/central name mismatch")
            }
            try reader.require(entry.size, at: payloadOffset, before: directoryOffset)
            let payload = try reader.bytes(at: payloadOffset, count: entry.size)
            guard crc32(payload) == entry.crc else { throw ArchiveError.checksumMismatch(entry.name) }
            guard String(data: payload, encoding: .utf8) != nil else { throw ArchiveError.invalidUTF8(entry.name) }
            output[entry.name] = payload
            nextOffset = payloadOffset + entry.size
        }
        guard nextOffset == directoryOffset else { throw ArchiveError.invalidArchive("hidden local data") }
        return output
    }

    private static func addSize(_ size: Int, total: inout Int) throws {
        guard size <= maximumFileBytes else { throw ArchiveError.limitExceeded("single CSV bytes") }
        guard size <= maximumTotalBytes - total else { throw ArchiveError.limitExceeded("total CSV bytes") }
        total += size
    }

    private static func validateName(_ name: String, seen: inout Set<String>) throws {
        guard name.utf8.count <= maximumNameBytes else { throw ArchiveError.limitExceeded("name bytes") }
        let forbidden = CharacterSet(charactersIn: "/\\:<>\"|?*").union(.controlCharacters)
        guard name.count > 4, name.hasSuffix(".csv"), !name.hasPrefix("."),
              name.rangeOfCharacter(from: forbidden) == nil,
              name.trimmingCharacters(in: .whitespacesAndNewlines) == name else {
            throw ArchiveError.invalidFileName(name)
        }
        let firstComponent = String(name.prefix { $0 != "." }).uppercased()
        let reserved = ["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
        guard !reserved.contains(firstComponent) else { throw ArchiveError.invalidFileName(name) }
        let folded = name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive,
                                                                       locale: Locale(identifier: "en_US_POSIX"))
        guard seen.insert(folded).inserted else { throw ArchiveError.duplicateFileName(name) }
    }

    private static func validateFeatures(version: UInt16, flags: UInt16, method: UInt16) throws {
        guard method == 0 else { throw ArchiveError.unsupportedFeature("compression method \(method); only stored is supported") }
        guard flags & 0x0041 == 0 else { throw ArchiveError.unsupportedFeature("encryption") }
        guard flags & 0x0008 == 0 else { throw ArchiveError.unsupportedFeature("data descriptor") }
        guard flags & ~utf8Flag == 0 else { throw ArchiveError.unsupportedFeature("general-purpose flags") }
        guard (10...20).contains(version) else { throw ArchiveError.unsupportedFeature("ZIP version \(version), including ZIP64") }
    }

    private static func validateAttributes(creator: UInt16, internalAttributes: UInt16,
                                           externalAttributes: UInt32) throws {
        guard [0, 3, 10, 19].contains(creator >> 8) else { throw ArchiveError.unsupportedFeature("creator attributes") }
        guard internalAttributes & ~UInt16(1) == 0 else { throw ArchiveError.unsupportedFeature("internal attributes") }
        // DOS hidden/system/volume/directory bits and Unix non-regular file types
        // cannot turn a root CSV into a hidden file, symlink or special device.
        let fileType = (externalAttributes >> 16) & 0xf000
        guard externalAttributes & 0x1e == 0, fileType == 0 || fileType == 0x8000 else {
            throw ArchiveError.unsupportedFeature("hidden, directory, symlink or special entry")
        }
    }

    private struct Entry {
        let name: String
        let nameBytes: Data
        let version: UInt16
        let flags: UInt16
        let time: UInt16
        let date: UInt16
        let crc: UInt32
        let size: Int
        let localOffset: Int
    }

    private struct Reader {
        let data: Data
        func require(_ count: Int, at offset: Int, before end: Int? = nil) throws {
            let boundary = end ?? data.count
            guard offset >= 0, count >= 0, boundary <= data.count,
                  offset <= boundary, count <= boundary - offset else {
                throw ArchiveError.invalidArchive("truncated or out-of-range record")
            }
        }
        func u16(_ offset: Int) throws -> UInt16 {
            try require(2, at: offset)
            let index = data.startIndex + offset
            return UInt16(data[index]) | UInt16(data[index + 1]) << 8
        }
        func u32(_ offset: Int) throws -> UInt32 {
            try require(4, at: offset)
            let index = data.startIndex + offset
            return UInt32(data[index]) | UInt32(data[index + 1]) << 8
                | UInt32(data[index + 2]) << 16 | UInt32(data[index + 3]) << 24
        }
        func bytes(at offset: Int, count: Int) throws -> Data {
            try require(count, at: offset)
            return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
        }
    }

    private struct Writer {
        var data = Data()
        init(capacity: Int) { data.reserveCapacity(capacity) }
        mutating func u16(_ value: UInt16) {
            data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        mutating func u32(_ value: UInt32) {
            data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value >> 16)); data.append(UInt8(truncatingIfNeeded: value >> 24))
        }
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0xedb88320 }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer in
            var crc: UInt32 = .max
            for byte in buffer.bindMemory(to: UInt8.self) { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xff)] }
            return crc ^ .max
        }
    }
}
