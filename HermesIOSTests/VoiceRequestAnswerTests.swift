import XCTest
@testable import HermesIOSCore

final class VoiceRequestAnswerTests: XCTestCase {
    func testYes() {
        for said in ["Oui", "oui.", "Je t’autorise", "je t'autorise", "Vas-y", "OK go", "D’accord", "ouais c'est bon", "Oui, pas de problème", "Accepte"] {
            XCTAssertEqual(VoiceRequestAnswer.approval(said), .approve, said)
        }
    }

    func testNo() {
        for said in ["Non", "non merci", "Je refuse", "Je ne t'autorise pas", "Annule", "pas question", "Jamais de la vie"] {
            XCTAssertEqual(VoiceRequestAnswer.approval(said), .deny, said)
        }
    }

    func testUnclearIsNoAnswer() {
        XCTAssertNil(VoiceRequestAnswer.approval(""))
        XCTAssertNil(VoiceRequestAnswer.approval("oui non"), "both")
        XCTAssertNil(VoiceRequestAnswer.approval("C'est quoi cette commande ?"))
        XCTAssertNil(VoiceRequestAnswer.approval(VoiceRequestAnswer.approvalQuestion(agent: "Jarvis")), "its own question, heard back, is never an answer")
        XCTAssertNil(VoiceRequestAnswer.approval("oui mais attends je voulais d'abord te demander quelque chose sur la paie de jeudi"), "too long")
    }

    func testChoices() {
        let choices = ["Costco Candiac", "Maxi Delson", "IGA Saint-Constant"]
        XCTAssertEqual(VoiceRequestAnswer.choice("Maxi Delson", among: choices), "Maxi Delson")
        XCTAssertEqual(VoiceRequestAnswer.choice("le Costco", among: choices), "Costco Candiac")
        XCTAssertEqual(VoiceRequestAnswer.choice("la deuxième", among: choices), "Maxi Delson")
        XCTAssertEqual(VoiceRequestAnswer.choice("3", among: choices), "IGA Saint-Constant")
        XCTAssertNil(VoiceRequestAnswer.choice("aucune idée", among: choices))
        XCTAssertNil(VoiceRequestAnswer.choice("le premier ou le deuxième", among: choices), "two ranks")
        XCTAssertEqual(VoiceRequestAnswer.choice("Oui", among: ["Oui", "Non"]), "Oui")
    }

    func testQuestionsAreSpeakable() {
        XCTAssertTrue(VoiceRequestAnswer.approvalQuestion(agent: "Jarvis").hasPrefix("Jarvis demande votre accord"))
        XCTAssertEqual(VoiceRequestAnswer.choiceQuestion("Quelle épicerie ?", choices: ["Maxi", "IGA", "Costco"]), "Quelle épicerie ? Maxi, IGA ou Costco ?")
        XCTAssertEqual(VoiceRequestAnswer.choiceQuestion("Pour quand ?", choices: []), "Pour quand ?")
    }
}
