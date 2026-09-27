import Foundation

public enum ImportError: Error, Equatable, Sendable {
    case invalidFile(String), invalidState, stalePreview, unavailableRow, tooManySelected
}

/// Public interchange format for ordinary cash events, distinct from complete backup CSV.
public enum ImportCSV {
    public static let header = ["source_id", "occurred_at", "type", "amount", "currency", "account", "destination_account", "category", "title", "note", "status"]
    public static let maximumBytes = 16 * 1024 * 1024
    public static let maximumRows = 10_000

    public static var template: Data {
        encode([header, ["example-0001", "2026-01-15T12:30:00+08:00", "expense", "20.10", "CNY", "银行卡尾号1234", "", "餐饮/正餐", "午餐", "合成示例，请替换后导入", "success"]])
    }

    public static func parse(_ data: Data, name: String, namespace: String, subjectID: UUID = SeedData.mpcID,
                             at date: Date = Date()) throws -> ImportBatch {
        let namespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !namespace.isEmpty, namespace.utf8.count <= 256 else { throw ImportError.invalidFile("请填写稳定的来源身份，例如银行名称和卡号尾号。") }
        let rows = try decode(data)
        guard rows.first == header else { throw ImportError.invalidFile("表头不匹配，请使用通用 CSV 模板；完整 ZIP 备份请走恢复入口。") }
        guard rows.count > 1 else { throw ImportError.invalidFile("文件没有数据行。") }
        guard rows.dropFirst().allSatisfy({ $0.count == header.count }) else { throw ImportError.invalidFile("数据行列数与表头不一致。") }
        return ImportBatch(name: name, namespace: namespace, createdAt: date,
                           rows: rows.dropFirst().map { ImportRow(raw: $0, subjectID: subjectID) })
    }

    /// UTF-8 with optional BOM; RFC 4180 quoting; LF or CRLF; literal backslashes and empty fields.
    static func decode(_ data: Data) throws -> [[String]] {
        guard data.count <= maximumBytes, String(data: data, encoding: .utf8) != nil else {
            throw ImportError.invalidFile("CSV 必须为 UTF-8，且不能超过 16 MiB。")
        }
        var bytes = Array(data)
        if bytes.starts(with: [239, 187, 191]) { bytes.removeFirst(3) }
        var rows: [[String]] = [], row: [String] = [], field: [UInt8] = []
        var state = 0, index = 0, endedRow = true
        func finishField() throws {
            guard row.count < 32 else { throw ImportError.invalidFile("列数过多。") }
            row.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true)
        }
        func finishRow() throws {
            guard rows.count < maximumRows + 1 else { throw ImportError.invalidFile("单个文件最多 10,000 笔，请拆分文件。") }
            rows.append(row); row.removeAll(keepingCapacity: true)
        }
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            guard byte != 0, field.count < 65_536 else { throw ImportError.invalidFile("字段过长或含无效字符。") }
            if state == 2 {
                if byte == 34 { state = 3 } else { field.append(byte) }
                continue
            }
            if state == 3 && byte == 34 { field.append(34); state = 2; continue }
            if byte == 44 {
                try finishField(); state = 0; endedRow = false
            } else if byte == 10 || byte == 13 {
                if byte == 13 {
                    guard index < bytes.count, bytes[index] == 10 else { throw ImportError.invalidFile("请使用 LF 或 CRLF 换行。") }
                    index += 1
                }
                try finishField(); try finishRow(); state = 0; endedRow = true
            } else if state == 0 && byte == 34 {
                state = 2; endedRow = false
            } else {
                guard state != 3, byte != 34 else { throw ImportError.invalidFile("CSV 引号未正确转义。") }
                field.append(byte); state = 1; endedRow = false
            }
        }
        guard state != 2 else { throw ImportError.invalidFile("CSV 引号未闭合。") }
        if !endedRow { try finishField(); try finishRow() }
        guard !rows.isEmpty else { throw ImportError.invalidFile("文件为空。") }
        return rows
    }

    static func encode(_ rows: [[String]]) -> Data {
        Data((rows.map { row in row.map { value in
            if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
                return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return value
        }.joined(separator: ",") }.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// Requires explicit time zone and a real Gregorian date; never infers the phone's locale.
    static func date(_ text: String) -> Date? {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func part(_ index: Int) -> String { Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "" }
        let numbers = (1...6).compactMap { Int(part($0)) }
        guard numbers.count == 6, numbers[0] > 0, (1...12).contains(numbers[1]), (1...31).contains(numbers[2]),
              (0...23).contains(numbers[3]), (0...59).contains(numbers[4]), (0...59).contains(numbers[5]) else { return nil }
        let zone = part(8)
        var offset = 0
        if zone != "Z" {
            let hours = Int(zone.dropFirst().prefix(2))!, minutes = Int(zone.suffix(2))!
            guard hours <= 14, minutes < 60, hours != 14 || minutes == 0 else { return nil }
            offset = (hours * 3600 + minutes * 60) * (zone.first == "-" ? -1 : 1)
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: offset)!
        let components = DateComponents(year: numbers[0], month: numbers[1], day: numbers[2], hour: numbers[3], minute: numbers[4], second: numbers[5])
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == components else { return nil }
        return date.addingTimeInterval(Double("0." + part(7)) ?? 0)
    }
}
