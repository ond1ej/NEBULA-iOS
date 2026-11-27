import XCTest

/// End-to-end UI tests of the iPhone app against an isolated TEST NEBULA (scripts/test_instance.py in the NEBULA_v1
/// server repository; every "scripts/test_instance.py" below means that file):
/// pairing with a real device key + simulated Face ID, chat with a streamed answer, the vault (first activation with
/// the test passphrase once, then Face ID only, reveal), Live Desktop take/release control, settings.
///
/// The runner passes TEST_RUNNER_NEBULA_LINK (pairing link) and TEST_RUNNER_NEBULA_VAULT (the TEST vault's synthetic
/// passphrase). Face ID prompts are answered by the host script with the simulator's "matching face" notification.
final class NEBULAUITests: XCTestCase {
    var app: XCUIApplication!
    let env = ProcessInfo.processInfo.environment

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-NEBULAUITestReset", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func waitFor(_ e: XCUIElement, _ timeout: TimeInterval = 20, _ msg: String = "") {
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "missing: \(msg.isEmpty ? e.debugDescription : msg)")
    }

    func testWelcomeScreenWithoutServer() throws {
        app.launch()
        waitFor(app.staticTexts["NEBULA"])
        XCTAssertTrue(app.buttons["Scan QR code"].exists)
        let field = app.textFields.element(boundBy: 0)
        field.tap()
        field.typeText("nebula://pair?v=1&u=https%3A%2F%2Fevil.example&p=bad")
        app.buttons["Pair"].tap()
        waitFor(app.staticTexts["This is not a valid NEBULA pairing code."], 5)
        shot("welcome-invalid-link")
    }

    func testEndToEnd() throws {
        guard let link = env["NEBULA_LINK"], let vaultPass = env["NEBULA_VAULT"] else {
            throw XCTSkip("needs the E2E server (TEST_RUNNER_NEBULA_LINK / TEST_RUNNER_NEBULA_VAULT)")
        }
        app.launch()
        // ---- pairing (Face ID once for the confirm key; the TEST server approves automatically)
        waitFor(app.staticTexts["NEBULA"])
        shot("01-welcome")
        let field = app.textFields.element(boundBy: 0)
        field.tap()
        field.typeText(link)
        app.buttons["Pair"].tap()
        let chats = app.tabBars.buttons["Chats"]
        waitFor(chats, 60, "connected app (tab bar)")
        shot("02-chats")

        // ---- chat: send a task, the answer streams in and stays exactly once
        // the fixture conversation of scripts/test_instance.py (CONVERSATION_TITLE, English only)
        let conv = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "E2E conversation")).firstMatch
        waitFor(conv, 20)
        conv.tap()
        let composer = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        waitFor(composer)
        composer.tap()
        let unique = "Test \(Int(Date().timeIntervalSince1970) % 100000): how does it look?"
        composer.typeText(unique)
        app.buttons["Send"].tap()
        let mine = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "You: \(unique)"))
        waitFor(mine.firstMatch, 10, "own message")
        // the streamed sample answer of scripts/test_instance.py ("Done – I changed nothing.")
        let answer = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "I changed nothing")).firstMatch
        waitFor(answer, 60, "streamed answer")
        shot("03-conversation")
        XCTAssertFalse(mine.element(boundBy: 1).exists, "the sent message must appear exactly once")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // ---- vault: first activation = passphrase once + Face ID, afterwards Face ID only
        app.tabBars.buttons["Vault"].tap()
        waitFor(app.staticTexts["The vault is locked"], 20)
        app.buttons["Unlock"].tap()
        let pass = app.secureTextFields["Vault password"]
        waitFor(pass, 20, "first-activation passphrase sheet")
        shot("04-vault-first-activation")
        pass.tap()
        pass.typeText(vaultPass)
        app.buttons["Continue"].tap()
        waitFor(app.staticTexts["The vault is unlocked"], 40)
        shot("05-vault-unlocked")
        app.buttons["Lock"].tap()
        waitFor(app.staticTexts["The vault is locked"], 20)
        app.buttons["Unlock"].tap()
        XCTAssertFalse(app.secureTextFields["Vault password"].waitForExistence(timeout: 4),
                       "after activation the vault must open with Face ID only (no second password)")
        waitFor(app.staticTexts["The vault is unlocked"], 40)
        app.staticTexts["E2E Mail"].tap()
        waitFor(app.buttons["Show password"], 15)
        app.buttons["Show password"].tap()
        waitFor(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'e2e-synthetic-'")).firstMatch, 30,
                "revealed test password")
        shot("06-vault-reveal")
        app.buttons["Done"].tap()

        // ---- Live Desktop: view, take control, click, release
        app.tabBars.buttons["Agents"].tap()
        waitFor(app.staticTexts["E2E Agent"], 20)
        app.staticTexts["E2E Agent"].tap()
        let live = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Live Desktop'")).firstMatch
        waitFor(live, 15)
        live.tap()
        let take = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Take control'")).firstMatch
        waitFor(take, 30, "take control button")
        sleep(2)
        shot("07-live-desktop")
        take.tap()
        sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        sleep(1)
        shot("08-live-desktop-control")
        let release = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Give back control'")).firstMatch
        if release.exists { release.tap() }
        app.buttons["Close"].tap()

        // ---- settings
        app.tabBars.buttons["Settings"].tap()
        waitFor(app.staticTexts["This device"], 10)
        shot("09-settings")
    }

    /// Scroll smoothness (hitches), memory and CPU while flicking through a 600-message conversation with Markdown
    /// and code blocks. Needs the paired app from testEndToEnd and `cmd-seed` on the E2E server.
    func testLongConversationScrolling() throws {
        guard env["NEBULA_LINK"] != nil else { throw XCTSkip("needs the E2E server") }
        app.launchArguments.removeAll { $0 == "-NEBULAUITestReset" }
        app.launch()
        // the seeded conversation of scripts/test_instance.py (LONG_CONVERSATION_TITLE, English only)
        let long = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Long conversation")).firstMatch
        waitFor(long, 30)
        long.tap()
        let list = app.scrollViews.firstMatch
        waitFor(list, 20)
        sleep(2)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTMemoryMetric(application: app),
                          XCTCPUMetric(application: app)], options: options) {
            list.swipeDown(velocity: .fast)
            list.swipeDown(velocity: .fast)
            list.swipeUp(velocity: .fast)
            list.swipeDown(velocity: .fast)
        }
        shot("10-long-conversation")
    }

    /// README screenshots against a real NEBULA (not the synthetic test server): pairs with NEBULA_SCREENSHOT_LINK,
    /// waits up to 3 minutes for the owner to approve the device, then captures the chat list, one agent's
    /// conversation (NEBULA_SCREENSHOT_AGENT), the Activity tab and that agent's Live Desktop. Asserts navigation only.
    func testReadmeScreenshots() throws {
        guard let link = env["NEBULA_SCREENSHOT_LINK"] else { throw XCTSkip("set TEST_RUNNER_NEBULA_SCREENSHOT_LINK") }
        let agent = env["NEBULA_SCREENSHOT_AGENT"] ?? "Analyst"
        app.launch()
        waitFor(app.staticTexts["NEBULA"])
        let field = app.textFields.element(boundBy: 0)
        field.tap()
        field.typeText(link)
        app.buttons["Pair"].tap()
        waitFor(app.tabBars.buttons["Chats"], 180, "connected app (owner approval)")
        sleep(3)
        shot("ios-home")
        let conv = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", agent)).firstMatch
        waitFor(conv, 30, "conversation with \(agent)")
        conv.tap()
        sleep(4)
        shot("ios-conversation")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Activity"].tap()
        sleep(3)
        shot("ios-activity")
        app.tabBars.buttons["Agents"].tap()
        sleep(2)
        shot("ios-agents")
        let row = app.staticTexts[agent]
        waitFor(row, 20)
        row.tap()
        let live = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Live Desktop'")).firstMatch
        waitFor(live, 15)
        live.tap()
        waitFor(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Take control'")).firstMatch, 40)
        sleep(5)
        shot("ios-live-desktop")
        app.buttons["Close"].tap()
    }

    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) { app.launch() }
    }
}
