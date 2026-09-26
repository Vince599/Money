import Foundation
import LedgerCore
#if os(Windows)
import ucrt
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private enum BaselineError: Error {
    case invalidArguments, incorrectResult(String)
}

private struct Options {
    let output: URL
    let metadata: URL
    let sizes: [Int]
    let samples: Int
    let warmups: Int

    init() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 10 else { throw BaselineError.invalidArguments }
        var values: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard values.updateValue(arguments[index + 1], forKey: arguments[index]) == nil else {
                throw BaselineError.invalidArguments
            }
        }
        guard Set(values.keys) == ["--output", "--metadata", "--sizes", "--samples", "--warmups"],
              let output = values["--output"], let metadata = values["--metadata"],
              let sizesText = values["--sizes"], let samples = Int(values["--samples"] ?? ""),
              let warmups = Int(values["--warmups"] ?? ""), (1...1000).contains(samples),
              (0...100).contains(warmups) else { throw BaselineError.invalidArguments }
        let components = sizesText.split(separator: ",", omittingEmptySubsequences: false)
        let sizes = components.compactMap { Int($0) }
        guard !sizes.isEmpty, sizes.count == components.count, Set(sizes).count == sizes.count,
              sizes.allSatisfy({ (0...100_000).contains($0) }) else { throw BaselineError.invalidArguments }
        self.output = URL(fileURLWithPath: output)
        self.metadata = URL(fileURLWithPath: metadata)
        self.sizes = sizes; self.samples = samples; self.warmups = warmups
    }
}

private func fixedID(_ namespace: String, _ ordinal: Int) -> UUID {
    let suffix = String(ordinal, radix: 16)
    return UUID(uuidString: namespace + "-0000-4000-8000-" + String(repeating: "0", count: 12 - suffix.count) + suffix)!
}

private struct Fixture {
    static let version = "core-mixed-v1"
    let book: LedgerBook
    let addition: LedgerEntry
    let filtered: EntryFilter
    let allExpectedIDs: [UUID]
    let filteredExpectedIDs: [UUID]
    let expectedBalanceAfterRecord: Int64

    init(count: Int) throws {
        let epoch = Date(timeIntervalSince1970: 1_640_995_200) // 2022-01-01 UTC, fixed across runs.
        let currencies: [Currency] = [.cny, .cny, .cny, .hkd, .usd, .cny]
        let kinds: [AccountKind] = [.bank, .wallet, .creditCard, .bank, .wallet, .storedValue]
        let accounts = (0..<6).map { index in
            Account(id: fixedID("20000000", index + 1), name: "合成账户 \(index) · 中文 English 长名称用于基线",
                    kind: kinds[index], nature: index == 2 ? .liability : .asset,
                    currency: currencies[index], openingMinor: 100_000_000,
                    openingDate: epoch, includedInSummary: index != 5)
        }
        let secondSubject = LedgerCore.Subject(id: fixedID("30000000", 1), name: "合成主体 · 家庭")
        let from = Date(timeIntervalSince1970: 1_672_531_200) // 2023-01-01 UTC.
        let to = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 UTC.
        var entries: [LedgerEntry] = []
        entries.reserveCapacity(count)
        var matching: [LedgerEntry] = []
        var accountZeroBalance: Int64 = 100_000_000
        for index in 0..<count {
            let slot = index % 12
            let kind: EntryKind = slot < 6 ? .expense : slot < 9 ? .income : .transfer
            let source = kind == .transfer ? index % 3 : index % 6
            let destination = kind == .transfer ? (source + 1) % 3 : nil
            let minor = Int64(100 + index % 19_900)
            let date = epoch.addingTimeInterval(Double((index % 1461) * 86_400 + index / 1461))
            let subject = index % 2 == 0 ? SeedData.mpcID : secondSubject.id
            let hasKeyword = index % 5 == 0
            let category = kind == .expense ? SeedData.mealsID : kind == .income ? SeedData.salaryIncomeID : nil
            let entry = LedgerEntry(id: fixedID("10000000", index + 1),
                                    operationID: fixedID("40000000", index + 1), kind: kind,
                                    amount: Money(minorUnits: minor, currency: currencies[source]),
                                    accountID: accounts[source].id,
                                    destinationAccountID: destination.map { accounts[$0].id },
                                    categoryID: category, subjectID: subject, occurredAt: date,
                                    createdAt: epoch.addingTimeInterval(Double(index)),
                                    title: hasKeyword ? "合成午餐 Café \(index)" : "合成记录 English \(index)",
                                    note: index % 11 == 0 ? String(repeating: "用于性能基线的长备注；中文与 English、组合字符 e\u{301}。", count: 8) : "合成备注")
            entries.append(entry)
            if source == 0 { accountZeroBalance += kind == .income ? minor : -minor }
            if destination == 0 { accountZeroBalance += minor }
            if kind == .expense, source == 0, subject == SeedData.mpcID, hasKeyword,
               minor >= 500, minor <= 15_000, date >= from, date < to {
                matching.append(entry)
            }
        }
        let book = LedgerBook(accounts: accounts, entries: entries, subjects: SeedData.subjects + [secondSubject])
        // Fixture generation and its full validation are outside all measured samples.
        try LedgerEngine.validate(book)
        let addition = LedgerEntry(id: fixedID("90000000", 1), operationID: fixedID("90000001", 1),
                                   kind: .expense, amount: Money(minorUnits: 2_010), accountID: accounts[0].id,
                                   categoryID: SeedData.mealsID, occurredAt: to, createdAt: to,
                                   title: "合成新增午餐", note: "每轮从同一基线追加，不累计规模")
        self.book = book; self.addition = addition
        self.filtered = EntryFilter(keyword: "午餐", kind: .expense, accountID: accounts[0].id,
                                    categoryID: SeedData.foodID, subjectID: SeedData.mpcID, currency: .cny,
                                    minimumMinor: 500, maximumMinor: 15_000, from: from, to: to)
        // Independent expected order: fixture occurrence dates are unique, so no tie-break is needed.
        self.allExpectedIDs = entries.sorted { $0.occurredAt > $1.occurredAt }.map(\.id)
        self.filteredExpectedIDs = matching.sorted { $0.occurredAt > $1.occurredAt }.map(\.id)
        self.expectedBalanceAfterRecord = accountZeroBalance - addition.amount.minorUnits
    }
}

