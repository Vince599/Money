import XCTest

@MainActor
final class LedgerUITests: XCTestCase {
    private let app = XCUIApplication()

    func testCalculatorCopyAndSearchFilters() throws {
        continueAfterFailure = false
        app.launchArguments = ["-ledger-ui-test-store", UUID().uuidString]
        app.launch()
        tap(app.tabBars.buttons["账户"])
        tap(element("accounts.add"))
        replace(app.textFields["account.name"], with: "Feature Wallet")
        replace(app.textFields["account.opening"], with: "100.00")
        tap(element("account.save"))
        wait(app.textFields["account.name"], for: "exists == false")
        tap(app.tabBars.buttons["首页"])
        tap(element("entry.add"))
        tap(element("entry.calculator"))
        replace(element("calculator.expression"), with: "10+5.05*2")
        assertText(element("calculator.result"), contains: "20.10 CNY")
        tap(element("calculator.keyboard.done"))
        screenshot("04-calculator-priority")
        tap(element("calculator.use"))
        wait(element("calculator.expression"), for: "exists == false")
        XCTAssertEqual(app.textFields["entry.amount"].value as? String, "20.10")
        tap(element("entry.category"))
        tap(app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label == %@",
            "entry.category.option.00000000-0000-4000-8000-000000000011", "餐饮 / 正餐")).firstMatch)
        tap(app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "entry.more", "更多信息")).firstMatch)
        // Form lazily creates expanded rows; the title may initially sit below the viewport.
        if !app.textFields["entry.title"].waitForExistence(timeout: 2) { app.swipeUp() }
        replace(app.textFields["entry.title"], with: "Lunch")
        tap(element("entry.save"))
        wait(app.textFields["entry.amount"], for: "exists == false")
        tap(app.tabBars.buttons["流水"])
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "entry.row."))
        assertText(rows.firstMatch, contains: "Lunch")
        let originalID = rows.firstMatch.identifier
        tap(rows.firstMatch)
        // A medium sheet lazily creates the action rows after its details are scrolled.
        let details = app.collectionViews.containing(.button, identifier: "编辑").firstMatch
        tap(element("entry.copy"), scrolling: details)
        XCTAssertTrue(app.textFields["entry.amount"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.textFields["entry.amount"].value as? String, "20.10")
        tap(element("entry.save"))
        wait(app.textFields["entry.amount"], for: "exists == false")
        tap(element("entry.detail.done"))
        wait(rows, count: 2)
        XCTAssertEqual(Set(rows.allElementsBoundByIndex.map(\.identifier)).count, 2)
        XCTAssertTrue(element(originalID).exists)
        let search = app.searchFields.firstMatch
        replace(search, with: "lunch")
        wait(rows, count: 2)
        screenshot("05-search-copied-entries")
        replace(search, with: "no-such-title")
        wait(rows, count: 0)
        XCTAssertTrue(element("history.empty").waitForExistence(timeout: 15))
        replace(search, with: "Lunch")
        wait(rows, count: 2)
        if app.keyboards.buttons["Search"].exists { app.keyboards.buttons["Search"].tap() }
        if app.keyboards.buttons["搜索"].exists { app.keyboards.buttons["搜索"].tap() }
        leaveHistorySearch()
        tap(element("history.filter"))
        tap(element("filter.currency"))
        tap(app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label == %@",
            "filter.currency.option.CNY", "CNY")).firstMatch)
        assertText(element("filter.currency"), contains: "CNY")
        replace(app.textFields["filter.minimum"], with: "20.11")
        tap(element("filter.apply"))
        wait(element("filter.apply"), for: "exists == false")
        wait(rows, count: 0)
        tap(element("history.clear"))
        wait(rows, count: 2)
        tap(app.tabBars.buttons["账户"])
        let account = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "account.row.")).firstMatch
        assertText(account, contains: "59.80 CNY")
    }

    func testCreateExpensePersistsAfterRelaunch() throws {
        continueAfterFailure = false
        app.launchArguments = ["-ledger-ui-test-store", UUID().uuidString]
        app.launch()
        tap(app.tabBars.buttons["账户"])
        tap(element("accounts.add"))
        XCTAssertTrue(element("account.makeDefault").waitForExistence(timeout: 15))
        XCTAssertEqual(element("account.makeDefault").value as? String, "1")
        replace(app.textFields["account.name"], with: "Smoke Wallet")
        replace(app.textFields["account.opening"], with: "100.00")
        tap(element("account.save"))
        wait(app.textFields["account.name"], for: "exists == false")
        let account = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "account.row.")).firstMatch
        assertText(account, contains: "100.00 CNY")
        let accountID = account.identifier
        tap(app.tabBars.buttons["首页"])
        tap(element("entry.add"))
        assertText(element("entry.account"), contains: "Smoke Wallet")
        assertText(element("entry.subject"), contains: "MPC")
        XCTAssertTrue(app.segmentedControls["entry.kind"].buttons["支出"].isSelected)
        replace(app.textFields["entry.amount"], with: "20.10")
        tap(element("entry.category"))
        tap(app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label == %@",
            "entry.category.option.00000000-0000-4000-8000-000000000011", "餐饮 / 正餐")).firstMatch)
        tap(element("entry.save"))
        wait(app.textFields["entry.amount"], for: "exists == false")
        tap(app.tabBars.buttons["流水"])
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "entry.row."))
        assertText(rows.firstMatch, contains: "正餐")
        assertText(rows.firstMatch, contains: "−20.10 CNY")
        XCTAssertEqual(rows.count, 1)
        let entryID = rows.firstMatch.identifier
        XCTAssertNotNil(UUID(uuidString: String(entryID.dropFirst("entry.row.".count))))
        tap(app.tabBars.buttons["账户"])
        assertText(element(accountID), contains: "79.90 CNY")
        app.terminate()
        app.launch() // Reuses the same isolated store argument; no reinstall or seeded data.
        assertText(element(entryID), contains: "−20.10 CNY")
        assertText(element(entryID), contains: "MPC")
        screenshot("01-home-after-relaunch")
        tap(app.tabBars.buttons["流水"])
        XCTAssertEqual(rows.count, 1)
        assertText(element(entryID), contains: "正餐")
        tap(app.tabBars.buttons["账户"])
        assertText(element(accountID), contains: "79.90 CNY")
        assertText(element(accountID), contains: "默认账户")
        screenshot("02-accounts-after-relaunch")
        tap(element("accounts.settings"))
        tap(element("settings.backup"))
        wait(element("backup.export"), for: "exists == true AND enabled == true AND hittable == true")
        wait(element("backup.import"), for: "exists == true AND enabled == true AND hittable == true")
        screenshot("03-backup-entry-points") // File pickers and restore execution are outside this smoke test.
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func leaveHistorySearch() {
        // Submit dismisses the keyboard but may keep native search active and hide the toolbar.
        // Search behaviour is verified above; cancel it before the independent amount-filter check.
        let cancel = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "取消", "Cancel")).firstMatch
        let filter = element("history.filter")
        func searchCloseButton() -> XCUIElement? {
            if cancel.exists && cancel.isHittable { return cancel }
            let search = app.searchFields.firstMatch
            guard search.exists else { return nil }
            let frame = search.frame
            // The iOS 26 screenshot shows one circular close button immediately outside
            // the search field. Locate that button without guessing its localized AX label.
            // The clear-text button is inside the field and is deliberately excluded.
            let candidates = app.buttons.allElementsBoundByIndex.filter { button in
                let bounds = button.frame
                return bounds.midX > frame.maxX
                    && abs(bounds.midY - frame.midY) < frame.height / 2
                    && button.isHittable
            }
            return candidates.count == 1 ? candidates.first : nil
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (filter.exists && filter.isHittable) || searchCloseButton() != nil
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, app.debugDescription)
        if let close = searchCloseButton() { close.tap() }
        wait(filter, for: "exists == true AND enabled == true AND hittable == true")
    }
    private func wait(_ target: XCUIElement, for predicate: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed, app.debugDescription)
    }
    private func wait(_ query: XCUIElementQuery, count: Int) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in query.count == count }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed, app.debugDescription)
    }
    private func tap(_ target: XCUIElement, scrolling scrollView: XCUIElement? = nil) {
        if let scrollView {
            XCTAssertTrue(scrollView.waitForExistence(timeout: 15), app.debugDescription)
            for _ in 0..<5 {
                if target.exists && target.isHittable { break }
                scrollView.swipeUp()
            }
        }
        XCTAssertTrue(target.waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<5 where !target.isHittable { app.swipeUp() }
        wait(target, for: "enabled == true AND hittable == true")
        target.tap()
    }
    private func replace(_ field: XCUIElement, with text: String) {
        tap(field)
        let previous = field.value as? String ?? ""
        // Tap beyond these short values to place the caret at the end before deleting each character.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + text)
        XCTAssertEqual(field.value as? String, text)
    }
    private func assertText(_ target: XCUIElement, contains text: String) {
        XCTAssertTrue(target.waitForExistence(timeout: 15))
        XCTAssertTrue((target.label + " " + (target.value as? String ?? "")).contains(text), target.debugDescription)
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
