import Foundation

public enum BackupError: Error, Equatable, Sendable {
    case unsupportedFormat(profile: String, version: String)
    case invalidArchive(reason: String)
    case invalidSnapshot(reason: String)
}

/// CSV framing only: callers apply the schema's null and text escaping rules.
/// UTF-8 and RFC 4180 field quoting, with the project's mandatory LF records.
enum BackupCSV {
    static let maxFileBytes = 32 * 1024 * 1024
    static let maxTotalBytes = 64 * 1024 * 1024
    static let maxRecords = 100_001 // Header plus 100,000 data records per table.
    static let maxColumns = 64
    static let maxCellBytes = 1024 * 1024

    static func encode(_ records: [[String?]]) -> Data {
        var output = Data()
        for row in records {
            for (index, value) in row.enumerated() {
                if index > 0 { output.append(44) }
                guard let value else { output.append(contentsOf: [92, 78]); continue }
                let quoted = value.isEmpty || value.utf8.contains(where: { $0 == 44 || $0 == 34 || $0 == 13 || $0 == 10 })
                if quoted { output.append(34) }
                // Work in UTF-8 bytes: a backslash followed by a combining mark is
                // still an escape character, even if Swift treats both as one Character.
                for byte in value.utf8 {
                    if byte == 92 || byte == 34 { output.append(byte) }
                    output.append(byte)
                }
                if quoted { output.append(34) }
            }
            output.append(10)
        }
        return output
    }

    /// Returns raw fields after CSV unquoting, before null/text unescaping.
    static func decode(_ data: Data, file: String) throws -> [[String]] {
        guard data.count <= maxFileBytes else { throw BackupError.invalidArchive(reason: "CSV file too large: \(file)") }
        let bytes = Array(data)
        guard !bytes.starts(with: [0xef, 0xbb, 0xbf]), bytes.last == 10,
              String(data: data, encoding: .utf8) != nil else {
            throw BackupError.invalidArchive(reason: "Invalid UTF-8, BOM or missing final LF: \(file)")
        }
        var rows: [[String]] = [], row: [String] = [], field: [UInt8] = []
        // 0 = start, 1 = unquoted, 2 = quoted, 3 = closing quote.
        var state = 0
        for byte in bytes {
            guard field.count <= maxCellBytes, row.count < maxColumns, rows.count < maxRecords else {
                throw BackupError.invalidArchive(reason: "CSV record, column or cell limit exceeded: \(file)")
            }
            if state == 2 {
                if byte == 34 { state = 3 } else { field.append(byte) }
                continue
            }
            if state == 3 && byte == 34 { field.append(34); state = 2; continue }
            if byte == 44 || byte == 10 {
                // An empty textual cell must be explicitly quoted, including the last cell.
                guard state != 0 else { throw BackupError.invalidArchive(reason: "Unquoted empty field: \(file)") }
                row.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true); state = 0
                if byte == 10 { rows.append(row); row.removeAll(keepingCapacity: true) }
            } else if state == 0 && byte == 34 {
                state = 2
            } else if state == 3 || byte == 34 || byte == 13 {
                throw BackupError.invalidArchive(reason: "Invalid CSV quoting or record separator: \(file)")
            } else {
                field.append(byte); state = 1
            }
        }
        guard state == 0 && row.isEmpty && field.isEmpty && !rows.isEmpty else {
            throw BackupError.invalidArchive(reason: "Unterminated CSV field: \(file)")
        }
        return rows
    }

    static func text(_ raw: String, file: String) throws -> String {
        var result: [UInt8] = [], pending = false
        for byte in raw.utf8 {
            if byte == 92 {
                if pending { result.append(byte) }
                pending.toggle()
            } else {
                guard !pending else { throw BackupError.invalidArchive(reason: "Unpaired text backslash: \(file)") }
                result.append(byte)
            }
        }
        guard !pending else { throw BackupError.invalidArchive(reason: "Unpaired text backslash: \(file)") }
        return String(decoding: result, as: UTF8.self)
    }
}
