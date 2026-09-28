import XCTest

@MainActor
final class LedgerUITests: XCTestCase {
    private let app = XCUIApplication()

    func testImportPartialCommitFilterPersistenceAndUndo() throws {
        continueAfterFailure = false
        // Setup is a synthetic CSV parsed by the production repository in a UUID-scoped database.
        // This test starts at draft review; it does not claim to exercise the system file picker.
        app.launchArguments = ["-ledger-ui-test-store", UUID().uuidString, "-ledger-ui-test-import-draft"]
        app.launch()
        tap(app.tabBars.buttons["账户"])
        tap(element("accounts.add"))
        replace(app.textFields["account.name"], with: "Import Wallet")
        replace(app.textFields["account.opening"], with: "100.00")
        tap(element("account.save"))
        wait(app.textFields["account.name"], for: "exists == false")
        let account = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "account.row.")).firstMatch
        assertText(account, contains: "100.00 CNY")
        let accountID = account.identifier
        let accountUUID = String(accountID.dropFirst("account.row.".count)).lowercased()
        openImportBatch()
        assertText(element("import.summary"), contains: "待处理 2")
        let lunch = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "import.row.", "Imported Lunch")).firstMatch
        tap(lunch, scrolling: foregroundList)
        tap(element("import.row.account"))
        tap(app.buttons["Import Wallet"])
        tap(element("import.row.category"))
        tap(app.buttons["餐饮 / 正餐"])
        tap(element("import.row.save"), scrolling: foregroundList)
        wait(element("import.row.save"), for: "exists == false")
        revealImportTop()
        tap(element("import.selectReady"))
        // Changing the filter must clear selection, even if the same ready row still matches.
        replace(app.textFields["import.filter.keyword"], with: "Imported")
        app.textFields["import.filter.keyword"].typeText("\n")
        wait(app.keyboards.firstMatch, for: "exists == false")
        let selection = element("import.selectionSummary")
        tap(element("import.filter.state"))
        tap(app.buttons["待处理"])
        wait(selection, for: "label CONTAINS '匹配 1 / 2 行' AND label CONTAINS '已选 0 行'")
        tap(element("import.filter.clear"))
        revealImportTop()
        tap(element("import.selectReady"))
        tap(element("import.preview"), scrolling: foregroundList)
        assertText(element("import.effect.after." + accountUUID), contains: "79.90 CNY")
        screenshot("13-import-partial-preview")
        tap(element("import.confirm.cancel"))
        wait(element("import.confirm"), for: "exists == false")
        revealImportTop()
        assertText(element("import.summary"), contains: "已导入 0")
        assertText(element("import.summary"), contains: "待处理 2")
        tap(element("import.preview"), scrolling: foregroundList)
        tap(element("import.confirm"), scrolling: foregroundList)
        wait(element("import.confirm"), for: "exists == false")

        app.terminate(); app.launch()
        tap(app.tabBars.buttons["账户"])
        assertText(element(accountID), contains: "79.90 CNY")
        tap(app.tabBars.buttons["流水"])
        let entries = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "entry.row."))
        wait(entries, count: 1)
        assertText(entries.firstMatch, contains: "Imported Lunch")
        assertText(entries.firstMatch, contains: "−20.10 CNY")
        tap(element("history.filter"))
        tap(element("filter.importSource"), scrolling: foregroundList)
        tap(app.buttons["有导入来源"])
        tap(element("filter.importNamespace"))
        tap(app.buttons["UI synthetic source"])
        tap(element("filter.apply"))
        wait(element("filter.apply"), for: "exists == false")
        wait(entries, count: 1)
        assertText(entries.firstMatch, contains: "Imported Lunch")
        screenshot("17-history-import-source-filter")
        tap(element("history.filter"))
        tap(element("filter.importSource"), scrolling: foregroundList)
        tap(app.buttons["无导入来源"])
        XCTAssertFalse(element("filter.importNamespace").exists)
        tap(element("filter.apply"))
        wait(element("filter.apply"), for: "exists == false")
        wait(element("history.empty"), for: "exists == true")
        wait(entries, count: 0)
        tap(element("history.clear"))
        wait(entries, count: 1)
        openImportBatch()
        assertText(element("import.summary"), contains: "已导入 1")
        assertText(element("import.summary"), contains: "待处理 1")
        screenshot("14-import-partial-after-relaunch")
        tap(element("import.undo"), scrolling: foregroundList)
        assertText(element("import.undo.effect." + accountUUID), contains: "79.90 → 100.00 CNY")
        screenshot("15-import-undo-impact")
        tap(element("import.undo.execute"), scrolling: foregroundList)
        tap(app.buttons["确认撤销本批"])
        wait(element("import.undo.execute"), for: "exists == false")

        app.terminate(); app.launch()
        tap(app.tabBars.buttons["账户"])
        assertText(element(accountID), contains: "100.00 CNY")
        tap(app.tabBars.buttons["流水"])
        wait(app.staticTexts["还没有流水"], for: "exists == true")
        wait(entries, count: 0)
        openImportBatch()
        assertText(element("import.summary"), contains: "已撤销 1")
        assertText(element("import.summary"), contains: "原未处理 1")
        XCTAssertFalse(element("import.selectReady").exists)
        XCTAssertFalse(element("import.preview").exists)
        screenshot("16-import-reverted-history")
    }

    private func openImportBatch() {
        tap(app.tabBars.buttons["账户"])
        tap(element("accounts.settings"))
        tap(element("settings.import"))
        let batches = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "import.batch."))
        wait(batches, count: 1)
        tap(batches.firstMatch, scrolling: foregroundList)
        wait(element("import.summary"), for: "exists == true")
    }

    private func revealImportTop() {
        let target = element("import.selectReady")
        let list = foregroundList
        for _ in 0..<6 {
            if target.exists && target.isHittable { break }
            list.swipeDown()
        }
        wait(target, for: "exists == true AND enabled == true AND hittable == true")
    }

    func testTagsAndProjectPersistAndFilterAfterProjectArchive() throws {
        continueAfterFailure = false
        app.launchArguments = ["-ledger-ui-test-store", UUID().uuidString]
        app.launch()
        tap(app.tabBars.buttons["账户"])
        tap(element("accounts.add"))
        replace(app.textFields["account.name"], with: "Labels Wallet")
        replace(app.textFields["account.opening"], with: "100.00")
        tap(element("account.save"))
        wait(app.textFields["account.name"], for: "exists == false")
        tap(element("accounts.settings"))
        tap(element("settings.tags"))
        tap(element("tag.add"))
        replace(app.textFields["label.name"], with: "Travel")
        tap(element("label.save"))
        wait(app.textFields["label.name"], for: "exists == false")
        let tag = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tag.row.")).firstMatch
        assertText(tag, contains: "Travel")
        let tagID = String(tag.identifier.dropFirst("tag.row.".count))
        tap(app.navigationBars["标签管理"].buttons["BackButton"])
        tap(element("settings.projects"))
        tap(element("project.add"))
        replace(app.textFields["label.name"], with: "Shanghai")
        tap(element("label.save"))
        wait(app.textFields["label.name"], for: "exists == false")
        let project = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "project.row.")).firstMatch
        assertText(project, contains: "Shanghai")
        let projectID = project.identifier
        tap(app.navigationBars["项目管理"].buttons["BackButton"])
        tap(element("settings.done"))
        tap(app.tabBars.buttons["首页"])
        tap(element("entry.add"))
        replace(app.textFields["entry.amount"], with: "20.10")
        tap(element("entry.category"))
        tap(app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label == %@",
            "entry.category.option.00000000-0000-4000-8000-000000000011", "餐饮 / 正餐")).firstMatch)
        tap(app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "entry.more", "更多信息")).firstMatch)
        tap(element("entry.labels"))
        let selectedTag = app.switches["entry.tag." + tagID]
        wait(selectedTag, for: "exists == true AND enabled == true AND hittable == true")
        selectedTag.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        wait(selectedTag, for: "value == '1'")
        tap(element("entry.project"))
        tap(app.buttons["Shanghai"])
        tap(element("entry.labels.done"))
        assertText(element("entry.labels"), contains: "Shanghai")
        assertText(element("entry.labels"), contains: "1 个标签")
        saveEntry()
        wait(app.textFields["entry.amount"], for: "exists == false")
        app.terminate(); app.launch()
        tap(app.tabBars.buttons["账户"])
        tap(element("accounts.settings"))
        tap(element("settings.projects"))
        tap(element(projectID))
        let archived = app.switches["label.unavailable"]
        wait(archived, for: "exists == true AND enabled == true AND hittable == true")
        archived.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        wait(archived, for: "value == '1'")
        tap(element("label.save"))
        wait(app.textFields["label.name"], for: "exists == false")
        assertText(element(projectID), contains: "已归档")
        tap(app.navigationBars["项目管理"].buttons["BackButton"])
        tap(element("settings.done"))
        tap(app.tabBars.buttons["流水"])
        tap(element("history.filter"))
        tap(element("filter.project"))
        tap(app.buttons["Shanghai（已归档）"])
        let filteredTag = app.switches["filter.tag." + tagID]
        wait(filteredTag, for: "exists == true AND enabled == true AND hittable == true")
        filteredTag.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        wait(filteredTag, for: "value == '1'")
        tap(element("filter.apply"))
        wait(element("filter.apply"), for: "exists == false")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "entry.row."))
        wait(rows, count: 1)
        assertText(rows.firstMatch, contains: "Shanghai")
        assertText(rows.firstMatch, contains: "#Travel")
        screenshot("12-tags-project-filter-after-archive")
    }

    func testCategoryIconSearchCancelSaveRelaunchAndRestoreDefault() throws {
        continueAfterFailure = false
        app.launchArguments = ["-ledger-ui-test-store", UUID().uuidString]
        app.launch()
        openMealCategory()
        let icon = element("category.edit.icon")
        assertText(icon, contains: "餐具")
        tap(icon)
        replace(app.textFields["category.icon.search"], with: "coffee")
        tap(element("category.icon.option.cup.and.saucer"))
        assertText(element("category.icon.preview"), contains: "咖啡杯")
        screenshot("10-category-icon-search-preview")
        tap(element("category.icon.cancel"))
        assertText(icon, contains: "餐具")
        tap(icon)
        replace(app.textFields["category.icon.search"], with: "coffee")
        tap(element("category.icon.option.cup.and.saucer"))
        tap(element("category.icon.use"))
        assertText(icon, contains: "咖啡杯")
        tap(element("category.edit.save"))
        wait(app.textFields["category.edit.name"], for: "exists == false")

        app.terminate(); app.launch()
        openMealCategory()
        assertText(element("category.edit.icon"), contains: "咖啡杯")
        screenshot("11-category-icon-after-relaunch")
        tap(element("category.edit.resetIcon"))
        assertText(element("category.edit.icon"), contains: "餐具")
        // Cancelling the editor discards even an explicit restore-default action.
        tap(element("category.edit.cancel"))
        tap(element("category.row.00000000-0000-4000-8000-000000000011"))
        assertText(element("category.edit.icon"), contains: "咖啡杯")
        tap(element("category.edit.resetIcon"))
        tap(element("category.edit.save"))
        wait(app.textFields["category.edit.name"], for: "exists == false")
        tap(element("category.row.00000000-0000-4000-8000-000000000011"))
        assertText(element("category.edit.icon"), contains: "餐具")
    }

    private func openMealCategory() {
        tap(app.tabBars.buttons["账户"])
        tap(element("accounts.settings"))
        tap(element("settings.categories"))
        tap(element("category.row.00000000-0000-4000-8000-000000000011"))
    }

    func testRefundShowsOriginalAndNetCostThenRequiresExplicitGroupDeletion() throws {
        continueAfterFailure = false
        app.launchArguments = ["-ledger-ui-test-store", UUID().uuidString]
        app.launch()
        tap(app.tabBars.buttons["账户"])
        tap(element("accounts.add"))
        replace(app.textFields["account.name"], with: "Recovery Wallet")
        replace(app.textFields["account.opening"], with: "2000.00")
        tap(element("account.save"))
        wait(app.textFields["account.name"], for: "exists == false")
        tap(app.tabBars.buttons["首页"])
        tap(element("entry.add"))
        replace(app.textFields["entry.amount"], with: "1000.00")
        tap(element("entry.category"))
        tap(app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label == %@",
            "entry.category.option.00000000-0000-4000-8000-000000000011", "餐饮 / 正餐")).firstMatch)
        saveEntry()
        wait(app.textFields["entry.amount"], for: "exists == false")
        tap(app.tabBars.buttons["流水"])
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "entry.row."))
        wait(rows, count: 1)
        let originalID = rows.firstMatch.identifier
        tap(rows.firstMatch)
        tap(element("entry.refund"), scrolling: foregroundList)
        replace(app.textFields["entry.amount"], with: "200.00")
        saveEntry()
        wait(app.textFields["entry.amount"], for: "exists == false")
        // The detail can expand beyond its initial medium height as associations appear.
        tap(element("entry.detail.done"))
        wait(rows, count: 2)
        assertText(element(originalID), contains: "−1000.00 CNY")
        assertText(element(originalID), contains: "已回收")
        screenshot("07-recovery-history-original-amount")
        tap(element("history.filter"))
        tap(element("filter.recoveryLink"), scrolling: foregroundList)
        tap(app.buttons["有关联"])
        tap(element("filter.apply"))
        wait(element("filter.apply"), for: "exists == false")
        wait(rows, count: 2)
        tap(element("history.filter"))
        tap(element("filter.recoveryLink"), scrolling: foregroundList)
        tap(app.buttons["无关联"])
        tap(element("filter.apply"))
        wait(element("filter.apply"), for: "exists == false")
        XCTAssertTrue(element("history.empty").waitForExistence(timeout: 15))
        wait(rows, count: 0)
        tap(element("history.clear"))
        wait(rows, count: 2)
        tap(element(originalID))
        let net = element("entry.netCost")
        for _ in 0..<5 where !net.exists || !net.isHittable { foregroundList.swipeUp() }
        assertText(net, contains: "800.00 CNY")
        screenshot("08-recovery-net-cost")
        tap(app.buttons["删除"], scrolling: foregroundList)
        let execute = element("delete.execute")
        for _ in 0..<5 where !execute.exists || !execute.isHittable { foregroundList.swipeUp() }
        XCTAssertTrue(execute.waitForExistence(timeout: 15))
        XCTAssertFalse(execute.isEnabled)
        let group = app.switches["delete.group"]
        wait(group, for: "exists == true AND enabled == true AND hittable == true")
        // The outer AX switch spans its text row; the native control is at the trailing edge.
        group.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        wait(group, for: "value == '1'")
        screenshot("09-recovery-delete-impact")
        tap(execute)
        tap(app.buttons["确认删除"])
        wait(rows, count: 0)
        tap(app.tabBars.buttons["账户"])
        let account = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "account.row.")).firstMatch
        assertText(account, contains: "2000.00 CNY")
    }

    func testAccountTemplateDefaultsAndSavedAppearanceSurviveRelaunch() throws {
        continueAfterFailure = false
        app.launchArguments = ["-ledger-ui-test-store", UUID().uuidString]
        app.launch()
        tap(app.tabBars.buttons["账户"])
        tap(element("accounts.add"))
        tap(element("account.template"))
        replace(app.searchFields.firstMatch, with: "10086")
        app.searchFields.firstMatch.typeText("\n")
        wait(app.keyboards.firstMatch, for: "exists == false")
        tap(element("account.template.option.cn.china-mobile.balance"))
        XCTAssertEqual(app.textFields["account.name"].value as? String, "中国移动话费")
        let included = app.switches["account.included"]
        XCTAssertEqual(included.value as? String, "0")
        wait(included, for: "exists == true AND enabled == true AND hittable == true")
        included.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        wait(included, for: "value == '1'")
        replace(app.textFields["account.name"], with: "自定义话费账户")
        tap(element("account.template"))
        replace(app.searchFields.firstMatch, with: "10010")
        app.searchFields.firstMatch.typeText("\n")
        wait(app.keyboards.firstMatch, for: "exists == false")
        tap(element("account.template.option.cn.china-unicom.balance"))
        XCTAssertEqual(app.textFields["account.name"].value as? String, "自定义话费账户")
        XCTAssertEqual(included.value as? String, "1")
        replace(app.textFields["account.opening"], with: "50.00")
        tap(element("account.save"))
        wait(app.textFields["account.name"], for: "exists == false")
        let account = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "account.row.")).firstMatch
        assertText(account, contains: "自定义话费账户")
        assertText(account, contains: "计入总资产")
        let accountID = account.identifier

        app.terminate()
        app.launch()
        tap(app.tabBars.buttons["账户"])
        tap(element(accountID))
        tap(app.buttons["编辑账户"])
        assertText(element("account.edit.template"), contains: "中国联通话费")
        screenshot("06-account-template-after-relaunch")
    }

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
        saveEntry()
        wait(app.textFields["entry.amount"], for: "exists == false")
        tap(app.tabBars.buttons["流水"])
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "entry.row."))
        assertText(rows.firstMatch, contains: "Lunch")
        let originalID = rows.firstMatch.identifier
        tap(rows.firstMatch)
        // A medium sheet lazily creates the action rows after its details are scrolled.
        let details = foregroundList
        tap(element("entry.copy"), scrolling: details)
        XCTAssertTrue(app.textFields["entry.amount"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.textFields["entry.amount"].value as? String, "20.10")
        saveEntry()
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
        tap(element("filter.currency"), scrolling: foregroundList)
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
        saveEntry()
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
        wait(rows, count: 1)
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
    private func saveEntry() {
        if app.keyboards.firstMatch.exists {
            tap(app.buttons["entry.keyboard.done"])
            wait(app.keyboards.firstMatch, for: "exists == false")
        }
        // App-wide swipes may land on the keyboard or a presenting list.
        tap(element("entry.save"), scrolling: foregroundList)
    }
    private var foregroundList: XCUIElement {
        // Modal lists follow their presenting list in the captured AX hierarchy.
        // Do not require a lazily created offscreen action to locate its scroll container.
        let lists = app.collectionViews
        XCTAssertTrue(lists.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        return lists.element(boundBy: max(0, lists.count - 1))
    }
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
        // Cloud simulator AX snapshots can themselves take over 15 seconds under load.
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 30), .completed, app.debugDescription)
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
        for _ in 0..<5 {
            if target.isHittable { break }
            app.swipeUp()
        }
        wait(target, for: "enabled == true AND hittable == true")
        target.tap()
    }
    private func replace(_ field: XCUIElement, with text: String) {
        tap(field)
        let displayed = field.value as? String ?? ""
        let previous = displayed == field.placeholderValue ? "" : displayed
        // Empty inputs already have the insertion point. A second coordinate tap can
        // hit the keyboard toolbar while the form moves to accommodate the keyboard.
        if !previous.isEmpty {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + text)
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            field.value as? String == text
        }, object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 15), .completed, field.debugDescription)
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
