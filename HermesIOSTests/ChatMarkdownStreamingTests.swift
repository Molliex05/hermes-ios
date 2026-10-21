import XCTest
@testable import HermesIOSCore

final class ChatMarkdownStreamingTests: XCTestCase {
    private let samples = [
        "## Titre\n\nTexte **fort**\n\n3. Trois\n  - Enfant\n- [x] Fait\n> Citation\n---\n\nFin.",
        "- un\n\n  suite de un\n\n- deux\n\nParagraphe après.\n\n```swift\nlet x = 1\n\nlet y = 2\n```\n\nAprès le code.",
        "# a | b\n|---|---|\n| 1 | 2 |\n\nTexte | avec barre\n| --- |\n\n> q1\n> q2\n\nÉté 👋 é\u{301}\n\n~~~~\n a\n\n~~~~\n\n***\n\nFin",
        "Ligne\r\n\r\nAutre ligne\r\n- item\r\n\r\n  suite\r\n",
        "````md\n```swift\n````\nAprès\n\n1) un\n2) deux\n\n\n\n   indenté\n\nfin",
        "",
        "\n\n\nTexte\n\n",
    ]

    func testStreamingMatchesFullParseAtEveryPrefix() {
        for sample in samples {
            var streaming = StreamingMarkdown()
            var prefix = ""
            for character in sample {
                prefix.append(character)
                XCTAssertEqual(streaming.update(prefix), ChatMarkdown.parse(prefix), "prefix: \(prefix.debugDescription)")
            }
        }
    }

    func testStreamingMatchesFullParseByChunksAndReplacement() {
        for sample in samples {
            var streaming = StreamingMarkdown()
            var prefix = ""
            var chunk = ""
            for character in sample {
                chunk.append(character)
                if chunk.count == 7 { prefix += chunk; chunk = ""; XCTAssertEqual(streaming.update(prefix), ChatMarkdown.parse(prefix)) }
            }
            prefix += chunk
            XCTAssertEqual(streaming.update(prefix), ChatMarkdown.parse(prefix))
            // message.complete / hydration may replace the text entirely.
            let replaced = "Réponse finale\n\n" + sample.uppercased()
            XCTAssertEqual(streaming.update(replaced), ChatMarkdown.parse(replaced))
            XCTAssertEqual(streaming.update(""), [])
        }
    }

    func testEditInsideStablePrefixFallsBackToFullParse() {
        var streaming = StreamingMarkdown()
        let first = "Un\n\nDeux\n\nTrois"
        XCTAssertEqual(streaming.update(first), ChatMarkdown.parse(first))
        let edited = "Ux\n\nDeux\n\nTrois et plus"
        XCTAssertEqual(streaming.update(edited), [.paragraph("Ux"), .paragraph("Deux"), .paragraph("Trois et plus")])
    }

    func testCheckpointSkipsIndentedContinuationAndOpenFence() {
        XCTAssertEqual(ChatMarkdown.parseDetailed("- a\n\n  b").checkpoint, nil)
        XCTAssertEqual(ChatMarkdown.parseDetailed("```\nx\n\ny").checkpoint, nil)
        XCTAssertEqual(ChatMarkdown.parseDetailed("Été\n\nFin").checkpoint, .init(utf8Offset: 7, blockCount: 1))
    }

    func testCodeChunksRoundTrip() {
        let code = (1...95).map { "ligne \($0) é" }.joined(separator: "\n")
        let chunks = ChatMarkdown.codeChunks(code, lines: 40)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.joined(separator: "\n"), code)
        XCTAssertEqual(ChatMarkdown.codeChunks(""), [""])
        XCTAssertEqual(ChatMarkdown.codeChunks("a\n"), ["a\n"])
    }

    func testUTF8Comparisons() {
        XCTAssertTrue(ChatMarkdown.sameUTF8("é👋", "é👋"))
        XCTAssertFalse(ChatMarkdown.sameUTF8("é", "e\u{301}"))
        XCTAssertTrue(ChatMarkdown.sameUTF8Prefix("abc", "abd", count: 2))
        XCTAssertFalse(ChatMarkdown.sameUTF8Prefix("ab", "abd", count: 3))
        XCTAssertTrue(ChatMarkdown.sameUTF8Prefix("", "", count: 0))
    }

    @MainActor func testCacheValidatesTextAndEvicts() {
        let cache = MarkdownCache(capacity: 4)
        XCTAssertEqual(cache.blocks(id: "a", text: "Un"), [.paragraph("Un")])
        XCTAssertEqual(cache.blocks(id: "a", text: "Un\n\nDeux"), [.paragraph("Un"), .paragraph("Deux")])
        XCTAssertEqual(cache.blocks(id: "a", text: "Autre"), [.paragraph("Autre")])
        for index in 0..<20 { XCTAssertEqual(cache.blocks(id: "m\(index)", text: "# \(index)"), [.heading(1, "\(index)")]) }
        XCTAssertEqual(cache.blocks(id: "a", text: "Autre"), [.paragraph("Autre")])
    }
}
