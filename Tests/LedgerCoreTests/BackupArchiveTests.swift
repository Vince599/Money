import Foundation
import Testing
@testable import LedgerCore

@Suite("LedgerCoreTests stored ZIP backup", .serialized)
struct BackupArchiveTests {
    // Generated independently with CPython 3.10 zipfile.ZipFile(...,
    // compression=ZIP_STORED, allowZip64=False). ZipInfo dates are 1980-01-01,
    // create_system=3, external_attr=0o100600 << 16. ASCII names use flag 0;
    // the Chinese name uses bit 11. No production writer generated this fixture.
    private let pythonFixture = Data(base64Encoded:
        "UEsDBBQAAAAAAAAAIQAmOfTLCQAAAAkAAAAFAAAAYS5jc3YxMjM0NTY3ODlQSwMEFAAAAAAAAAAhAAAAAAAAAAAAAAAAAAkAAABlbXB0eS5jc3ZQSwMEFAAACAAAAAAhAObFmm4QAAAAEAAAAAoAAADotKbmnKwuY3N2eCx5CuS6uuawkeW4gSwxClBLAQIUAxQAAAAAAAAAIQAmOfTLCQAAAAkAAAAFAAAAAAAAAAAAAACAgQAAAABhLmNzdlBLAQIUAxQAAAAAAAAAIQAAAAAAAAAAAAAAAAAJAAAAAAAAAAAAAACAgSwAAABlbXB0eS5jc3ZQSwECFAMUAAAIAAAAACEA5sWabhAAAAAQAAAACgAAAAAAAAAAAAAAgIFTAAAA6LSm5pysLmNzdlBLBQYAAAAAAwADAKIAAACLAAAAAAA=")!

