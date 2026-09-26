import Foundation

public enum AmountExpressionError: Error, Equatable, Sendable {
    case invalidSyntax
    case divisionByZero
    case overflow
    case tooComplex
    case excessPrecision
}

/// An input helper only: posted amounts remain Money, while drafts retain the original expression.
public enum AmountExpression {
    public struct Evaluation: Equatable, Sendable {
        public let money: Money
        /// True whenever the exact result differs from the amount in the currency's smallest unit.
        public let wasRounded: Bool
    }

    public static let maximumUTF8Length = 512
    public static let maximumTokens = 256
    public static let maximumParenthesisDepth = 32

    /// Supports +, -, *, /, ×, ÷, unary signs and parentheses with ordinary operator precedence.
    /// Uses bounded exact rational arithmetic and rounds only the final result, halfway away from zero.
    /// Zero and negative results can be previewed; EntryDraft rejects them for ordinary entries.
    public static func evaluate(_ text: String, currency: Currency = .cny) throws -> Evaluation {
        guard text.utf8.count <= maximumUTF8Length else { throw AmountExpressionError.tooComplex }
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var parser = try Parser(input)

        // Preserve the established strict money format for a plain number. A mistyped extra decimal
        // must not silently become a valid entry merely because calculator support was added.
        if let literal = parser.plainAmountLiteral {
            if let point = literal.firstIndex(of: "."),
               literal.distance(from: point, to: literal.endIndex) - 1 > currency.fractionDigits {
                throw AmountExpressionError.excessPrecision
            }
            do {
                return Evaluation(money: try Money.parse(input, currency: currency), wasRounded: false)
            } catch LedgerError.overflow {
                throw AmountExpressionError.overflow
            } catch {
                throw AmountExpressionError.invalidSyntax
            }
        }

        let value = try parser.parse()
        var scale: UInt128 = 1
        for _ in 0..<currency.fractionDigits { scale *= 10 }
        let denominator = UInt128(value.denominator)
        let scaled = value.numerator.magnitude.multipliedFullWidth(by: scale)
        // dividingFullWidth requires the quotient to fit UInt128. A larger result cannot fit Money.
        guard scaled.high < denominator else { throw AmountExpressionError.overflow }
        let (quotient, remainder) = denominator.dividingFullWidth(scaled)
        let increment: UInt128 = remainder >= denominator - remainder ? 1 : 0
        let rounded = quotient.addingReportingOverflow(increment)
        let limit = UInt128(Int64.max) + (value.numerator < 0 ? 1 : 0)
        guard !rounded.overflow, rounded.partialValue <= limit else { throw AmountExpressionError.overflow }
        let units: Int64
        if value.numerator < 0 {
            units = rounded.partialValue == UInt128(Int64.max) + 1 ? Int64.min : -Int64(rounded.partialValue)
        } else {
            units = Int64(rounded.partialValue)
        }
        return Evaluation(money: Money(minorUnits: units, currency: currency), wasRounded: remainder != 0)
    }
}

private extension AmountExpression {
    enum Token {
        case number(Rational, String)
        case plus, minus, multiply, divide, open, close
    }

    struct Parser {
        var tokens: [Token] = []
        var position = 0
        var depth = 0

        init(_ text: String) throws {
            let scalars = Array(text.unicodeScalars)
            var index = 0
            while index < scalars.count {
                let scalar = scalars[index]
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { index += 1; continue }
                switch scalar.value {
                case 43: tokens.append(.plus)
                case 45: tokens.append(.minus)
                case 42, 215: tokens.append(.multiply)
                case 47, 247: tokens.append(.divide)
                case 40: tokens.append(.open)
                case 41: tokens.append(.close)
                case 48...57:
                    let start = index
                    while index < scalars.count, (48...57).contains(scalars[index].value) { index += 1 }
                    if index < scalars.count, scalars[index].value == 46 {
                        index += 1
                        let fractionStart = index
                        while index < scalars.count, (48...57).contains(scalars[index].value) { index += 1 }
                        guard index > fractionStart else { throw AmountExpressionError.invalidSyntax }
                    }
                    let literal = String(String.UnicodeScalarView(scalars[start..<index]))
                    tokens.append(.number(try Rational(decimal: literal), literal))
                    index -= 1
                default: throw AmountExpressionError.invalidSyntax
                }
                guard tokens.count <= maximumTokens else { throw AmountExpressionError.tooComplex }
                index += 1
            }
        }

        var plainAmountLiteral: String? {
            if tokens.count == 1, case let .number(_, literal) = tokens[0] { return literal }
            if tokens.count == 2, case .minus = tokens[0], case let .number(_, literal) = tokens[1] { return literal }
            return nil
        }

        mutating func parse() throws -> Rational {
            let result = try addition()
            guard position == tokens.count else { throw AmountExpressionError.invalidSyntax }
            return result
        }

