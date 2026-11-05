import XCTest
@testable import HermesIOSCore

final class VoiceProgressTests: XCTestCase {
    private func step(_ name: String) -> Transcript.ToolStep { Transcript.ToolStep(id: name, name: name, state: .running) }

    func testKnownToolsSayWhatTheyDo() {
        XCTAssertEqual(VoiceProgress.line(for: step("agenda_creer")), .init(clip: "agenda-ajout", text: "J’ajoute ça à ton agenda."))
        XCTAssertEqual(VoiceProgress.line(for: step("widget_publier"))?.text, "Je mets ton widget à jour.")
        XCTAssertEqual(VoiceProgress.line(for: step("mcp__noriven__finance_list_accounts"))?.clip, "comptes")
        XCTAssertNil(VoiceProgress.line(for: step("terminal")), "an unknown tool says nothing it cannot back")
    }

    func testEveryLineHasItsRecording() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HermesIOS/Resources/Progress")
        for clip in VoiceProgress.lines.keys {
            let size = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(clip + ".pcm").path)[.size] as? Int ?? 0
            XCTAssertGreaterThan(size, 24_000, "\(clip): at least half a second of 24 kHz 16-bit audio")
        }
    }
}