    @Test func readsIndependentPythonStoredFixture() throws {
        let files = try BackupArchive.decode(pythonFixture)
        #expect(files == ["a.csv": Data("123456789".utf8), "empty.csv": Data(),
                          "账本.csv": Data("x,y\n人民币,1\n".utf8)])
        // CRC-32/ISO-HDLC's standard check vector, independently confirmed by
        // Python zlib.crc32(b"123456789"). This guards against matching bad CRCs
        // in a writer/reader pair that only tests its own output.
        let encoded = try BackupArchive.encode(["check.csv": Data("123456789".utf8)])
        #expect(u32(encoded, 14) == 0xcbf43926)
        #expect(u32(encoded, centralOffset(encoded) + 16) == 0xcbf43926)
    }

    @Test func deterministicEncodingAndEmptyFiles() throws {
        let first = ["z.csv": Data(), "a.csv": Data("id,note\n1,\"a,b\"\n".utf8), "账本.csv": Data("值\n".utf8)]
        var second: [String: Data] = [:]
        second["账本.csv"] = first["账本.csv"]; second["z.csv"] = first["z.csv"]; second["a.csv"] = first["a.csv"]
        let encoded = try BackupArchive.encode(first)
        #expect(try encoded == BackupArchive.encode(second))
        #expect(try BackupArchive.decode(encoded) == first)
        #expect(u16(encoded, 6) == 0x0800)
        #expect(String(data: encoded.subdata(in: 30..<35), encoding: .utf8) == "a.csv")
        let empty = try BackupArchive.encode([:])
        #expect(empty.count == 22)
        #expect(try BackupArchive.decode(empty).isEmpty)
    }

    @Test func acceptsDataWithNonzeroStartIndex() throws {
        var prefixed = Data([0xff, 0xfe, 0xfd])
        prefixed.append(pythonFixture)
        let slice = prefixed.dropFirst(3)
        #expect(slice.startIndex == 3)
        #expect(try BackupArchive.decode(slice)["a.csv"] == Data("123456789".utf8))
    }

    @Test(arguments: ["../a.csv", "/a.csv", "a/b.csv", "a\\b.csv", "C:a.csv", "C:\\a.csv",
                      ".hidden.csv", "a.csv/", "a.txt", "a.csv ", " a.csv", "a\u{0}.csv",
                      "a\n.csv", "a:stream.csv", "CON.csv", "LPT1.csv", "a?.csv", ".csv"])
    func rejectsUnsafeNamesOnEncode(_ name: String) {
        #expect(throws: (any Error).self) { try BackupArchive.encode([name: Data()]) }
    }

    @Test func rejectsCaseConflictsAndUTF8OnEncode() {
        #expect(throws: (any Error).self) { try BackupArchive.encode(["A.csv": Data(), "a.csv": Data()]) }
        #expect(throws: (any Error).self) { try BackupArchive.encode(["a.csv": Data([0xff, 0xfe])]) }
        #expect(throws: (any Error).self) { try BackupArchive.encode([String(repeating: "x", count: 252) + ".csv": Data()]) }
    }

    @Test(arguments: ["..csv", "/.csv", "\\.csv", ":.csv"])
    func rejectsNamesFromExternalArchive(_ name: String) {
        var corrupt = pythonFixture
        // First name has exactly five bytes, keeping unrelated metadata valid.
        corrupt.replaceSubrange(30..<35, with: name.utf8)
        let central = centralOffset(corrupt)
        corrupt.replaceSubrange((central + 46)..<(central + 51), with: name.utf8)
        #expect(throws: (any Error).self) { try BackupArchive.decode(corrupt) }
    }

    @Test func rejectsInvalidNameEncodingAndUnmarkedUnicode() {
        var invalid = pythonFixture
        invalid[30] = 0xff; invalid[centralOffset(invalid) + 46] = 0xff
        #expect(throws: (any Error).self) { try BackupArchive.decode(invalid) }
        var unmarked = pythonFixture
        set16(&unmarked, 83 + 6, 0)
        set16(&unmarked, centralOffset(unmarked) + 51 + 55 + 8, 0)
        #expect(throws: (any Error).self) { try BackupArchive.decode(unmarked) }
    }

    @Test func rejectsDuplicateAndCaseConflictingNamesFromCentralDirectory() throws {
        let original = try BackupArchive.encode(["a.csv": Data(), "b.csv": Data()])
        for replacement in [UInt8(ascii: "a"), UInt8(ascii: "A")] {
            var corrupt = original
            let central = centralOffset(corrupt)
            corrupt[35 + 30] = replacement
            corrupt[central + 51 + 46] = replacement
            #expect(throws: (any Error).self) { try BackupArchive.decode(corrupt) }
        }
    }

    @Test(arguments: [UInt16(8), UInt16(99)])
    func rejectsOtherCompressionMethods(_ method: UInt16) {
        var corrupt = pythonFixture
        set16(&corrupt, 8, method); set16(&corrupt, centralOffset(corrupt) + 10, method)
        #expect(throws: (any Error).self) { try BackupArchive.decode(corrupt) }
    }

    @Test(arguments: [UInt16(1), UInt16(0x40), UInt16(8), UInt16(0x2000), UInt16(0x10)])
    func rejectsEncryptionDescriptorsAndUnknownFlags(_ flags: UInt16) {
        var corrupt = pythonFixture
        set16(&corrupt, 6, flags); set16(&corrupt, centralOffset(corrupt) + 8, flags)
        #expect(throws: (any Error).self) { try BackupArchive.decode(corrupt) }
    }

    @Test func rejectsZIP64AndUnsupportedExtraFields() {
        for relative in [20, 24, 42] {
            var corrupt = pythonFixture
            set32(&corrupt, centralOffset(corrupt) + relative, .max)
            #expect(throws: (any Error).self) { try BackupArchive.decode(corrupt) }
        }
        var extra = pythonFixture
        set16(&extra, centralOffset(extra) + 30, 20)
        #expect(throws: (any Error).self) { try BackupArchive.decode(extra) }
        var localExtra = pythonFixture
        set16(&localExtra, 28, 20)
        #expect(throws: (any Error).self) { try BackupArchive.decode(localExtra) }
        var version = pythonFixture
        set16(&version, centralOffset(version) + 6, 45)
        #expect(throws: (any Error).self) { try BackupArchive.decode(version) }
        var endZIP64 = pythonFixture
        set16(&endZIP64, endZIP64.count - 12, .max)
        #expect(throws: (any Error).self) { try BackupArchive.decode(endZIP64) }
    }

    @Test(arguments: [UInt32(0o120777 << 16), UInt32(0o040700 << 16), UInt32(0o020600 << 16),
                      UInt32(2), UInt32(4), UInt32(0x10)])
    func rejectsSymlinkDirectorySpecialAndHiddenAttributes(_ attributes: UInt32) {
        var corrupt = pythonFixture
        set32(&corrupt, centralOffset(corrupt) + 38, attributes)
        #expect(throws: (any Error).self) { try BackupArchive.decode(corrupt) }
    }

    @Test func verifiesPayloadCRCAndStrictUTF8() {
        var badCRC = pythonFixture
        badCRC[35] = UInt8(ascii: "0")
        #expect(throws: BackupArchive.ArchiveError.checksumMismatch("a.csv")) { try BackupArchive.decode(badCRC) }
        // Python zlib.crc32(b"\xff23456789") == 0xbbf1e1fc. A valid checksum
        // must not make invalid CSV UTF-8 acceptable.
        var invalidUTF8 = pythonFixture
        invalidUTF8[35] = 0xff
        set32(&invalidUTF8, 14, 0xbbf1e1fc)
        set32(&invalidUTF8, centralOffset(invalidUTF8) + 16, 0xbbf1e1fc)
        #expect(throws: BackupArchive.ArchiveError.invalidUTF8("a.csv")) { try BackupArchive.decode(invalidUTF8) }
    }

    @Test(arguments: [4, 6, 8, 10, 12, 14, 18, 22, 26, 30])
    func rejectsLocalCentralDisagreement(_ offset: Int) {
        var corrupt = pythonFixture
        corrupt[offset] ^= 1
        #expect(throws: (any Error).self) { try BackupArchive.decode(corrupt) }
    }

    @Test func rejectsEveryTruncatedPrefixAndTrailingData() {
        for length in 0..<pythonFixture.count {
            #expect(throws: (any Error).self) { try BackupArchive.decode(pythonFixture.prefix(length)) }
        }
        for suffix in [Data([0]), Data("PK\u{5}\u{6}".utf8), pythonFixture.suffix(22)] {
            var corrupt = pythonFixture; corrupt.append(suffix)
            #expect(throws: (any Error).self) { try BackupArchive.decode(corrupt) }
        }
    }

    @Test func rejectsOverlapsGapsHiddenEntriesAndFakeOffsets() throws {
        let original = try BackupArchive.encode(["a.csv": Data(), "b.csv": Data()])
        let central = centralOffset(original)
        for offset in [UInt32(0), UInt32(1), UInt32(34), UInt32(36), UInt32(0xfffffffe)] {
            var corrupt = original
            set32(&corrupt, central + 51 + 42, offset)
            #expect(throws: (any Error).self) { try BackupArchive.decode(corrupt) }
        }
        // Remove a central entry, but preserve its real local header. EOCD counts
        // and directory size are consistent; the unlisted local record is not.
        var hidden = original
        hidden.removeSubrange((central + 51)..<(central + 102))
        set16(&hidden, hidden.count - 14, 1); set16(&hidden, hidden.count - 12, 1)
        set32(&hidden, hidden.count - 10, 51)
        #expect(throws: (any Error).self) { try BackupArchive.decode(hidden) }
        var prefix = original
        prefix.insert(0, at: 0)
        set32(&prefix, prefix.count - 6, UInt32(central + 1))
        set32(&prefix, central + 1 + 42, 1)
        set32(&prefix, central + 1 + 51 + 42, 36)
        #expect(throws: (any Error).self) { try BackupArchive.decode(prefix) }
    }

    @Test func centralOrderNeedNotEqualLocalOrder() throws {
        var archive = try BackupArchive.encode(["a.csv": Data("a".utf8), "b.csv": Data("b".utf8)])
        let central = centralOffset(archive)
        let first = archive.subdata(in: central..<(central + 51))
        let second = archive.subdata(in: (central + 51)..<(central + 102))
        archive.replaceSubrange(central..<(central + 102), with: second + first)
        #expect(try BackupArchive.decode(archive) == ["a.csv": Data("a".utf8), "b.csv": Data("b".utf8)])
    }

    @Test func rejectsSplitCommentsAndUnlistedDirectoryBytes() {
        for offset in [4, 6, 8, 12, 16, 20] {
            var corrupt = pythonFixture
            corrupt[corrupt.count - 22 + offset] ^= 1
            #expect(throws: (any Error).self) { try BackupArchive.decode(corrupt) }
        }
        for offset in [32, 34, 36] {
            var corrupt = pythonFixture
            set16(&corrupt, centralOffset(corrupt) + offset, 2)
            #expect(throws: (any Error).self) { try BackupArchive.decode(corrupt) }
        }
    }

    @Test func sizeAndCountLimitsApplyBeforeLargeAllocations() throws {
        let maximumCount = Dictionary(uniqueKeysWithValues: (0..<64).map { ("f\($0).csv", Data()) })
        #expect(try BackupArchive.decode(BackupArchive.encode(maximumCount)).count == 64)
        var excessiveCount = maximumCount; excessiveCount["overflow.csv"] = Data()
        #expect(throws: BackupArchive.ArchiveError.limitExceeded("file count")) { try BackupArchive.encode(excessiveCount) }
        let tooLarge = Data(repeating: UInt8(ascii: "a"), count: BackupArchive.maximumFileBytes + 1)
        #expect(throws: BackupArchive.ArchiveError.limitExceeded("single CSV bytes")) {
            try BackupArchive.encode(["a.csv": tooLarge])
        }
        let full = Data(repeating: UInt8(ascii: "a"), count: BackupArchive.maximumFileBytes)
        #expect(throws: BackupArchive.ArchiveError.limitExceeded("total CSV bytes")) {
            try BackupArchive.encode(["a.csv": full, "b.csv": full, "c.csv": full])
        }
        var declaredLarge = pythonFixture
        let central = centralOffset(declaredLarge)
        set32(&declaredLarge, central + 20, UInt32(BackupArchive.maximumFileBytes + 1))
        set32(&declaredLarge, central + 24, UInt32(BackupArchive.maximumFileBytes + 1))
        #expect(throws: BackupArchive.ArchiveError.limitExceeded("single CSV bytes")) { try BackupArchive.decode(declaredLarge) }
        var declaredTotal = pythonFixture
        for entry in [central, central + 51, central + 51 + 55] {
            set32(&declaredTotal, entry + 20, UInt32(BackupArchive.maximumFileBytes))
            set32(&declaredTotal, entry + 24, UInt32(BackupArchive.maximumFileBytes))
        }
        #expect(throws: BackupArchive.ArchiveError.limitExceeded("total CSV bytes")) { try BackupArchive.decode(declaredTotal) }
        var declaredCount = pythonFixture
        set16(&declaredCount, declaredCount.count - 14, 65); set16(&declaredCount, declaredCount.count - 12, 65)
        #expect(throws: BackupArchive.ArchiveError.limitExceeded("file count")) { try BackupArchive.decode(declaredCount) }
        let longestName = String(repeating: "x", count: 251) + ".csv"
        #expect(try BackupArchive.decode(BackupArchive.encode([longestName: Data()]))[longestName] == Data())
    }

    private func centralOffset(_ data: Data) -> Int { Int(u32(data, data.count - 6)) }
    private func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
    private func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
    private func set16(_ data: inout Data, _ offset: Int, _ value: UInt16) {
        data[offset] = UInt8(truncatingIfNeeded: value); data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
    private func set32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
}
