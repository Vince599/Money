import SwiftUI
import UIKit
import LedgerCore

/// Local presentation only. Account names never determine brand identity.
struct AccountIconView: View {
    let iconID: String?
    let kind: AccountKind

    var body: some View {
        let icon = iconID.flatMap { AccountTemplateCatalog.icon(id: $0) }
        Group {
            if let assetName = icon?.assetName, let image = UIImage(named: assetName) {
                Image(uiImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .padding(5)
                    .frame(width: 36, height: 36)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: icon?.fallbackSymbol ?? fallbackSymbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }
        }
        .accessibilityHidden(true)
    }

    private var fallbackSymbol: String {
        switch kind {
        case .wallet: "wallet.bifold"
        case .bank: "building.columns"
        case .cash: "banknote"
        case .creditCard, .storedValue: "creditcard"
        case .brokerage: "chart.line.uptrend.xyaxis"
        case .loan: "building.columns"
        }
    }
}
