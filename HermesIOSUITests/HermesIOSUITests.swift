import XCTest

@MainActor
final class HermesIOSUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func testChatAndAgents() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertGreaterThan(app.buttons["app-navigation"].frame.minY, app.windows.firstMatch.frame.maxY - 130)
        XCTAssertLessThan(app.windows.firstMatch.frame.maxY - app.textFields["chat-composer"].frame.maxY, 130)
        XCTAssertGreaterThan(app.buttons["switch-profile"].frame.minY, app.textFields["chat-composer"].frame.maxY)
        assertControlsInsideComposer(in: app)
        capture("01-chat")
        openNavigation("Agents", in: app)
        XCTAssertTrue(app.staticTexts["Vos agents."].waitForExistence(timeout: 3))
        capture("02-agents")
        app.buttons.containing(.staticText, identifier: "Atlas").firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Bonjour, je suis Atlas")).firstMatch.waitForExistence(timeout: 3))
        openNavigation("Réglages", in: app)
        XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 3))
        capture("03-settings")
        app.buttons["close-settings"].tap()
        XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 3))
    }

    func testAttachmentsMenuAndVoicePreserveDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        let composer = app.textFields["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap(); composer.typeText("Mon brouillon écrit")
        app.buttons["message-actions"].tap()
        XCTAssertTrue(app.buttons["Ajouter une photo"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Ajouter un fichier"].exists)
        XCTAssertFalse(app.buttons["Mentionner un agent"].exists)
        XCTAssertFalse(app.buttons["Dicter un message"].exists)
        capture("18-attachments-menu")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 30, dy: 150)).tap()
        app.buttons["voice-mode"].tap()
        XCTAssertTrue(app.buttons["voice-listen"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["voice-listen"].isEnabled)
        capture("19-voice")
        app.buttons["return-to-chat"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "Mon brouillon écrit")
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

    func testDraftSurvivesThumbNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        let composer = app.textFields["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap(); composer.typeText("Mon brouillon reste ici")
        assertControlsInsideComposer(in: app)
        capture("13-composer-keyboard")
        openNavigation("Agents", in: app)
        XCTAssertTrue(app.buttons["return-to-chat"].waitForExistence(timeout: 3))
        app.buttons["return-to-chat"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "Mon brouillon reste ici")
        openNavigation("Réglages", in: app)
        XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 3))
        app.buttons["close-settings"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "Mon brouillon reste ici")
    }

    func testNativeHermesConnectionAndResume() throws {
        guard ProcessInfo.processInfo.environment["HERMES_IOS_INTEGRATION"] == "1" else { throw XCTSkip("Start the isolated Hermes integration server and set HERMES_IOS_INTEGRATION=1.") }
        let app = XCUIApplication()
        app.launchArguments = ["--integration-test", "--voice-fixture"]
        app.launch()
        if app.buttons["Rencontrer mon Hermes"].waitForExistence(timeout: 5) {
            app.buttons["Rencontrer mon Hermes"].tap()
            let address = app.textFields["Adresse Hermes"]
            XCTAssertTrue(address.waitForExistence(timeout: 3))
            address.tap(); address.typeText("http://127.0.0.1:19119")
            let user = app.textFields["Utilisateur"]
            user.tap()
            user.typeText("hermes-ios-test")
            XCTAssertEqual(user.value as? String, "hermes-ios-test")
            let password = app.secureTextFields["Mot de passe Hermes"]
            password.tap(); password.typeText("hermes-ios-local-fixture")
            app.swipeUp()
            app.buttons["connect-agent"].tap()
            XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 40))
            // Verify persisted authentication immediately. Relaunch also dismisses iOS'
            // optional password-manager sheet without saving disposable fixture credentials.
            app.terminate(); app.launch()
        }
        XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 40))
        XCTAssertTrue(app.staticTexts["Connecté à Hermes"].waitForExistence(timeout: 40))
        openNavigation("Conversations", in: app)
        let newChat = try XCTUnwrap(app.buttons.matching(identifier: "Nouvelle conversation").allElementsBoundByIndex.first(where: { $0.isHittable }))
        newChat.tap()
        let composer = app.textFields["chat-composer"]
        composer.tap(); composer.typeText("Bonjour depuis HermesIOS sur iPhone")
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

        // check_tools_contract.py seeds only the disposable research profile.
        app.buttons["switch-profile"].tap()
        XCTAssertTrue(app.buttons["quick-profile-research"].waitForExistence(timeout: 5))
        app.buttons["quick-profile-research"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        openNavigation("Skills", in: app)
        let skill = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "mobile-fixture-")).firstMatch
        XCTAssertTrue(skill.waitForExistence(timeout: 15))
        skill.tap()
        let toggle = app.switches["Disponible pour l’agent"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        capture("09-skill-before")
        let expected = (toggle.value as? String) == "1" ? "0" : "1"
        // SwiftUI exposes the label and switch as one wide accessibility element.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: toggle)
        let outcome = XCTWaiter.wait(for: [enabled], timeout: 10)
        capture("09-native-skill")
        XCTAssertEqual(outcome, .completed)
        app.buttons["return-to-chat"].tap()
        openNavigation("Modèles", in: app)
        XCTAssertTrue(app.staticTexts["hermes-ios-fixture-mobile"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["return-to-chat"].tap()
        openNavigation("Workspace", in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Mobile ")).firstMatch.waitForExistence(timeout: 15))
        app.buttons["return-to-chat"].tap()
        openNavigation("Kanban", in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Mobile fixture ")).firstMatch.waitForExistence(timeout: 15))
        capture("10-native-kanban")
        app.buttons["return-to-chat"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap(); composer.typeText("Brouillon préservé pendant la voix")
        app.buttons["voice-mode"].tap()
        XCTAssertTrue(app.staticTexts["Bonjour Hermes, résume mon projet."].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Hermes vous répond."].waitForExistence(timeout: 45))
        XCTAssertTrue(app.staticTexts["Je vous écoute."].waitForExistence(timeout: 15))
        capture("20-native-voice-loop")
        app.buttons["return-to-chat"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Brouillon préservé pendant la voix")
    }

    func testSpacesDiscoveryAndTools() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.buttons["app-navigation"].waitForExistence(timeout: 10))
        app.buttons["app-navigation"].tap()
        XCTAssertTrue(app.textFields["spaces-search"].waitForExistence(timeout: 3))
        capture("07-spaces")
        XCTAssertTrue(app.buttons["space-kanban"].exists)
        XCTAssertFalse(app.buttons["space-skills"].exists)
        app.buttons["tools-filter-agent"].tap()
        XCTAssertTrue(app.buttons["space-skills"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["space-kanban"].exists)
        capture("11-agent-tools")
        for (query, identifier, title) in [("cron", "routines", "Les routines"), ("skills", "skills", "Skills"), ("kanban", "kanban", "Kanban"), ("workspace", "workspace", "Workspace"), ("modèle", "models", "Modèles"), ("voix", "voice", "Voix")] {
            let search = app.textFields["spaces-search"]
            search.tap(); search.typeText(query)
            let button = app.buttons["space-" + identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            button.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3))
            if identifier == "voice" {
                XCTAssertTrue(app.buttons["voice-listen"].exists)
                XCTAssertEqual(app.buttons["voice-listen"].frame.midY, app.buttons["return-to-chat"].frame.midY, accuracy: 1)
            }
            if identifier == "kanban" {
                XCTAssertTrue(app.buttons["Nouvelle tâche"].exists)
                XCTAssertLessThanOrEqual(app.buttons["Nouvelle tâche"].frame.maxY, app.buttons["return-to-chat"].frame.maxY)
            }
            capture("08-" + identifier)
            if identifier == "kanban" { XCTAssertTrue(app.staticTexts["Préparer la prochaine idée"].waitForExistence(timeout: 5)) }
            app.buttons["back-to-spaces"].tap()
            XCTAssertTrue(app.textFields["spaces-search"].waitForExistence(timeout: 3))
            app.buttons["Effacer la recherche"].tap()
        }
        app.buttons["return-to-chat"].tap()
        XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 3))
    }

    private func openNavigation(_ destination: String, in app: XCUIApplication) {
        if destination == "Agents" {
            app.buttons["switch-profile"].tap()
            XCTAssertTrue(app.buttons["manage-agents"].waitForExistence(timeout: 3))
            app.buttons["manage-agents"].tap(); return
        }
        if destination == "Conversations" { app.buttons["quick-history"].tap(); return }
        app.buttons["app-navigation"].tap()
        if destination == "Réglages" {
            XCTAssertTrue(app.buttons["quick-settings"].waitForExistence(timeout: 3))
            app.buttons["quick-settings"].tap(); return
        }
        let search = app.textFields["spaces-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap(); search.typeText(destination)
        let identifier = destination == "Réglages" ? "settings" : destination == "Modèles" ? "models" : destination == "Conversations" ? "history" : destination.lowercased()
        let button = app.buttons["space-" + identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        button.tap()
    }

    func testQuickProfileSwitchKeepsSeparateDrafts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        let composer = app.textFields["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap(); composer.typeText("Une idee pour Hermes")
        app.buttons["switch-profile"].tap()
        XCTAssertTrue(app.buttons["quick-profile-default"].waitForExistence(timeout: 3))
        capture("12-profiles")
        // Selecting the active profile must leave the current chat untouched.
        app.buttons["quick-profile-default"].tap()
        XCTAssertEqual(composer.value as? String, "Une idee pour Hermes")
        app.buttons["switch-profile"].tap()
        app.buttons["quick-profile-research"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Bonjour, je suis Atlas")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "Message…")
        composer.tap(); composer.typeText("Une recherche pour Atlas")
        app.buttons["switch-profile"].tap()
        app.buttons["quick-profile-default"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "Une idee pour Hermes")
        app.buttons["switch-profile"].tap()
        app.buttons["quick-profile-research"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "Une recherche pour Atlas")
        app.buttons["quick-history"].tap()
        XCTAssertTrue(app.navigationBars["Conversations"].waitForExistence(timeout: 3))
        capture("21-conversation-list")
        app.buttons["return-to-chat"].tap()
        XCTAssertEqual(composer.value as? String, "Une recherche pour Atlas")
    }

    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        // Also keep PNGs in the disposable runner container: beta Xcode can stall
        // while finalizing xcresult after a fully completed suite.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-ios-qa")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertControlsInsideComposer(in app: XCUIApplication) {
        let surface = app.otherElements["composer-surface"]
        XCTAssertTrue(surface.exists)
        for identifier in ["message-actions", "switch-profile", "quick-history", "app-navigation", "voice-mode", "send-message"] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.exists)
            XCTAssertTrue(surface.frame.contains(control.frame), "\(identifier) belongs inside the composer bubble")
        }
    }
}
