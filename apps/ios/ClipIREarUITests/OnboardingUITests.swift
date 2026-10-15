import XCTest

/// UI tests on the single main screen (HomeView): onboarding, starting by hand, the field-study setting rule.
final class OnboardingUITests: XCTestCase {
    /// SwiftUI's Menu label fails XCUITest's scroll-to-visible step (kAXErrorCannotComplete); a coordinate tap skips it.
    @MainActor
    private func tapMenuButton(_ app: XCUIApplication) {
        let more = app.buttons["moreMenu"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor
    private func openMenu(_ app: XCUIApplication, _ item: String) {
        tapMenuButton(app)
        let button = app.buttons[item]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "menu item \(item)")
        button.tap()
    }

    /// P8.1: consent → retention → indicator → agree → main screen; shown once; cues off unless turned on.
    @MainActor
    func testOnboardingFlowThenMainScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-earOnboarded", "NO"]
        app.launch()
        let next = app.buttons["onboardingNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Listens, keeps text, not audio"].exists)
        next.tap()
        XCTAssertTrue(app.staticTexts["How long to keep the transcript"].waitForExistence(timeout: 5))
        app.buttons["10 min"].tap()
        XCTAssertTrue(app.buttons["10 min"].isSelected)
        next.tap()
        XCTAssertTrue(app.staticTexts["The orange dot is expected"].waitForExistence(timeout: 5))
        XCTAssertEqual(next.label, "I agree, start using ClipIR Ear")
        next.tap()
        XCTAssertTrue(app.buttons["listenButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Missed something?"].exists)

        app.terminate()  // shown once: a relaunch goes straight to the app
        app.launchArguments = ["-earCues", "NO"]  // the simulator may hold the owner's setting
        app.launch()
        XCTAssertTrue(app.buttons["listenButton"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["onboardingNext"].exists)
        openMenu(app, "Settings")
        XCTAssertTrue(app.switches["cuesToggle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["cuesToggle"].value as? String, "0", "cues toggle reflects the stored setting")
    }

    /// Regression: tapping Start listening by hand (no -earAutostart) crashed in the notification-permission callback.
    @MainActor
    func testStartListeningByHandDoesNotCrash() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-earOnboarded", "YES"]
        app.launch()
        let listen = app.buttons["listenButton"]
        XCTAssertTrue(listen.waitForExistence(timeout: 10))
        listen.tap()
        XCTAssertTrue(app.buttons["pttButton"].waitForExistence(timeout: 10), "listening: the ask button shows")
        XCTAssertEqual(app.state, .runningForeground, "app must survive Start listening")
        openMenu(app, "Stop listening")
        XCTAssertTrue(listen.waitForExistence(timeout: 5))
    }

    /// Field-study build: listening needs a lawful setting (StGB §201); "Somewhere else" never starts, and there is
    /// no Record item.
    @MainActor
    func testFieldStudyRefusesUnconsentedSetting() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-earOnboarded", "YES", "-earFieldStudy", "YES"]
        app.launch()
        let listen = app.buttons["listenButton"]
        XCTAssertTrue(listen.waitForExistence(timeout: 10))
        listen.tap()
        let other = app.buttons["Somewhere else"]
        XCTAssertTrue(other.waitForExistence(timeout: 5), "setting question shown")
        other.tap()
        XCTAssertTrue(listen.exists, "did not start")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Not started'")).firstMatch.exists)
        listen.tap()
        app.buttons["Public talk or lecture"].tap()
        XCTAssertTrue(app.buttons["pttButton"].waitForExistence(timeout: 10), "starts in a public setting")
        tapMenuButton(app)
        XCTAssertTrue(app.buttons["Stop listening"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Record audio"].exists, "no audio recording in the field study")
        app.buttons["Stop listening"].tap()
    }
}
