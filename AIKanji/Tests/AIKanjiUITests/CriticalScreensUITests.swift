import XCTest

final class CriticalScreensUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-AIKanjiResetSession", "-AIKanjiUITestOrigin"]
    }

    func test01_welcomeOffersCreateJoinAndLogin() {
        app.launch()
        XCTAssertTrue(app.buttons["create-event"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["join-event"].exists)
        XCTAssertTrue(app.buttons["login"].exists)
    }

    func test02_createEventOffersOptionalDateOriginInviteQRAndShare() {
        app.launchArguments.append("-AIKanjiUITestCreate")
        app.launch()
        XCTAssertTrue(app.switches["include-date"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["origin-search"].exists)
        let code = createEvent(named: "UI smoke event", as: "Alice")
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(app.images["inviteQRCode"].exists)
        XCTAssertTrue(app.buttons["share-invite"].exists)
        XCTAssertTrue(app.buttons["copy-invite"].exists)
    }

    func test03_joinRequiresPreviewBeforeParticipantForm() {
        app.launchArguments.append("-AIKanjiUITestCreate")
        app.launch()
        let code = createEvent(named: "UI join event", as: "Alice")
        app.terminate()
        app.launchArguments = ["-AIKanjiResetSession", "-AIKanjiUITestOrigin"]
        app.launch()
        XCTAssertTrue(app.buttons["join-event"].waitForExistence(timeout: 20))
        app.buttons["join-event"].tap()
        let field = app.textFields["invite-code"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText(code)
        XCTAssertFalse(app.textFields["join-display-name"].exists)
        app.buttons["preview-event"].tap()
        XCTAssertTrue(app.otherElements["event-preview"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.textFields["join-display-name"].exists)
        XCTAssertTrue(app.buttons["join-origin-search"].exists)
    }

    func test04_structuredPreferenceEditorExposesCriticalIdentifiers() {
        app.launchArguments.append("-AIKanjiUITestCreate")
        app.launch()
        _ = createEvent(named: "UI preference event", as: "Alice")
        app.buttons["continue-event"].tap()
        let add = app.buttons["add-constraint"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        add.tap()
        let categories = ["budget", "cuisine", "allergy", "dietary", "room", "travel_time", "other"]
        for category in categories {
            XCTAssertTrue(app.buttons["constraint-category-\(category)"].waitForExistence(timeout: 5))
        }
        app.buttons["constraint-category-allergy"].tap()
        XCTAssertTrue(app.staticTexts["表示義務 9品目"].exists)
        XCTAssertTrue(app.staticTexts["表示推奨 20品目"].exists)
        XCTAssertTrue(app.buttons["constraint-allergen-shrimp"].exists)
        XCTAssertTrue(app.buttons["constraint-allergen-gelatin"].exists)
        XCTAssertFalse(app.buttons["complete-input"].exists)
        XCTAssertFalse(app.buttons["reopen-input"].exists)
    }

    func test05_eventHomeUsesSimplifiedTabsAndRestoresAfterRelaunch() {
        app.launchArguments.append("-AIKanjiUITestCreate")
        app.launch()
        _ = createEvent(named: "UI restored event", as: "Alice")
        app.buttons["continue-event"].tap()
        XCTAssertEqual(app.buttons["tab-requirements"].label, "希望")
        XCTAssertEqual(app.buttons["tab-status"].label, "みんな")
        XCTAssertEqual(app.buttons["tab-candidates"].label, "候補")
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.staticTexts["UI restored event"].waitForExistence(timeout: 30))
    }

    private func createEvent(named name: String, as displayName: String) -> String {
        let eventName = app.textFields["event-name"]
        XCTAssertTrue(eventName.waitForExistence(timeout: 20))
        eventName.tap()
        eventName.typeText(name)
        let yourName = app.textFields["display-name"]
        if !yourName.isHittable { app.swipeUp() }
        yourName.tap()
        yourName.typeText(displayName)
        app.buttons["create-submit"].tap()
        let code = app.staticTexts["inviteCode"]
        XCTAssertTrue(code.waitForExistence(timeout: 30))
        return code.label
    }
}
