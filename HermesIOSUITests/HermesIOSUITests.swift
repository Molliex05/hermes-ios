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
        let menuClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["Ajouter une photo"])
        XCTAssertEqual(XCTWaiter.wait(for: [menuClosed], timeout: 5), .completed)
        let voice = app.buttons["voice-mode"]
        let voiceReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: voice)
        XCTAssertEqual(XCTWaiter.wait(for: [voiceReady], timeout: 5), .completed)
        capture("18b-attachments-menu-closed")
        voice.tap()
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

    private func connectFixtureIfNeeded(_ app: XCUIApplication, address endpoint: String = "http://127.0.0.1:19119") {
        if app.buttons["Rencontrer mon Hermes"].waitForExistence(timeout: 5) {
            app.buttons["Rencontrer mon Hermes"].tap()
            let address = app.textFields["Adresse Hermes"]
            XCTAssertTrue(address.waitForExistence(timeout: 3))
            address.tap(); address.typeText(endpoint)
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
    }

    func testNativeInteractiveRecoveryAndPermissions() throws {
        guard ProcessInfo.processInfo.environment["HERMES_IOS_INTEGRATION"] == "1" else { throw XCTSkip("Requires isolated Hermes fixture on port 19123.") }
        let app = XCUIApplication()
        app.launchArguments = ["--integration-test", "--voice-fixture"]
        app.launch()
        connectFixtureIfNeeded(app, address: "http://127.0.0.1:19123")
        XCTAssertTrue(app.staticTexts["Connecté à Hermes"].waitForExistence(timeout: 40))
        app.buttons["Nouvelle conversation"].tap()
        let composer = app.textFields["chat-composer"]
        composer.tap(); composer.typeText("HERMES_IOS_REQUEST_TEST")
        app.buttons["send-message"].tap()
        let blue = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Bleu")).firstMatch
        XCTAssertTrue(blue.waitForExistence(timeout: 45))
        capture("24-native-questions")
        blue.tap()
        XCTAssertTrue(app.staticTexts["Un détail à ajouter ?"].waitForExistence(timeout: 10))
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Connecté à Hermes"].waitForExistence(timeout: 40))
        XCTAssertTrue(app.staticTexts["Un détail à ajouter ?"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Choisir une couleur"].exists)
        let response = app.textFields["Votre réponse…"]
        XCTAssertTrue(response.waitForExistence(timeout: 5)); response.tap(); response.typeText("Simple et fluide")
        app.buttons["Répondre"].tap()
        let final = app.descendants(matching: .any).matching(identifier: "assistant-message").matching(NSPredicate(format: "label CONTAINS %@", "le fil est retrouvé."))
        XCTAssertTrue(final.firstMatch.waitForExistence(timeout: 45))
        XCTAssertFalse(app.staticTexts["Un détail à ajouter ?"].exists)
        app.buttons["app-navigation"].tap()
        let search = app.textFields["spaces-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Permissions")
        app.buttons["space-capabilities"].tap()
        app.buttons["Permissions"].tap()
        XCTAssertTrue(app.staticTexts["Quand demander mon accord"].waitForExistence(timeout: 20))
        capture("25-native-permissions")
        app.buttons["return-to-chat"].tap()
        app.buttons["voice-mode"].tap()
        let transcriptToggle = app.buttons["voice-transcript-toggle"]
        XCTAssertTrue(transcriptToggle.waitForExistence(timeout: 30)); transcriptToggle.tap()
        XCTAssertTrue(app.staticTexts["Bonjour Hermes, résume mon projet."].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Hermes vous répond."].waitForExistence(timeout: 45))
        capture("26-native-voice-stream")
        XCTAssertTrue(app.staticTexts["Je vous écoute."].waitForExistence(timeout: 30))
        app.buttons["return-to-chat"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
    }

    func testNativeStreamingMarkdown() throws {
        guard ProcessInfo.processInfo.environment["HERMES_IOS_INTEGRATION"] == "1" else { throw XCTSkip("Requires isolated Hermes fixture") }
        let app = XCUIApplication()
        app.launch()
        connectFixtureIfNeeded(app)
        XCTAssertTrue(app.staticTexts["Connecté à Hermes"].waitForExistence(timeout: 40))
        app.buttons["Nouvelle conversation"].tap()
        let composer = app.textFields["chat-composer"]
        composer.tap(); composer.typeText("HERMES_IOS_MARKDOWN_TEST")
        app.buttons["send-message"].tap()
        let answer = app.descendants(matching: .any).matching(identifier: "assistant-message")
        XCTAssertTrue(answer.matching(NSPredicate(format: "label CONTAINS %@", "Premiers mots reçus")).firstMatch.waitForExistence(timeout: 12))
        XCTAssertFalse(answer.matching(NSPredicate(format: "label CONTAINS %@", "Réponse terminée.")).firstMatch.exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        capture("23-live-stream")
        XCTAssertTrue(answer.matching(NSPredicate(format: "label CONTAINS %@", "Réponse terminée.")).firstMatch.waitForExistence(timeout: 50))
        XCTAssertEqual(answer.count, 1)
        XCTAssertTrue(app.buttons["Copier le code"].exists)
        app.buttons["Copier le code"].tap()
        XCTAssertTrue(app.buttons["Copier le code"].exists)
        capture("24-markdown-chat")
        // Read earlier content without being dragged back down by layout changes.
        app.swipeDown()
        capture("25-markdown-heading")
    }

    func testNativeNotificationOpensCorrectConversationAfterColdLaunch() throws {
        guard ProcessInfo.processInfo.environment["HERMES_IOS_INTEGRATION"] == "1" else { throw XCTSkip("Requires push fixture and external simctl push injector") }
        let app = XCUIApplication()
        app.launchArguments = ["--integration-test", "--notification-fixture-permission"]
        app.launch()
        connectFixtureIfNeeded(app, address: "http://127.0.0.1:19133")
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = system.buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }
        else if system.buttons["Autoriser"].exists { system.buttons["Autoriser"].tap() }
        XCTAssertTrue(app.staticTexts["Connecté à Hermes"].waitForExistence(timeout: 40))
        app.buttons["Nouvelle conversation"].tap()
        let composer = app.textFields["chat-composer"]
        composer.tap(); composer.typeText("Mon brouillon avant notification")
        XCUIDevice.shared.press(.home)
        app.terminate()
        print("HERMES_NOTIFICATION_READY")
        let alert = system.staticTexts["Un nouveau message vous attend."]
        XCTAssertTrue(alert.waitForExistence(timeout: 60))
        alert.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.staticTexts["Research"].firstMatch.waitForExistence(timeout: 40))
        let answer = app.descendants(matching: .any).matching(identifier: "assistant-message").matching(NSPredicate(format: "label CONTAINS %@", "le fil est retrouvé."))
        XCTAssertTrue(answer.firstMatch.waitForExistence(timeout: 40))
        XCTAssertEqual(composer.value as? String, "Message…")
        capture("29-notification-correct-conversation")
    }

    func testNativeToolContinuesWhileBackgrounded() throws {
        guard ProcessInfo.processInfo.environment["HERMES_IOS_INTEGRATION"] == "1" else { throw XCTSkip("Requires isolated Hermes fixture on port 19129") }
        let app = XCUIApplication()
        app.launchArguments = ["--integration-test"]
        app.launch()
        connectFixtureIfNeeded(app, address: "http://127.0.0.1:19129")
        XCTAssertTrue(app.staticTexts["Connecté à Hermes"].waitForExistence(timeout: 40))
        app.buttons["Nouvelle conversation"].tap()
        let composer = app.textFields["chat-composer"]
        composer.tap(); composer.typeText("HERMES_IOS_TOOL_BACKGROUND_TEST")
        app.buttons["send-message"].tap()
        let activity = app.buttons["tool-activity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 30))
        activity.tap()
        XCTAssertTrue(app.staticTexts["Commande"].waitForExistence(timeout: 3))
        XCUIDevice.shared.press(.home)
        sleep(55)
        app.activate()
        let final = app.descendants(matching: .any).matching(identifier: "assistant-message").matching(NSPredicate(format: "label CONTAINS %@", "le fil est retrouvé."))
        XCTAssertTrue(final.firstMatch.waitForExistence(timeout: 45))
        XCTAssertEqual(final.count, 1)
        let sent = app.descendants(matching: .any).matching(identifier: "user-message").matching(NSPredicate(format: "label CONTAINS %@", "HERMES_IOS_TOOL_BACKGROUND_TEST"))
        XCTAssertEqual(sent.count, 1)
        XCTAssertFalse(app.staticTexts["Non envoyé · copiez pour réessayer"].exists)
        capture("28-tool-background-completed")
    }

    func testNativeRoutineResultAndPermissionDiscovery() throws {
        guard ProcessInfo.processInfo.environment["HERMES_IOS_INTEGRATION"] == "1" else {
            throw XCTSkip("Requires a fresh app install and isolated Hermes fixture on port 19139.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--integration-test"]
        app.launch()
        connectFixtureIfNeeded(app, address: "http://127.0.0.1:19139")
        XCTAssertTrue(app.staticTexts["Connecté à Hermes"].waitForExistence(timeout: 40))
        app.buttons["app-navigation"].tap()
        let search = app.textFields["spaces-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("cron")
        app.buttons["space-routines"].tap()
        XCTAssertTrue(app.buttons["routine.add"].waitForExistence(timeout: 10))
        app.buttons["routine.add"].tap()

        // The normal form exposes a rhythm and a wall-clock time. Technical
        // syntax stays collapsed until the person explicitly opens Advanced.
        XCTAssertTrue(app.buttons["routine.rhythm"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.datePickers["routine.time"].exists)
        XCTAssertTrue(app.staticTexts["Tous les jours à 8 h"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "routine.rawSchedule").firstMatch.exists)
        capture("33-routine-simple-schedule")
        let name = "Routine UI " + String(UUID().uuidString.prefix(8))
        let nameField = app.textFields["routine.name"]
        nameField.tap(); nameField.typeText(name)
        let prompt = app.descendants(matching: .any).matching(identifier: "routine.prompt").firstMatch
        prompt.tap(); prompt.typeText("Réponds brièvement pour tester le résultat de cette routine.")
        app.swipeUp()
        let advanced = app.buttons["routine.advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5)); advanced.tap()
        let raw = app.descendants(matching: .any).matching(identifier: "routine.rawSchedule").firstMatch
        XCTAssertTrue(raw.waitForExistence(timeout: 3))
        raw.tap()
        raw.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (raw.value as? String ?? "").count))
        // This disposable one-shot cannot accidentally fire on the scheduler
        // while the UI test is inspecting the form, regardless of time zone.
        raw.typeText("2099-01-01T08:30:00Z")
        app.buttons["routine.create"].tap()
        XCTAssertTrue(app.navigationBars["Les routines"].waitForExistence(timeout: 20))
        let routine = app.buttons.containing(.staticText, identifier: name).firstMatch
        XCTAssertTrue(routine.waitForExistence(timeout: 15)); routine.tap()
        let trigger = app.buttons["routine.trigger"]
        for _ in 0..<4 where !trigger.isHittable { app.swipeUp() }
        XCTAssertTrue(trigger.isHittable); trigger.tap()
        let confirm = app.buttons["Exécuter"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        app.swipeUp()
        let result = app.buttons["routine.result"].firstMatch
        // The local fixture responds quickly, but the native endpoint waits for
        // the completed execution before returning its stored SessionInfo.
        XCTAssertTrue(result.waitForExistence(timeout: 45))
        for _ in 0..<4 where !result.isHittable { app.swipeUp() }
        XCTAssertTrue(result.isEnabled); XCTAssertTrue(result.isHittable)
        capture("34-routine-native-result")
        result.tap()
        XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.navigationBars["Les routines"].exists)
        // A completed response alone could be the Bot Chat destination. Requiring
        // this unique run title checks that the tapped execution was selected.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch.waitForExistence(timeout: 10))
        let answer = app.descendants(matching: .any).matching(identifier: "assistant-message")
            .matching(NSPredicate(format: "label CONTAINS %@", "le fil est retrouvé."))
        XCTAssertTrue(answer.firstMatch.waitForExistence(timeout: 20))
        capture("35-routine-opened-conversation")

        app.buttons["app-navigation"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Permissions")
        app.buttons["space-capabilities"].tap()
        app.buttons["Permissions"].tap()
        let policy = app.buttons["configuration-approvals.mode"]
        XCTAssertTrue(policy.waitForExistence(timeout: 20)); policy.tap()
        let manual = app.buttons["approval-mode-manual"]
        XCTAssertTrue(manual.waitForExistence(timeout: 5))
        XCTAssertTrue(manual.label.contains("Me demander"))
        capture("36-permission-choices")
        // Read the native options without changing or saving any permission.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let advancedPermissions = app.buttons["configuration-advanced"]
        for _ in 0..<4 where !advancedPermissions.isHittable { app.swipeUp() }
        XCTAssertTrue(advancedPermissions.isHittable); advancedPermissions.tap()
        XCTAssertTrue(app.navigationBars["Réglages avancés"].waitForExistence(timeout: 5))
        capture("37-permissions-advanced")
        app.buttons["return-to-chat"].tap()
        XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 5))
    }

    func testNativeSendThenImmediatelyBackground() throws {
        guard ProcessInfo.processInfo.environment["HERMES_IOS_INTEGRATION"] == "1" else { throw XCTSkip("Requires isolated Hermes fixture") }
        let app = XCUIApplication()
        app.launchArguments = ["--integration-test"]
        app.launch()
        connectFixtureIfNeeded(app)
        XCTAssertTrue(app.staticTexts["Connecté à Hermes"].waitForExistence(timeout: 40))
        app.buttons["Nouvelle conversation"].tap()
        let composer = app.textFields["chat-composer"]
        composer.tap(); composer.typeText("HERMES_IOS_BACKGROUND_TEST")
        app.buttons["send-message"].tap()
        // Leave before waiting for either the submission acknowledgement or a first token.
        XCUIDevice.shared.press(.home)
        // Longer than the native 20-second orphan grace. The fixture streams for ~30 seconds.
        sleep(40)
        app.activate()
        let final = app.descendants(matching: .any).matching(identifier: "assistant-message").matching(NSPredicate(format: "label CONTAINS %@", "le fil est retrouvé."))
        XCTAssertTrue(final.firstMatch.waitForExistence(timeout: 45))
        XCTAssertEqual(final.count, 1)
        let sent = app.descendants(matching: .any).matching(identifier: "user-message").matching(NSPredicate(format: "label CONTAINS %@", "HERMES_IOS_BACKGROUND_TEST"))
        XCTAssertEqual(sent.count, 1)
        capture("22-background-completed")
        app.terminate(); app.launch()
        XCTAssertTrue(final.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Connecté à Hermes"].waitForExistence(timeout: 40))
    }

    func testNativeHermesConnectionAndResume() throws {
        guard ProcessInfo.processInfo.environment["HERMES_IOS_INTEGRATION"] == "1" else { throw XCTSkip("Start the isolated Hermes integration server and set HERMES_IOS_INTEGRATION=1.") }
        let app = XCUIApplication()
        app.launchArguments = ["--integration-test", "--voice-fixture"]
        app.launch()
        connectFixtureIfNeeded(app)
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
        let transcriptToggle = app.buttons["voice-transcript-toggle"]
        XCTAssertTrue(transcriptToggle.waitForExistence(timeout: 30)); transcriptToggle.tap()
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

    func testToolFavoritesPersistAndOpenTheirDestination() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.buttons["app-navigation"].waitForExistence(timeout: 10))
        app.buttons["app-navigation"].tap()
        app.buttons["edit-tool-favorites"].tap()
        let options = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "favorite-option-"))
        XCTAssertTrue(options.firstMatch.waitForExistence(timeout: 3))

        // Adapt to persisted preferences; restore the removed favorite at the end.
        let original = options.allElementsBoundByIndex.first { ($0.value as? String) == "Ajouté" && $0.isHittable }
        let originalID = original?.identifier
        original?.tap()
        let candidate = try XCTUnwrap(options.allElementsBoundByIndex.first {
            $0.identifier != originalID && ($0.value as? String) != "Ajouté" && $0.isEnabled && $0.isHittable
        })
        let selectedID = candidate.identifier
        let shortcutID = selectedID.replacingOccurrences(of: "favorite-option-", with: "favorite-tool-")
        candidate.tap()
        XCTAssertEqual(candidate.value as? String, "Ajouté")
        app.buttons["close-tool-favorites"].tap()
        XCTAssertTrue(app.buttons[shortcutID].waitForExistence(timeout: 3))
        capture("30-tool-favorites")

        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["app-navigation"].waitForExistence(timeout: 10))
        app.buttons["app-navigation"].tap()
        XCTAssertTrue(app.buttons[shortcutID].waitForExistence(timeout: 3))
        app.buttons[shortcutID].tap()
        XCTAssertTrue(app.buttons["back-to-spaces"].waitForExistence(timeout: 3))
        app.buttons["back-to-spaces"].tap()
        app.buttons["edit-tool-favorites"].tap()
        XCTAssertTrue(app.buttons[selectedID].waitForExistence(timeout: 3))
        app.buttons[selectedID].tap()
        if let originalID { app.buttons[originalID].tap() }
        app.buttons["close-tool-favorites"].tap()
        app.buttons["return-to-chat"].tap()
        XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 3))
    }

    func testUnreadConversationFilterClearsAfterOpening() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.buttons["quick-history"].waitForExistence(timeout: 10))
        app.buttons["quick-history"].tap()
        let filter = app.segmentedControls["history-filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 3))
        filter.buttons["Non lues"].tap()
        let unread = app.buttons["conversation-demo-default-idea"]
        XCTAssertTrue(unread.waitForExistence(timeout: 3))
        capture("31-unread-conversations")
        unread.tap()
        XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 3))
        app.buttons["quick-history"].tap()
        filter.buttons["Non lues"].tap()
        XCTAssertTrue(app.staticTexts["Vous êtes à jour"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["conversation-demo-default-idea"].exists)
        filter.buttons["Toutes"].tap()
        XCTAssertTrue(app.buttons["conversation-demo-default-idea"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["En cours"].exists)
        app.buttons["return-to-chat"].tap()
    }

    func testLargeTextThumbNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let composer = app.textFields["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        assertControlsInsideComposer(in: app)
        for identifier in ["message-actions", "switch-profile", "quick-history", "app-navigation", "voice-mode"] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.isHittable, "\(identifier) remains reachable at the largest text size")
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, "\(identifier) hit target height")
            XCTAssertGreaterThanOrEqual(control.frame.width, 44, "\(identifier) hit target width")
        }
        capture("38-large-text-composer")
        composer.tap(); composer.typeText("Mon brouillon en grand texte")
        assertControlsInsideComposer(in: app)
        capture("39-large-text-keyboard")
        app.buttons["switch-profile"].tap()
        let closeProfile = app.buttons["return-to-chat"]
        XCTAssertTrue(closeProfile.waitForExistence(timeout: 5))
        XCTAssertTrue(closeProfile.isHittable)
        XCTAssertGreaterThanOrEqual(closeProfile.frame.width, 44)
        XCTAssertGreaterThanOrEqual(closeProfile.frame.height, 44)
        capture("40-large-text-profiles")
        closeProfile.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Mon brouillon en grand texte")
        app.buttons["app-navigation"].tap()
        XCTAssertTrue(app.textFields["spaces-search"].waitForExistence(timeout: 5))
        let closeTools = app.buttons["return-to-chat"]
        XCTAssertTrue(closeTools.isHittable)
        XCTAssertGreaterThanOrEqual(closeTools.frame.width, 44)
        XCTAssertGreaterThanOrEqual(closeTools.frame.height, 44)
        capture("41-large-text-tools")
        closeTools.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Mon brouillon en grand texte")
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

    func testNativeHandsFreeVoiceConversation() throws {
        guard ProcessInfo.processInfo.environment["HERMES_IOS_INTEGRATION"] == "1" else { throw XCTSkip("Requires isolated Hermes fixture on port 19149.") }
        let app = XCUIApplication()
        app.launchArguments = ["--integration-test", "--voice-fixture", "--voice-quiet-fixture"]
        app.launch()
        connectFixtureIfNeeded(app, address: "http://127.0.0.1:19149")
        XCTAssertTrue(app.staticTexts["Connecté à Hermes"].waitForExistence(timeout: 40))
        app.buttons["Nouvelle conversation"].tap()
        let composer = app.textFields["chat-composer"]
        composer.tap(); composer.typeText("Mon brouillon reste privé")
        app.buttons["voice-mode"].tap()
        let listening = app.staticTexts["Je vous écoute."]
        let speaking = app.staticTexts["Hermes vous répond."]
        XCTAssertTrue(listening.waitForExistence(timeout: 20))
        // Quiet fixture stays silent for 18 seconds: no old 15-second auto-pause.
        Thread.sleep(forTimeInterval: 16)
        XCTAssertTrue(listening.exists)
        XCTAssertFalse(app.otherElements["voice-error"].exists)
        capture("42-voice-listening")
        XCTAssertTrue(speaking.waitForExistence(timeout: 60))
        capture("43-voice-speaking")
        XCTAssertTrue(listening.waitForExistence(timeout: 60))
        // A second full turn starts and plays with no microphone/send gesture.
        XCTAssertTrue(speaking.waitForExistence(timeout: 60))
        XCTAssertTrue(listening.waitForExistence(timeout: 60))
        let microphone = app.buttons["voice-listen"]
        microphone.tap()
        XCTAssertTrue(app.staticTexts["Microphone coupé."].waitForExistence(timeout: 5))
        let toggle = app.buttons["voice-transcript-toggle"]
        XCTAssertTrue(toggle.exists); toggle.tap()
        XCTAssertTrue(app.staticTexts["Bonjour Hermes, résume mon projet."].waitForExistence(timeout: 5))
        capture("44-voice-muted-transcript")
        app.buttons["return-to-chat"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Mon brouillon reste privé")
        XCTAssertFalse(app.staticTexts["Non envoyé · copiez pour réessayer"].exists)
    }

    func testVoiceAccessibilityAndDismissal() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["voice-mode"].waitForExistence(timeout: 10))
        app.buttons["voice-mode"].tap()
        let close = app.buttons["return-to-chat"]
        XCTAssertTrue(close.waitForExistence(timeout: 5)); XCTAssertTrue(close.isHittable)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        XCTAssertTrue(app.buttons["voice-listen"].exists)
        capture("45-voice-accessibility")
        close.tap()
        XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 5))
    }

    func testNativeVoiceBargeInAndNextTurn() throws {
        guard ProcessInfo.processInfo.environment["HERMES_IOS_INTEGRATION"] == "1" else { throw XCTSkip("Requires isolated Hermes fixture on port 19149.") }
        let app = XCUIApplication()
        app.launchArguments = ["--integration-test", "--voice-fixture", "--voice-barge-fixture"]
        app.launch()
        connectFixtureIfNeeded(app, address: "http://127.0.0.1:19149")
        XCTAssertTrue(app.staticTexts["Connecté à Hermes"].waitForExistence(timeout: 40))
        app.buttons["Nouvelle conversation"].tap()
        app.buttons["voice-mode"].tap()
        let listening = app.staticTexts["Je vous écoute."]
        let speaking = app.staticTexts["Hermes vous répond."]
        XCTAssertTrue(listening.waitForExistence(timeout: 20))
        XCTAssertTrue(speaking.waitForExistence(timeout: 45))
        // The fixture produces microphone speech over the first PCM playback.
        // Its normal multi-sentence playback lasts longer than this interruption window.
        XCTAssertTrue(listening.waitForExistence(timeout: 8))
        capture("46-voice-barge-in")
        XCTAssertFalse(app.otherElements["voice-error"].exists)
        XCTAssertTrue(speaking.waitForExistence(timeout: 45))
        XCTAssertTrue(listening.waitForExistence(timeout: 60))
        app.buttons["voice-listen"].tap()
        XCTAssertTrue(app.staticTexts["Microphone coupé."].waitForExistence(timeout: 5))
        app.buttons["return-to-chat"].tap()
        XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Non envoyé · copiez pour réessayer"].exists)
    }

    func testNativeVoiceCanCloseAndReopenWithoutLateCapture() throws {
        guard ProcessInfo.processInfo.environment["HERMES_IOS_INTEGRATION"] == "1" else { throw XCTSkip("Requires isolated Hermes fixture on port 19149.") }
        let app = XCUIApplication()
        app.launchArguments = ["--integration-test", "--voice-fixture", "--voice-quiet-fixture"]
        app.launch()
        connectFixtureIfNeeded(app, address: "http://127.0.0.1:19149")
        XCTAssertTrue(app.staticTexts["Connecté à Hermes"].waitForExistence(timeout: 40))
        app.buttons["Nouvelle conversation"].tap()
        for _ in 0..<2 {
            app.buttons["voice-mode"].tap()
            XCTAssertTrue(app.staticTexts["Je vous écoute."].waitForExistence(timeout: 20))
            app.buttons["return-to-chat"].tap()
            XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 5))
        }
        Thread.sleep(forTimeInterval: 4)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "user-message").firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "assistant-message").firstMatch.exists)
        app.textFields["chat-composer"].tap()
        app.textFields["chat-composer"].typeText("Le chat reste disponible")
        XCTAssertTrue(app.buttons["send-message"].isEnabled)
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
