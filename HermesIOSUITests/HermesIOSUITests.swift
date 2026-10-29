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
        XCTAssertLessThan(app.buttons["app-navigation"].frame.maxY, app.textFields["chat-composer"].frame.minY)
        XCTAssertLessThan(app.windows.firstMatch.frame.maxY - app.textFields["chat-composer"].frame.maxY, 130)
        XCTAssertLessThan(app.buttons["switch-profile"].frame.maxY, app.textFields["chat-composer"].frame.minY)
        assertControlsInsideComposer(in: app)
        capture("01-chat")
        openNavigation("Agents", in: app)
        XCTAssertTrue(app.navigationBars["Gérer mes agents"].waitForExistence(timeout: 3))
        capture("02-agents")
        returnToChat(app)
        // « Mes agents » in the menu opens a conversation in one tap.
        app.buttons["app-navigation"].tap()
        let atlas = app.buttons["menu-agent-research"]
        XCTAssertTrue(app.buttons["menu-current-agent"].waitForExistence(timeout: 3))
        for _ in 0..<5 where !(atlas.exists && atlas.isHittable) { app.swipeUp() }
        XCTAssertTrue(atlas.isHittable)
        capture("02b-menu-agents")
        atlas.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Bonjour, je suis Atlas")).firstMatch.waitForExistence(timeout: 3))
        openNavigation("Réglages", in: app)
        XCTAssertTrue(app.navigationBars["Connexions"].waitForExistence(timeout: 3))
        capture("03-settings")
        returnToChat(app)
        XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 3))
    }

    /// Sending closes the keyboard while the list follows the new message: the last message must stay just above the
    /// composer, never leave a blank gap below it (the view used to jump up and need a manual scroll down).
    func testSendKeepsConversationAtTheBottom() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-slow-send"]
        app.launch()
        let composer = app.textFields["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let surface = app.otherElements["composer-surface"]
        for index in 1...12 {
            composer.tap()
            let filler = String(repeating: " mot", count: (index * 7) % 23)
            composer.typeText("Message \(index) : une phrase assez longue pour que la conversation dépasse vite la hauteur de l'écran." + filler)
            app.buttons["send-message"].tap()
            for delay in [0.5, 3.0] {
                Thread.sleep(forTimeInterval: delay)
                let user = app.descendants(matching: .any).matching(identifier: "user-message").allElementsBoundByIndex.last
                XCTAssertNotNil(user, "message \(index) at \(delay)s")
                if let user { XCTAssertLessThanOrEqual(user.frame.maxY, surface.frame.minY + 1, "message \(index) hidden behind the composer at \(delay)s") }
                let last = app.descendants(matching: .any).matching(identifier: "assistant-message").allElementsBoundByIndex.last ?? user
                // A short conversation sits at the top by design; the gap only matters once the content overflows.
                if let last, index >= 4 {
                    let gap = surface.frame.minY - last.frame.maxY
                    XCTAssertLessThan(gap, 90, "blank gap of \(gap)pt under the last message after message \(index) at \(delay)s")
                }
            }
        }
    }

    /// A long conversation of rows with very different heights: after sending, the new message must be on screen.
    func testSendInALongConversationShowsTheNewMessage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-long-history", "--demo-slow-send"]
        app.launch()
        let composer = app.textFields["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let surface = app.otherElements["composer-surface"]
        Thread.sleep(forTimeInterval: 1.5)
        for round in 1...3 {
            composer.tap()
            composer.typeText("Message de test numéro \(round) dans une longue conversation.")
            app.buttons["send-message"].tap()
            for delay in [0.6, 1.5, 3.0] {
                Thread.sleep(forTimeInterval: delay)
                let mine = app.descendants(matching: .any).matching(identifier: "user-message").matching(NSPredicate(format: "label CONTAINS %@", "numéro \(round) ")).firstMatch
                XCTAssertTrue(mine.exists, "round \(round): my message is not in the visible list after \(delay)s")
                if mine.exists { XCTAssertLessThanOrEqual(mine.frame.maxY, surface.frame.minY + 1, "round \(round): hidden behind the composer at \(delay)s") }
            }
        }
    }

    /// Rich cards from the agent: the carousel, the map, the weather, the figures and the event render natively, and a
    /// quick reply sends itself as if typed.
    func testRichCardsRenderAndAQuickReplySends() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-cards"]
        app.launch()
        XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 10))
        // The newest reply holds a card and a link preview; a tall last row used to fall out of the accessibility tree.
        let latestChoice = app.buttons["Bonne soirée"]
        XCTAssertTrue(latestChoice.waitForExistence(timeout: 5), "the last reply's quick replies")
        XCTAssertTrue(app.descendants(matching: .any)["link-preview"].waitForExistence(timeout: 5), "a link in the text gets a preview")
        let event = app.descendants(matching: .any)["card-event"]
        for _ in 0..<8 where !event.exists { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(event.exists, "the agenda reply's event card")
        // Up to the first reply: its cards are there, but an old quick reply no longer answers.
        let oldChoice = app.buttons["Seulement avec garage"]
        for _ in 0..<40 where !(oldChoice.exists && oldChoice.isHittable) { app.swipeDown(velocity: .fast) }
        for identifier in ["card-carousel", "card-choices"] {
            XCTAssertTrue(app.descendants(matching: .any)[identifier].waitForExistence(timeout: 5), identifier)
        }
        XCTAssertTrue(oldChoice.exists)
        XCTAssertFalse(oldChoice.isEnabled, "only the newest reply's cards answer")
        // Back down with the « Dernier message » button, then answer the newest reply.
        let jump = app.buttons["Dernier message"]
        XCTAssertTrue(jump.waitForExistence(timeout: 3))
        jump.tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: latestChoice)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        latestChoice.tap()
        let sent = app.descendants(matching: .any).matching(identifier: "user-message").matching(NSPredicate(format: "label CONTAINS %@", "Bonne soirée")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 5), "the quick reply was sent as a message")
        capture("42-rich-cards")
    }

    func testAttachmentsMenuAndVoicePreserveDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        let composer = app.textFields["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap(); composer.typeText("Mon brouillon écrit")
        app.buttons["message-actions"].tap()
        // The « + » opens a short sheet of three tiles, never a menu behind the keyboard.
        XCTAssertTrue(app.buttons["attach-photos"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["attach-files"].exists)
        XCTAssertTrue(app.buttons["attach-camera"].exists)
        XCTAssertFalse(app.buttons["Mentionner un agent"].exists)
        XCTAssertFalse(app.buttons["Dicter un message"].exists)
        capture("18-attachments-menu")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 30, dy: 150)).tap()
        let menuClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["attach-photos"])
        XCTAssertEqual(XCTWaiter.wait(for: [menuClosed], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["send-message"].exists)
        composer.tap(); composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Mon brouillon écrit".count))
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
        // The voice button only exists while the field is empty, so the draft was cleared to reach it: the field is empty again.
        XCTAssertEqual(composer.value as? String, "Demander à Hermes")
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
        XCTAssertTrue(app.navigationBars["Gérer mes agents"].waitForExistence(timeout: 3))
        returnToChat(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "Mon brouillon reste ici")
        openNavigation("Réglages", in: app)
        XCTAssertTrue(app.navigationBars["Connexions"].waitForExistence(timeout: 3))
        returnToChat(app)
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
        app.buttons["Autre réponse…"].tap()
        let response = app.textFields["Votre réponse…"]
        XCTAssertTrue(response.waitForExistence(timeout: 5)); response.typeText("Simple et fluide")
        app.buttons["Envoyer cette réponse"].tap()
        let final = app.descendants(matching: .any).matching(identifier: "assistant-message").matching(NSPredicate(format: "label CONTAINS %@", "le fil est retrouvé."))
        XCTAssertTrue(final.firstMatch.waitForExistence(timeout: 45))
        XCTAssertFalse(app.staticTexts["Un détail à ajouter ?"].exists)
        openNavigation("Permissions", in: app)
        XCTAssertTrue(app.staticTexts["Quand demander mon accord"].waitForExistence(timeout: 20))
        capture("25-native-permissions")
        returnToChat(app)
        app.buttons["voice-mode"].tap()
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
        XCTAssertEqual(composer.value as? String, "Demander à Atlas")
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
        // A step reads as one element: « Commande, <what it runs> ».
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Commande")).firstMatch.waitForExistence(timeout: 3))
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
        openNavigation("Routines", in: app)
        XCTAssertTrue(app.buttons["routine.add"].waitForExistence(timeout: 10))
        app.buttons["routine.add"].tap()

        // The normal form exposes a rhythm and a wall-clock time. Technical
        // syntax stays collapsed until the person explicitly opens Advanced.
        XCTAssertTrue(app.buttons["routine.rhythm"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["routine.time"].exists)
        XCTAssertTrue(app.staticTexts["Tous les jours à 8 h"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "routine.rawSchedule").firstMatch.exists)
        capture("33-routine-simple-schedule")
        let name = "Routine UI " + String(UUID().uuidString.prefix(8))
        let nameField = app.textFields["routine.name"]
        nameField.tap(); nameField.typeText(name)
        let prompt = app.descendants(matching: .any).matching(identifier: "routine.prompt").firstMatch
        prompt.tap(); prompt.typeText("Réponds brièvement pour tester le résultat de cette routine.")
        app.swipeUp()
        let advanced = app.descendants(matching: .any).matching(identifier: "routine.advanced").firstMatch
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

        openNavigation("Permissions", in: app)
        let policy = app.buttons["configuration-approvals.mode"]
        XCTAssertTrue(policy.waitForExistence(timeout: 20)); policy.tap()
        let manual = app.buttons["approval-mode-manual"]
        XCTAssertTrue(manual.waitForExistence(timeout: 5))
        XCTAssertTrue(manual.label.contains("Me demander"))
        capture("36-permission-choices")
        // Read the native options without changing or saving any permission.
        app.navigationBars.buttons["nav-back"].firstMatch.tap()
        let advancedPermissions = app.buttons["configuration-advanced"]
        for _ in 0..<4 where !advancedPermissions.isHittable { app.swipeUp() }
        XCTAssertTrue(advancedPermissions.isHittable); advancedPermissions.tap()
        XCTAssertTrue(app.navigationBars["Réglages avancés"].waitForExistence(timeout: 5))
        capture("37-permissions-advanced")
        returnToChat(app)
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
        returnToChat(app)
        openNavigation("Modèle", in: app)
        app.buttons["settings-page-model.main"].tap()
        app.buttons["settings-change-model"].tap()
        XCTAssertTrue(app.staticTexts["hermes-ios-fixture-mobile"].firstMatch.waitForExistence(timeout: 20))
        returnToChat(app)
        openNavigation("Workspace", in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Mobile ")).firstMatch.waitForExistence(timeout: 15))
        returnToChat(app)
        openNavigation("Kanban", in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Mobile fixture ")).firstMatch.waitForExistence(timeout: 15))
        capture("10-native-kanban")
        returnToChat(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap(); composer.typeText("Brouillon préservé pendant la voix")
        app.buttons["voice-mode"].tap()
        XCTAssertTrue(app.staticTexts["Hermes vous répond."].waitForExistence(timeout: 45))
        XCTAssertTrue(app.staticTexts["Je vous écoute."].waitForExistence(timeout: 15))
        capture("20-native-voice-loop")
        app.buttons["return-to-chat"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Brouillon préservé pendant la voix")
    }

    func testMenuDiscoveryAndTools() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.buttons["app-navigation"].waitForExistence(timeout: 10))
        app.buttons["app-navigation"].tap()
        let search = app.textFields["app-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["menu-current-agent"].exists)
        capture("07-menu")
        XCTAssertTrue(app.buttons["space-kanban"].exists)
        // Agent pages are reached from the agent, not duplicated in the menu.
        XCTAssertFalse(app.buttons["space-agent-model"].exists)
        XCTAssertFalse(app.buttons["space-capabilities"].exists)
        for (query, identifier, title) in [("cron", "routines", "Les routines"), ("skills", "skills", "Compétences"), ("kanban", "kanban", "Kanban"),
                                           ("workspace", "workspace", "Espace de travail"), ("modèle", "agent-model", "Modèle"), ("voix", "agent-voice", "Voix")] {
            search.tap(); search.typeText(query)
            let button = app.buttons["space-" + identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 5), identifier)
            button.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3), title)
            if identifier == "kanban" {
                XCTAssertTrue(app.buttons["Nouvelle tâche"].exists)
                XCTAssertTrue(app.staticTexts["Préparer la prochaine idée"].waitForExistence(timeout: 5))
            }
            capture("08-" + identifier)
            app.navigationBars[title].buttons["nav-back"].tap()
            XCTAssertTrue(search.waitForExistence(timeout: 3), "back to menu from " + title)
            search.tap(); search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: query.count + 2))
        }
        returnToChat(app)
        XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 3))
    }

    func testAgentSettingsAreGroupedAndPushed() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.buttons["app-navigation"].waitForExistence(timeout: 10))
        app.buttons["app-navigation"].tap()
        XCTAssertTrue(app.buttons["menu-current-agent"].waitForExistence(timeout: 3))
        app.buttons["menu-current-agent"].tap()
        XCTAssertTrue(app.buttons["settings-page-model"].waitForExistence(timeout: 5))
        for identifier in ["voice", "permissions", "personality", "skills"] { XCTAssertTrue(app.buttons["settings-page-" + identifier].exists, identifier) }
        // The search field now sits in the list, so the last pages of the section start below the fold.
        app.swipeUp()
        XCTAssertTrue(app.buttons["settings-page-tools"].waitForExistence(timeout: 3), "tools")
        app.swipeDown()
        capture("14-agent-settings")
        app.buttons["settings-page-permissions"].tap()
        XCTAssertTrue(app.navigationBars["Permissions"].waitForExistence(timeout: 5))
        // Pushed in the same stack: no second sheet, the back button returns to the agent.
        app.navigationBars["Permissions"].buttons["nav-back"].tap()
        XCTAssertTrue(app.buttons["settings-page-model"].waitForExistence(timeout: 3))
        returnToChat(app)
        XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 3))
    }

    func testSkeletonWhileFirstLoading() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-slow"]
        app.launch()
        XCTAssertTrue(app.buttons["app-navigation"].waitForExistence(timeout: 10))
        openNavigation("Skills", in: app)
        XCTAssertTrue(app.navigationBars["Compétences"].waitForExistence(timeout: 3))
        // Placeholders speak once, as « Chargement », then give way to the real rows.
        XCTAssertTrue(app.descendants(matching: .any)["Chargement"].firstMatch.waitForExistence(timeout: 2))
        capture("15-skeleton-skills")
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.descendants(matching: .any)["Chargement"].firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        returnToChat(app)
    }

    private func openNavigation(_ destination: String, in app: XCUIApplication) {
        if destination == "Agents" {
            app.buttons["switch-profile"].tap()
            XCTAssertTrue(app.buttons["manage-agents"].waitForExistence(timeout: 3))
            app.buttons["manage-agents"].tap(); return
        }
        app.buttons["app-navigation"].tap()
        let identifier = ["Réglages": "connections", "Routines": "routines", "Kanban": "kanban", "Workspace": "workspace",
                          "Skills": "skills", "Modèle": "agent-model", "Permissions": "agent-permissions"][destination] ?? destination.lowercased()
        let query = ["Réglages": "connexions", "Routines": "cron", "Skills": "compétences", "Workspace": "workspace"][destination] ?? destination
        let search = app.textFields["app-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap(); search.typeText(query)
        let button = app.buttons["space-" + identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }

    /// Closes the chat's sheet from any depth: back to its root, then its close button.
    private func returnToChat(_ app: XCUIApplication) {
        let close = app.buttons["return-to-chat"]
        for _ in 0..<6 where !(close.exists && close.isHittable) {
            let back = app.navigationBars.buttons["nav-back"].firstMatch
            guard back.exists else { break }
            back.tap()
        }
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.tap()
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
        XCTAssertEqual(composer.value as? String, "Demander à Atlas")
        composer.tap(); composer.typeText("Une recherche pour Atlas")
        app.buttons["switch-profile"].tap()
        app.buttons["quick-profile-default"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "Une idee pour Hermes")
        app.buttons["switch-profile"].tap()
        app.buttons["quick-profile-research"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "Une recherche pour Atlas")
        // In a conversation the list lives in the « … » menu; the quick button only exists on an empty chat.
        if app.buttons["quick-history"].exists { app.buttons["quick-history"].tap() }
        else {
            app.buttons["Actions de la conversation"].tap()
            app.buttons["Conversations"].firstMatch.tap()
        }
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
        XCTAssertFalse(app.buttons["edit-tool-favorites"].waitForExistence(timeout: 2))
        app.navigationBars.buttons["nav-back"].firstMatch.tap()
        XCTAssertTrue(app.buttons["edit-tool-favorites"].waitForExistence(timeout: 3))
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
        let filter = app.otherElements["history-filter"]
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
        for identifier in ["message-actions", "switch-profile", "app-navigation", "voice-mode"] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.isHittable, "\(identifier) remains reachable at the largest text size")
            XCTAssertGreaterThanOrEqual(control.frame.height, 43.9, "\(identifier) hit target height")
            XCTAssertGreaterThanOrEqual(control.frame.width, 43.9, "\(identifier) hit target width")
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
        XCTAssertTrue(app.textFields["app-search-field"].waitForExistence(timeout: 5))
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

    func testNativeGPTLiveDelegationAndReopen() throws {
        guard ProcessInfo.processInfo.environment["HERMES_IOS_INTEGRATION"] == "1" else { throw XCTSkip("Requires isolated GPT-Live fixture on port 19159.") }
        let app = XCUIApplication()
        app.launchArguments = ["--integration-test", "--live-transport-fixture"]
        app.launch()
        connectFixtureIfNeeded(app, address: "http://127.0.0.1:19159")
        XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 40))
        app.buttons["Nouvelle conversation"].tap()
        let composer = app.textFields["chat-composer"]
        composer.tap()
        if let previous = composer.value as? String, previous.contains("Brouillon privé GPT-Live") {
            composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        }
        composer.typeText("Brouillon privé GPT-Live")
        app.buttons["voice-mode"].tap()
        XCTAssertTrue(app.staticTexts["Je vous écoute."].waitForExistence(timeout: 40))
        XCTAssertTrue(app.staticTexts["Hermes vous répond."].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["voice-transcript-toggle"].exists)
        XCTAssertFalse(app.otherElements["voice-error"].exists)
        app.buttons["voice-listen"].tap()
        XCTAssertTrue(app.staticTexts["Micro coupé"].waitForExistence(timeout: 5))
        capture("60-gpt-live-stone")
        app.buttons["return-to-chat"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, "Brouillon privé GPT-Live")
        // The header may reuse the first user message as the conversation title.
        XCTAssertEqual(app.scrollViews.staticTexts.matching(identifier: "Bonjour Hermes, résume mon projet en français.").count, 1)
        app.buttons["voice-mode"].tap()
        XCTAssertTrue(app.buttons["voice-engine"].waitForExistence(timeout: 5))
        app.buttons["return-to-chat"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
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
        XCTAssertFalse(app.buttons["voice-transcript-toggle"].exists)
        capture("44-voice-muted")
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
        // The pill holds the plus, the field and one trailing button (voice while empty, send once there is text);
        // navigation and agent controls live in the header above it.
        XCTAssertTrue(app.buttons["message-actions"].exists)
        XCTAssertTrue(surface.frame.contains(app.buttons["message-actions"].frame), "message-actions belongs inside the composer pill")
        XCTAssertTrue(app.buttons["voice-mode"].exists || app.buttons["send-message"].exists)
        for identifier in ["switch-profile", "app-navigation"] {
            XCTAssertLessThan(app.buttons[identifier].frame.maxY, surface.frame.minY, "\(identifier) belongs in the header")
        }
    }
}
