import XCTest

/// Part B: a guard against basic regressions on the critical screens. These are
/// deliberately shallow — the multi-participant privacy proof lives in the domain
/// tests, which do not depend on the UI at all.
final class CriticalScreensUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func test01_welcomeOffersCreateAndJoin() {
        app.launch()
        XCTAssertTrue(app.buttons["Create Event"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Join Event"].exists)
        captureScreenshot(named: "welcome")
    }

    func test02_createEventShowsInviteCodeAndQR() {
        app.launch()
        let code = createEvent(named: "UI smoke event", as: "Alice", captureForm: true)
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(app.images["inviteQRCode"].exists, "the QR code renders next to the invite code")
        captureScreenshot(named: "invite-code-and-qr")
    }

    func test03_joinWithManualCodeSucceeds() {
        app.launch()
        let code = createEvent(named: "UI join event", as: "Alice")

        app.terminate()
        app.launchArguments = ["-AIKanjiResetSession"]
        app.launch()
        app.buttons["Join Event"].tap()
        let field = app.textFields["6-character code"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText(code)
        app.textFields["Your name"].tap()
        app.textFields["Your name"].typeText("Bob")
        app.buttons["Join Event"].tap()

        XCTAssertTrue(
            app.buttons["Continue"].waitForExistence(timeout: 30),
            "joining with a manually typed code lands on the event"
        )
    }

    func test04_submittedConstraintReachesTheGroupFeed() {
        app.launch()
        _ = createEvent(named: "UI feed event", as: "Alice")
        app.buttons["Continue"].tap()

        XCTAssertTrue(app.buttons["Budget"].waitForExistence(timeout: 20))
        captureScreenshot(named: "constraint-entry")
        app.buttons["Budget"].tap()
        app.buttons["next-MUST"].tap()

        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 30), "the parse-confirmation sheet is presented")
        save.tap()

        XCTAssertTrue(
            waitUntil(timeout: 20) { !save.exists },
            "the parse-confirmation sheet dismisses after saving"
        )
        app.buttons["Group"].tap()
        let empty = app.staticTexts["No shared requirements yet."]
        XCTAssertTrue(
            waitUntil(timeout: 30) { !empty.exists && app.cells.count > 0 },
            "the submitted requirement shows up in the group feed"
        )
        captureScreenshot(named: "group-activity-feed")
    }

    // MARK: - Helpers

    /// Drives WelcomeView → CreateEventView and returns the generated invite code.
    private func createEvent(
        named name: String,
        as displayName: String,
        captureForm: Bool = false
    ) -> String {
        app.buttons["Create Event"].tap()

        let eventName = app.textFields["Event name"]
        XCTAssertTrue(eventName.waitForExistence(timeout: 20))
        if captureForm {
            captureScreenshot(named: "create-event-form")
        }
        eventName.tap()
        eventName.typeText(name)

        let yourName = app.textFields["Your name"]
        yourName.tap()
        yourName.typeText(displayName)

        app.buttons["Create Event"].firstMatch.tap()

        let code = app.staticTexts["inviteCode"]
        if !code.waitForExistence(timeout: 30) {
            let dump = XCTAttachment(string: app.debugDescription)
            dump.lifetime = .keepAlways
            add(dump)
            XCTFail("no invite code after creating the event; screen was:\n\(app.debugDescription)")
        }
        return code.label
    }

    private func captureScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "poll")], timeout: 0.5)
        }
        return condition()
    }
}
