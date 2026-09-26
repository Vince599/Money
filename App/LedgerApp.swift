import SwiftUI

@main
struct LedgerApp: App {
    @State private var model = LedgerAppModel()
    var body: some Scene {
        WindowGroup { LedgerRootView(model: model).task { await model.start() } }
    }
}