private struct Sample: Codable {
    let entries: Int
    let operation: String
    let phase: String
    let ordinal: Int
    let elapsedNanoseconds: Int64
    let status: String
    let failure: String?
}

private func statistics(_ samples: [Sample]) -> [String: Any] {
    let measured = samples.filter { $0.phase == "measured" }
    let values = measured.map(\.elapsedNanoseconds).sorted()
    func percentile(_ fraction: Double) -> Any {
        guard !values.isEmpty else { return NSNull() }
        let index = max(0, Int(ceil(Double(values.count) * fraction)) - 1)
        return Double(values[index]) / 1_000_000
    }
    return ["measuredAttempts": measured.count, "failedAttempts": measured.filter { $0.status != "ok" }.count,
            "p50Milliseconds": percentile(0.50), "p95Milliseconds": percentile(0.95),
            "maximumMilliseconds": values.last.map { Double($0) / 1_000_000 } as Any? ?? NSNull()]
}

private final class Runner {
    let options: Options
    let metadata: Any
    let started = ISO8601DateFormatter().string(from: Date())
    var samples: [Sample] = []
    var fixtures: [[String: Int]] = []
    var status = "running"
    var failure: String?

    init(options: Options) throws {
        self.options = options
        metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: options.metadata))
    }

    func persist() throws {
        let encoder = JSONEncoder()
        let sampleObjects = try JSONSerialization.jsonObject(with: encoder.encode(samples))
        let operations = ["validate", "recordExpense", "queryAll", "queryCombined"]
        let summaries: [[String: Any]] = options.sizes.flatMap { size in
            operations.map { operation in
                var summary = statistics(samples.filter { $0.entries == size && $0.operation == operation })
                summary["entries"] = size; summary["operation"] = operation
                return summary
            }
        }
        var report: [String: Any] = [
            "reportVersion": "ledger-core-performance-v1", "fixtureVersion": Fixture.version,
            "status": status, "startedAtUTC": started, "updatedAtUTC": ISO8601DateFormatter().string(from: Date()),
            "metadata": metadata, "sizes": options.sizes, "samplesPerOperation": options.samples,
            "warmupsPerOperation": options.warmups, "samples": sampleObjects, "summaries": summaries,
            "fixtures": fixtures,
            "clock": "Swift ContinuousClock; integer nanoseconds",
            "percentileMethod": "Nearest rank: sorted[ceil(p * n) - 1]; measured attempts only; warmups retained separately",
            "scope": "Release, in-memory LedgerCore functions only. Not SQLite, App, SwiftUI, device performance, or Q01-Q09 acceptance.",
            "cacheConditions": "Synthetic book resident in memory; warmups and untimed correctness checks may warm caches. Not a cold-cache experiment.",
            "boundaries": [
                "validate": "LedgerEngine.validate(book) return/throw",
                "recordExpense": "LedgerEngine.record(new expense, in: unchanged baseline) return/throw; includes engine validation, excludes SQLite and UI",
                "queryAll": "EntryQuery.entries default filter return/throw; all matching rows sorted, no pagination or rendering",
                "queryCombined": "EntryQuery.entries combined synthetic filter return/throw; all matching rows sorted, no debounce or rendering"
            ],
            "excludedFromTiming": "Fixture creation, correctness checks, JSON serialization, report writes, compilation and console output."
        ]
        if let failure { report["failure"] = failure }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: options.output, options: .atomic)
    }

    func measure<Value>(_ operation: String, fixture: Fixture,
                        work: () throws -> Value, check: (Value) throws -> Void) throws {
        for iteration in 0..<(options.warmups + options.samples) {
            let phase = iteration < options.warmups ? "warmup" : "measured"
            let ordinal = phase == "warmup" ? iteration + 1 : iteration - options.warmups + 1
            let clock = ContinuousClock()
            let start = clock.now
            let result = Result { try work() }
            let elapsed = start.duration(to: clock.now).components
            let nanoseconds = elapsed.seconds * 1_000_000_000 + elapsed.attoseconds / 1_000_000_000
            var issue: String?
            do { try check(result.get()) }
            catch { issue = String(describing: error) } // Inputs and errors in this tool are synthetic only.
            samples.append(Sample(entries: fixture.book.entries.count, operation: operation, phase: phase,
                                  ordinal: ordinal, elapsedNanoseconds: nanoseconds,
                                  status: issue == nil ? "ok" : "failed", failure: issue))
            if let issue {
                try persist()
                throw BaselineError.incorrectResult("\(operation): \(issue)")
            }
        }
        try persist()
        let summary = statistics(samples.filter { $0.entries == fixture.book.entries.count && $0.operation == operation })
        print("\(fixture.book.entries.count) entries / \(operation): p50=\(summary["p50Milliseconds"]!) ms, p95=\(summary["p95Milliseconds"]!) ms, max=\(summary["maximumMilliseconds"]!) ms")
    }

    func run() throws {
        try persist()
        do {
            for size in options.sizes {
                let fixture = try Fixture(count: size)
                fixtures.append(["entries": size, "accounts": fixture.book.accounts.count,
                                 "subjects": fixture.book.subjects.count,
                                 "queryCombinedExpectedMatches": fixture.filteredExpectedIDs.count])
                print("Fixture \(size) entries: combined query expects \(fixture.filteredExpectedIDs.count) matches; every sample checks actual IDs against this expectation.")
                try measure("validate", fixture: fixture, work: { try LedgerEngine.validate(fixture.book) }) { _ in
                    guard fixture.book.entries.count == size else { throw BaselineError.incorrectResult("baseline size changed") }
                }
                try measure("recordExpense", fixture: fixture, work: {
                    try LedgerEngine.record(fixture.addition, in: fixture.book)
                }) { result in
                    guard result.entries.count == size + 1, result.entries.last == fixture.addition,
                          fixture.book.entries.count == size,
                          try LedgerEngine.balance(of: fixture.addition.accountID, in: result).minorUnits == fixture.expectedBalanceAfterRecord
                    else { throw BaselineError.incorrectResult("record count, identity or balance") }
                }
                try measure("queryAll", fixture: fixture, work: { try EntryQuery.entries(in: fixture.book) }) { result in
                    guard result.map(\.id) == fixture.allExpectedIDs else { throw BaselineError.incorrectResult("all query results or order") }
                }
                try measure("queryCombined", fixture: fixture, work: { try EntryQuery.entries(in: fixture.book, matching: fixture.filtered) }) { result in
                    guard result.map(\.id) == fixture.filteredExpectedIDs else { throw BaselineError.incorrectResult("filtered query results or order") }
                }
            }
            status = "completed"
            try persist()
        } catch {
            status = "failed"; failure = String(describing: error)
            try persist()
            throw error
        }
    }
}

do {
    let runner = try Runner(options: Options())
    try runner.run()
} catch {
    FileHandle.standardError.write(Data("Core baseline failed: \(error)\n".utf8))
    exit(1)
}
