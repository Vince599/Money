import XCTest

@MainActor
final class LedgerUITests: XCTestCase {
    private let app = XCUIApplication()

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
    private func wait(_ target: XCUIElement, for predicate: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
    }
    private func tap(_ target: XCUIElement) {
        XCTAssertTrue(target.waitForExistence(timeout: 15))
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
