import XCTest

/// End-to-end UI tests of the Mac app against the isolated TEST NEBULA (scripts/test_instance.py in the NEBULA_v1
/// server repository; every "scripts/test_instance.py" below means that file).
/// This Mac (a Mac mini) has no Touch ID, and the system password prompt must never be automated: DEBUG builds get
/// `-NEBULAUITestSkipPresence`, which skips only the local LocalAuthentication prompt (never compiled into Release).
/// Everything else — device keys, signatures, the server's checks, the vault's device key — is real.
final class NEBULAMacUITests: XCTestCase {
    var app: XCUIApplication!
    let env = ProcessInfo.processInfo.environment

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-NEBULAUITestReset", "-NEBULAUITestSkipPresence", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func waitFor(_ e: XCUIElement, _ timeout: TimeInterval = 20, _ msg: String = "") {
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "missing: \(msg.isEmpty ? e.debugDescription : msg)")
    }

    func testEndToEnd() throws {
        guard let link = env["NEBULA_LINK"], let vaultPass = env["NEBULA_VAULT"] else {
            throw XCTSkip("needs the E2E server (TEST_RUNNER_NEBULA_LINK / TEST_RUNNER_NEBULA_VAULT)")
        }
        app.launch()
        let window = app.windows.firstMatch
        waitFor(window.staticTexts["NEBULA"])
        let field = window.textFields.element(boundBy: 0)
        field.click()
        field.typeText(link)
        window.buttons["Pair"].click()
        let sidebarChats = window.outlines.staticTexts["Chats"].exists ? window.outlines.staticTexts["Chats"]
            : window.staticTexts["Chats"]
        waitFor(sidebarChats, 60, "connected sidebar")
        shot("mac-01-connected")

        // chat
        // the fixture conversation of scripts/test_instance.py (CONVERSATION_TITLE, English only)
        let conv = window.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "E2E conversation")).firstMatch
        waitFor(conv, 20)
        conv.click()
        let composer = window.textViews.firstMatch.exists ? window.textViews.firstMatch : window.textFields.firstMatch
        waitFor(composer)
        composer.click()
        composer.typeText("Hello from the Mac \(Int(Date().timeIntervalSince1970) % 100000)")
        window.buttons["Send"].click()
        // the streamed sample answer of scripts/test_instance.py ("Done – I changed nothing.")
        waitFor(window.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "I changed nothing")).firstMatch,
                60, "streamed answer")
        shot("mac-02-conversation")

        // vault: passphrase once (first activation), then no second password
        window.staticTexts["Vault"].click()
        waitFor(window.staticTexts["The vault is locked"], 20)
        window.buttons["Unlock"].click()
        let pass = app.secureTextFields["Vault password"]
        waitFor(pass, 20)
        pass.click()
        pass.typeText(vaultPass)
        app.buttons["Continue"].click()
        waitFor(window.staticTexts["The vault is unlocked"], 40)
        window.buttons["Lock"].click()
        waitFor(window.staticTexts["The vault is locked"], 20)
        window.buttons["Unlock"].click()
        XCTAssertFalse(app.secureTextFields["Vault password"].waitForExistence(timeout: 4))
        waitFor(window.staticTexts["The vault is unlocked"], 40)
        shot("mac-03-vault")

        // Live Desktop in its own window
        window.staticTexts["Agents"].click()
        waitFor(window.staticTexts["E2E Agent"], 20)
        window.staticTexts["E2E Agent"].click()
        app.typeKey("d", modifierFlags: [.command, .shift])
        let take = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Take control'")).firstMatch
        waitFor(take, 30, "Live Desktop window")
        sleep(2)
        take.click()
        sleep(2)
        let desktopWindow = app.windows.element(boundBy: 0)
        desktopWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        sleep(1)
        shot("mac-04-live-desktop")
        let back = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Give back control'")).firstMatch
        if back.exists { back.click() }
    }

    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) { app.launch() }
    }
}
