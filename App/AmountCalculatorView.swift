import SwiftUI
import LedgerCore

/// The expression remains part of the ordinary autosaved draft until the user uses its result.
struct AmountCalculatorView: View {
    @Binding var expression: String
    let currency: Currency
    let errorMessage: (any Error) -> String
    @Environment(\.dismiss) private var dismiss
    private let keys = ["7", "8", "9", "÷", "4", "5", "6", "×", "1", "2", "3", "−", "0", ".", "(", "+"]
    private var evaluation: Result<AmountExpression.Evaluation, any Error> {
        Result { try AmountExpression.evaluate(expression, currency: currency) }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TextField("输入金额或算式", text: $expression)
                        .keyboardType(.numbersAndPunctuation)
                        .font(.title2).monospacedDigit().accessibilityIdentifier("calculator.expression")
                    switch evaluation {
                    case .success(let value):
                        Text(value.money.decimalString + " " + currency.rawValue)
                            .font(.largeTitle).monospacedDigit().accessibilityIdentifier("calculator.result")
                        if value.wasRounded {
                            Text("结果已四舍五入到小数点后两位；点击下方按钮使用此金额。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else { Text("先乘除，后加减；括号内优先计算。").font(.footnote).foregroundStyle(.secondary) }
                        if value.money.minorUnits <= 0 { Text("记账金额需要大于零。").foregroundStyle(.red) }
                    case .failure(let error):
                        Text(expression.isEmpty ? "输入数字开始计算。" : errorMessage(error))
                            .foregroundStyle(expression.isEmpty ? Color.secondary : .red)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        ForEach(keys, id: \.self) { key in
                            Button(key) { expression += key == "−" ? "-" : key }
                                .font(.title2).frame(maxWidth: .infinity, minHeight: 52)
                                .buttonStyle(.bordered).accessibilityIdentifier("calculator.key." + key)
                        }
                    }
                    HStack(spacing: 12) {
                        Button("清除") { expression = "" }.accessibilityIdentifier("calculator.clear")
                        Spacer()
                        Button(")") { expression += ")" }.accessibilityLabel("右括号")
                        Spacer()
                        Button { if !expression.isEmpty { expression.removeLast() } } label: { Label("退格", systemImage: "delete.left") }
                    }.buttonStyle(.bordered)
                    Button("使用计算结果") {
                        if case .success(let value) = evaluation, value.money.minorUnits > 0 {
                            expression = value.money.decimalString
                            dismiss()
                        }
                    }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                        .disabled(!canUseResult).accessibilityIdentifier("calculator.use")
                }.padding(24)
            }
            .navigationTitle("金额计算器").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回记账") { dismiss() } } }
        }
    }
    private var canUseResult: Bool {
        if case .success(let value) = evaluation { return value.money.minorUnits > 0 }
        return false
    }
}
