import Foundation
import Testing
@testable import LedgerCore

@Suite("LedgerCoreTests amount calculator") struct AmountExpressionTests {
    @Test func precedenceParenthesesAndOperatorAliases() throws {
        #expect(try AmountExpression.evaluate("10+20×3").money.minorUnits == 7_000)
        #expect(try AmountExpression.evaluate("(10+20)*3").money.minorUnits == 9_000)
        #expect(try AmountExpression.evaluate("100÷4/5*2").money.minorUnits == 1_000)
        #expect(try AmountExpression.evaluate("10-3-2").money.minorUnits == 500)
        #expect(try AmountExpression.evaluate(" 10 +\n 20 * 3 ").money.minorUnits == 7_000)
    }

    @Test func decimalArithmeticNeverRoundsIntermediateResults() throws {
        let values = ["0.1+0.2": 30, "1/3*3": 100, "1/200*2": 1,
                      "1/6+1/6+1/6": 50, "3.005-0.005": 300, "0/7": 0]
        for (expression, amount) in values {
            let evaluation = try AmountExpression.evaluate(expression)
            #expect(evaluation.money.minorUnits == Int64(amount))
            #expect(!evaluation.wasRounded)
        }
    }

    @Test func finalRoundingIsHalfwayAwayFromZero() throws {
        let values = ["1/3": 33, "2/3": 67, "1/200": 1, "-1/200": -1,
                      "1/201": 0, "-1/201": 0, "2.675+0": 268, "-2.675+0": -268]
        for (expression, amount) in values {
            let evaluation = try AmountExpression.evaluate(expression)
            #expect(evaluation.money.minorUnits == Int64(amount))
            #expect(evaluation.wasRounded)
        }
    }

    @Test func unarySignsAndNonpositiveResultsCanBePreviewed() throws {
        #expect(try AmountExpression.evaluate("2*-3").money.minorUnits == -600)
        #expect(try AmountExpression.evaluate("-(2+3)").money.minorUnits == -500)
        #expect(try AmountExpression.evaluate("1--2").money.minorUnits == 300)
        #expect(try AmountExpression.evaluate("+(2-2)").money.minorUnits == 0)
        #expect(try AmountExpression.evaluate("1/-2").money.minorUnits == -50)
    }

    @Test func plainMoneyPreservesPrecisionRulesAndCanonicalResult() throws {
        let plain = try AmountExpression.evaluate(" 00012.3 ", currency: .usd)
        #expect(plain.money.decimalString == "12.30")
        #expect(plain.money.currency == .usd)
        #expect(!plain.wasRounded)
        #expect(throws: AmountExpressionError.excessPrecision) { try AmountExpression.evaluate("1.005") }
        #expect(throws: AmountExpressionError.excessPrecision) { try AmountExpression.evaluate("-1.000") }
        #expect(try AmountExpression.evaluate("1.005+0").money.minorUnits == 101)
    }

    @Test func moneyBoundariesAndRoundedOverflow() throws {
        #expect(try AmountExpression.evaluate("92233720368547758.07+0").money.minorUnits == Int64.max)
        #expect(try AmountExpression.evaluate("-92233720368547758.08+0").money.minorUnits == Int64.min)
        #expect(try AmountExpression.evaluate("92233720368547758.074+0").money.minorUnits == Int64.max)
        #expect(try AmountExpression.evaluate("-92233720368547758.084+0").money.minorUnits == Int64.min)
        #expect(throws: AmountExpressionError.overflow) { try AmountExpression.evaluate("92233720368547758.075+0") }
        #expect(throws: AmountExpressionError.overflow) { try AmountExpression.evaluate("-92233720368547758.085+0") }
        #expect(throws: AmountExpressionError.overflow) { try AmountExpression.evaluate("92233720368547758.08") }
    }

    @Test func rationalReductionAndWideFinalScaling() throws {
        let maximum = "170141183460469231731687303715884105727"
        #expect(try AmountExpression.evaluate("\(maximum)/\(maximum)").money.minorUnits == 100)
        let nearlyOne = try AmountExpression.evaluate("170141183460469231731687303715884105726/\(maximum)")
        #expect(nearlyOne.money.minorUnits == 100)
        #expect(nearlyOne.wasRounded)
        #expect(try AmountExpression.evaluate("(\(maximum)/2)*(2/\(maximum))").money.minorUnits == 100)
    }

    @Test func intermediateOverflowIsReportedWithoutTrapping() {
        for expression in ["170141183460469231731687303715884105728+0",
                           "170141183460469231731687303715884105727+1",
                           "170141183460469231731687303715884105727*2",
                           "1/0.000000000000000000000000000000000000001",
                           "1/170141183460469231731687303715884105727/2"] {
            #expect(throws: AmountExpressionError.overflow) { try AmountExpression.evaluate(expression) }
        }
    }

    @Test func divisionByZeroIncludesComputedDenominators() {
        for expression in ["1/0", "0/0", "2/(1-1)", "3÷(-0)"] {
            #expect(throws: AmountExpressionError.divisionByZero) { try AmountExpression.evaluate(expression) }
        }
    }

    @Test(arguments: ["", " ", "NaN", "1e2", "1,000", "1.", ".5", "1.2.3", "１２",
                      "1+", "()", "(1+2", "1+2)", "2(3)", "(1)(2)", "1 2", "1/**2", "abc", "1%2"])
    func malformedExpressionsAreRejected(_ expression: String) {
        #expect(throws: AmountExpressionError.invalidSyntax) { try AmountExpression.evaluate(expression) }
    }

    @Test func boundedComplexityRejectsOversizedAndDeepInput() throws {
        #expect(throws: AmountExpressionError.tooComplex) {
            try AmountExpression.evaluate(String(repeating: " ", count: AmountExpression.maximumUTF8Length + 1))
        }
        #expect(throws: AmountExpressionError.tooComplex) {
            try AmountExpression.evaluate(String(repeating: "(", count: 33) + "1" + String(repeating: ")", count: 33))
        }
        #expect(throws: AmountExpressionError.tooComplex) {
            try AmountExpression.evaluate(String(repeating: "+", count: AmountExpression.maximumTokens) + "1")
        }
        #expect(try AmountExpression.evaluate(String(repeating: "(", count: 32) + "1" + String(repeating: ")", count: 32)).money.minorUnits == 100)
    }

    @Test func draftPostsComputedAmountAndRetainsOriginalExpression() throws {
        let account = Account(name: "Calculator", openingMinor: 10_000)
        let book = LedgerBook(accounts: [account])
        let draft = EntryDraft(amountText: "10+20*3", accountID: account.id, expenseCategoryID: SeedData.mealsID)
        let entry = try draft.entry(in: book)
        #expect(entry.amount.minorUnits == 7_000)
        #expect(draft.amountText == "10+20*3")
        let restored = try JSONDecoder().decode(EntryDraft.self, from: JSONEncoder().encode(draft))
        #expect(restored == draft)
        #expect(try restored.entry(in: book).amount == entry.amount)
    }

    @Test func ordinaryDraftRejectsZeroNegativeAndRoundedToZero() {
        let account = Account(name: "Calculator")
        let book = LedgerBook(accounts: [account])
        for expression in ["1-1", "1-2", "1/300"] {
            let draft = EntryDraft(amountText: expression, accountID: account.id, expenseCategoryID: SeedData.mealsID)
            #expect(throws: LedgerError.invalidAmount) { try draft.entry(in: book) }
        }
    }
}