        mutating func addition() throws -> Rational {
            var result = try multiplication()
            while position < tokens.count {
                switch tokens[position] {
                case .plus:
                    position += 1
                    result = try result.adding(multiplication())
                case .minus:
                    position += 1
                    result = try result.adding(multiplication().negated())
                default: return result
                }
            }
            return result
        }

        mutating func multiplication() throws -> Rational {
            var result = try unary()
            while position < tokens.count {
                switch tokens[position] {
                case .multiply:
                    position += 1
                    result = try result.multiplied(by: unary())
                case .divide:
                    position += 1
                    result = try result.divided(by: unary())
                default: return result
                }
            }
            return result
        }

        mutating func unary() throws -> Rational {
            var negative = false
            while position < tokens.count {
                if case .minus = tokens[position] { negative.toggle(); position += 1 }
                else if case .plus = tokens[position] { position += 1 }
                else { break }
            }
            guard position < tokens.count else { throw AmountExpressionError.invalidSyntax }
            let result: Rational
            switch tokens[position] {
            case let .number(number, _):
                result = number
                position += 1
            case .open:
                depth += 1
                guard depth <= maximumParenthesisDepth else { throw AmountExpressionError.tooComplex }
                position += 1
                result = try addition()
                guard position < tokens.count, case .close = tokens[position] else {
                    throw AmountExpressionError.invalidSyntax
                }
                position += 1
                depth -= 1
            default: throw AmountExpressionError.invalidSyntax
            }
            return negative ? result.negated() : result
        }
    }

    /// The denominator is positive and numerator excludes Int128.min so negation is always safe.
    struct Rational {
        let numerator: Int128
        let denominator: Int128

        init(_ numerator: Int128, _ denominator: Int128 = 1) throws {
            guard numerator != Int128.min, denominator > 0 else { throw AmountExpressionError.overflow }
            let factor = Self.gcd(Int128(numerator.magnitude), denominator)
            self.numerator = numerator / factor
            self.denominator = denominator / factor
        }

        init(decimal text: String) throws {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            var fraction = parts.count == 2 ? String(parts[1]) : ""
            while fraction.last == "0" { fraction.removeLast() }
            var numerator: Int128 = 0
            for digit in (String(parts[0]) + fraction).utf8 {
                numerator = try Self.add(Self.multiply(numerator, 10), Int128(digit - 48))
            }
            var denominator: Int128 = 1
            for _ in fraction { denominator = try Self.multiply(denominator, 10) }
            try self.init(numerator, denominator)
        }

        private init(reducedNumerator: Int128, denominator: Int128) {
            self.numerator = reducedNumerator
            self.denominator = denominator
        }

        func negated() -> Rational {
            Rational(reducedNumerator: -numerator, denominator: denominator)
        }

        func adding(_ other: Rational) throws -> Rational {
            let shared = Self.gcd(denominator, other.denominator)
            let sum = try Self.add(Self.multiply(numerator, other.denominator / shared),
                                   Self.multiply(other.numerator, denominator / shared))
            guard sum != Int128.min else { throw AmountExpressionError.overflow }
            let reduction = Self.gcd(Int128(sum.magnitude), shared)
            return try Rational(sum / reduction,
                                Self.multiply(denominator / shared, other.denominator / reduction))
        }

        func multiplied(by other: Rational) throws -> Rational {
            let leftReduction = Self.gcd(Int128(numerator.magnitude), other.denominator)
            let rightReduction = Self.gcd(Int128(other.numerator.magnitude), denominator)
            return try Rational(Self.multiply(numerator / leftReduction, other.numerator / rightReduction),
                                Self.multiply(denominator / rightReduction, other.denominator / leftReduction))
        }

        func divided(by other: Rational) throws -> Rational {
            guard other.numerator != 0 else { throw AmountExpressionError.divisionByZero }
            let numeratorReduction = Self.gcd(Int128(numerator.magnitude), Int128(other.numerator.magnitude))
            let denominatorReduction = Self.gcd(denominator, other.denominator)
            let value = try Self.multiply(numerator / numeratorReduction, other.denominator / denominatorReduction)
            guard value != Int128.min else { throw AmountExpressionError.overflow }
            return try Rational(other.numerator < 0 ? -value : value,
                                Self.multiply(denominator / denominatorReduction,
                                              Int128(other.numerator.magnitude) / numeratorReduction))
        }

        static func gcd(_ a: Int128, _ b: Int128) -> Int128 {
            var a = a, b = b
            while b != 0 { (a, b) = (b, a % b) }
            return a
        }

        static func multiply(_ a: Int128, _ b: Int128) throws -> Int128 {
            let result = a.multipliedReportingOverflow(by: b)
            guard !result.overflow else { throw AmountExpressionError.overflow }
            return result.partialValue
        }

        static func add(_ a: Int128, _ b: Int128) throws -> Int128 {
            let result = a.addingReportingOverflow(b)
            guard !result.overflow else { throw AmountExpressionError.overflow }
            return result.partialValue
        }
    }
}
