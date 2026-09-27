import Foundation

/// Presentation metadata only. Selecting a template never creates or changes a saved account.
public struct AccountIcon: Identifiable, Equatable, Sendable {
    public let id: String
    public let assetName: String?
    public let fallbackSymbol: String
    public let colorHex: String
    public let accessibilityName: String
}

public struct AccountInstitution: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let shortName: String
    public let aliases: [String]
    public let iconID: String
}

public enum AccountTemplateGroup: String, CaseIterable, Sendable {
    case wallet, bank, creditCard, storedValue, cash

    public var title: String {
        switch self {
        case .wallet: "支付钱包"
        case .bank: "银行卡"
        case .creditCard: "信用卡"
        case .storedValue: "话费与储值"
        case .cash: "现金"
        }
    }
}

/// Defaults for a new account, separate from an institution's shared brand icon.
public struct AccountTemplate: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let group: AccountTemplateGroup
    public let institutionID: String?
    public let iconID: String
    public let kind: AccountKind
    public let nature: AccountNature
    public let currency: Currency
    public let includedInSummary: Bool
    public let keywords: [String]
    public let note: String

    /// Produces an unsaved account with its own UUID, even when reusing the same template.
    /// Stable presentation IDs are saved independently of the account's custom name.
    public func makeAccount(name: String? = nil, openingMinor: Int64 = 0,
                            openingDate: Date = Date()) -> Account {
        Account(name: name ?? self.name, kind: kind, nature: nature, currency: currency,
                openingMinor: openingMinor, openingDate: openingDate,
                includedInSummary: includedInSummary,
                institutionID: institutionID, templateID: id, iconID: iconID)
    }

    /// Editing must preserve kind, nature, currency, opening amount/date and account identity.
    /// Compatibility only filters suggestions; it does not authorize applying creation defaults.
    public func isCompatible(with account: Account) -> Bool {
        kind == account.kind && nature == account.nature && currency == account.currency
    }
}

public extension AccountTemplateCatalog {
    static func template(id: String) -> AccountTemplate? { templates.first { $0.id == id } }
    static func institution(id: String) -> AccountInstitution? { institutions.first { $0.id == id } }
    static func icon(id: String) -> AccountIcon? { icons.first { $0.id == id } }

    /// Supports Chinese names, short names and curated aliases such as ICBC / 工行 / gongshang.
    static func search(_ query: String, group: AccountTemplateGroup? = nil) -> [AccountTemplate] {
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "zh_Hans_CN"))
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return templates.filter { template in
            guard group == nil || template.group == group else { return false }
            let institution = template.institutionID.flatMap { Self.institution(id: $0) }
            let fields = [template.name, template.id, institution?.name ?? "", institution?.shortName ?? ""]
                + template.keywords + (institution?.aliases ?? [])
            let text = fields.joined(separator: " ").folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "zh_Hans_CN"))
            return words.allSatisfy { text.contains($0) }
        }
    }
}
