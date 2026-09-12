import XCTest

@MainActor
final class IrisUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func testChatAndAgents() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 10))
        capture("01-chat")
        app.tabBars.buttons["Agents"].tap()
        XCTAssertTrue(app.staticTexts["À chacun\nson talent."].waitForExistence(timeout: 3))
        capture("02-agents")
        app.buttons.containing(.staticText, identifier: "Atlas").firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Bonjour, je suis Atlas")).firstMatch.waitForExistence(timeout: 3))
        app.tabBars.buttons["Réglages"].tap()
        capture("03-settings")
    }

    func testOnboarding() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-onboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["Rencontrer mon Hermes"].waitForExistence(timeout: 10))
        capture("04-welcome")
        app.buttons["Rencontrer mon Hermes"].tap()
        XCTAssertTrue(app.textFields["Adresse Hermes"].waitForExistence(timeout: 3))
        capture("05-connect")
        XCTAssertFalse(app.buttons["connect-agent"].isEnabled)
    }

    func testDraftSurvivesSwitchingTabs() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        let composer = app.textFields["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap(); composer.typeText("Mon brouillon reste ici")
        app.tabBars.buttons["Agents"].tap()
        app.tabBars.buttons["Conversation"].tap()
        XCTAssertEqual(composer.value as? String, "Mon brouillon reste ici")
    }

    func testNativeHermesConnectionAndResume() throws {
        guard ProcessInfo.processInfo.environment["IRIS_INTEGRATION"] == "1" else { throw XCTSkip("Start the isolated Hermes integration server and set IRIS_INTEGRATION=1.") }
        let app = XCUIApplication()
        app.launchArguments = ["--integration-test"]
        app.launch()
        if app.buttons["Rencontrer mon Hermes"].waitForExistence(timeout: 5) {
            app.buttons["Rencontrer mon Hermes"].tap()
            let address = app.textFields["Adresse Hermes"]
            XCTAssertTrue(address.waitForExistence(timeout: 3))
            address.tap(); address.typeText("http://127.0.0.1:19119")
            let user = app.textFields["Utilisateur"]
            user.tap()
            user.typeText("iris-test")
            XCTAssertEqual(user.value as? String, "iris-test")
            let password = app.secureTextFields["Mot de passe Hermes"]
            password.tap(); password.typeText("iris-local-fixture")
            app.swipeUp()
            app.buttons["connect-agent"].tap()
            XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 40))
            // Verify persisted authentication immediately. Relaunch also dismisses iOS'
            // optional password-manager sheet without saving disposable fixture credentials.
            app.terminate(); app.launch()
        }
        XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 40))
        XCTAssertTrue(app.staticTexts["Connecté à Hermes"].waitForExistence(timeout: 40))
        app.buttons["Nouvelle conversation"].tap()
        let composer = app.textFields["chat-composer"]
        composer.tap(); composer.typeText("Bonjour depuis Iris sur iPhone")
        app.buttons["send-message"].tap()
        let answer = app.descendants(matching: .any).matching(identifier: "assistant-message").matching(NSPredicate(format: "label CONTAINS %@", "Bonjour depuis Hermes"))
        XCTAssertTrue(answer.firstMatch.waitForExistence(timeout: 45))
        XCUIDevice.shared.press(.home)
        // The agent keeps running on Hermes while iOS suspends its client.
        sleep(3)
        app.activate()
        let final = app.descendants(matching: .any).matching(identifier: "assistant-message").matching(NSPredicate(format: "label CONTAINS %@", "le fil est retrouvé."))
        XCTAssertTrue(final.firstMatch.waitForExistence(timeout: 30))
        XCTAssertEqual(final.count, 1)
        capture("06-live-hermes")
        app.terminate(); app.launch()
        XCTAssertTrue(final.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Connecté à Hermes"].waitForExistence(timeout: 30))
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
