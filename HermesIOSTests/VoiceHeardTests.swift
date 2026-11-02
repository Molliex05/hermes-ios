import XCTest
@testable import HermesIOSCore

final class VoiceHeardTests: XCTestCase {
    func testInventionsFromNoiseAreNoMessage() {
        for text in ["Yep.", "yep", " Yeah! ", "Thank you.", "Merci d'avoir regardé !", "Sous-titres réalisés par la communauté d'Amara.org",
                     "Hmm…", "euh", "", "   ", "a"] {
            XCTAssertTrue(VoiceHeard.isNoise(text), text)
        }
    }

    func testRealAnswersStay() {
        for text in ["Oui", "Non.", "OK", "Merci", "Ajoute mon quart demain", "C'est quoi la météo ?"] {
            XCTAssertFalse(VoiceHeard.isNoise(text), text)
        }
    }

    func testOnlyRealWordsCutTheAgentOff() {
        XCTAssertFalse(VoiceHeard.confirmsInterruption("Yep."))
        XCTAssertFalse(VoiceHeard.confirmsInterruption("Merci"), "one stray word is not an interruption")
        XCTAssertTrue(VoiceHeard.confirmsInterruption("Attends."))
        XCTAssertTrue(VoiceHeard.confirmsInterruption("Arrête"))
        XCTAssertTrue(VoiceHeard.confirmsInterruption("Non, pas celui-là"))
        XCTAssertTrue(VoiceHeard.confirmsInterruption("Et demain ?"))
    }
}
