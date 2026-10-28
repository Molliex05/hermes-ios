import XCTest
@testable import HermesIOSCore

final class ChatCardsTests: XCTestCase {
    func testAUIFenceBecomesACardAndStreamsAsIncomplete() {
        let reply = "Voici trois options.\n\n```ui\n{\"type\":\"carousel\",\"items\":[{\"title\":\"A\"}]}\n```\n\nBonne soirée."
        let blocks = ChatMarkdown.parse(reply)
        XCTAssertEqual(blocks.count, 3)
        guard case .card(let json, let complete) = blocks[1] else { return XCTFail("expected a card") }
        XCTAssertTrue(complete); XCTAssertNotNil(ChatCard.parse(json))
        guard case .card(_, let streaming) = ChatMarkdown.parse("Voici :\n\n```ui\n{\"type\":\"carou").last else { return XCTFail() }
        XCTAssertFalse(streaming, "an unfinished fence is still streaming")
        guard case .code(let language, _) = ChatMarkdown.parse("```swift\nlet a = 1\n```").first else { return XCTFail() }
        XCTAssertEqual(language, "swift", "ordinary code stays code")
    }

    func testCarouselKeepsOnlySafeLinksAndBoundsItems() {
        let items = (0..<20).map { "{\"title\":\"Maison \($0)\",\"price\":\"450 000 $\",\"image\":\"https://img.example/\($0).jpg\",\"url\":\"https://example.com/\($0)\",\"badges\":[\"3 ch.\",\"2 sdb\"]}" }
        let json = "{\"type\":\"annonces\",\"title\":\"Maisons\",\"items\":[\(items.joined(separator: ","))]}"
        guard case .carousel(let title, let parsed)? = ChatCard.parse(json) else { return XCTFail() }
        XCTAssertEqual(title, "Maisons"); XCTAssertEqual(parsed.count, ChatCard.maxItems)
        XCTAssertEqual(parsed[0].badges, ["3 ch.", "2 sdb"]); XCTAssertEqual(parsed[0].url?.host, "example.com")
        let unsafe = "{\"type\":\"carousel\",\"items\":[{\"title\":\"X\",\"url\":\"javascript:alert(1)\",\"image\":\"file:///etc/passwd\"}]}"
        guard case .carousel(_, let risky)? = ChatCard.parse(unsafe) else { return XCTFail() }
        XCTAssertNil(risky[0].url); XCTAssertNil(risky[0].image)
    }

    func testPlacesAcceptCoordinatesOrAnAddress() {
        let json = """
        {"type":"lieux","items":[{"name":"Barbier Saint-Constant","address":"12 rue Principale, Saint-Constant","note":"Ouvert jusqu'à 18 h"},
        {"name":"Café","lat":"45.36","lon":-73.57},{"name":"Nulle part","lat":120,"lon":0},{}]}
        """
        guard case .places(_, let places)? = ChatCard.parse(json) else { return XCTFail() }
        XCTAssertEqual(places.count, 3, "an empty entry is dropped")
        XCTAssertFalse(places[0].hasCoordinate); XCTAssertEqual(places[0].query, "Barbier Saint-Constant, 12 rue Principale, Saint-Constant")
        XCTAssertEqual(places[1].latitude, 45.36); XCTAssertTrue(places[1].hasCoordinate)
        XCTAssertFalse(places[2].hasCoordinate, "an impossible latitude is ignored, the name is kept")
    }

    func testChoicesMetricsWeatherEventAndLinks() {
        guard case .choices(_, let options)? = ChatCard.parse("{\"type\":\"choix\",\"options\":[\"Oui\",{\"label\":\"Plus tard\",\"reply\":\"Rappelle-moi demain\"}]}") else { return XCTFail() }
        XCTAssertEqual(options, ["Oui", "Rappelle-moi demain"])
        guard case .metrics(_, let metrics)? = ChatCard.parse("{\"type\":\"chiffres\",\"items\":[{\"label\":\"Revenu\",\"value\":12400,\"delta\":\"+8 %\"},{\"label\":\"Profit\",\"value\":\"3 100 $\",\"delta\":\"-2 %\"}]}") else { return XCTFail() }
        XCTAssertEqual(metrics[0].value, "12400"); XCTAssertEqual(metrics[0].trend, .up); XCTAssertEqual(metrics[1].trend, .down)
        guard case .weather(let weather)? = ChatCard.parse("{\"type\":\"météo\",\"place\":\"Saint-Constant\",\"now\":{\"temp\":\"7 °C\",\"condition\":\"Averses\"},\"days\":[{\"day\":\"Mer\",\"high\":9,\"low\":2,\"condition\":\"Soleil\"}]}") else { return XCTFail() }
        XCTAssertEqual(weather.temperature, 7); XCTAssertEqual(weather.days.first?.high, 9)
        XCTAssertEqual(ChatCard.weatherSymbol(weather.condition), "cloud.rain.fill")
        XCTAssertEqual(ChatCard.weatherSymbol("Partiellement nuageux"), "cloud.sun.fill")
        guard case .event(let event)? = ChatCard.parse("{\"type\":\"event\",\"title\":\"Barbier\",\"start\":\"2026-10-30T17:00\",\"location\":\"Saint-Constant\"}") else { return XCTFail() }
        XCTAssertEqual(event.title, "Barbier")
        guard case .links(_, let links)? = ChatCard.parse("{\"type\":\"liens\",\"items\":[\"https://a.example\",{\"url\":\"http://b.example/x\",\"title\":\"B\"},\"ftp://c\"]}") else { return XCTFail() }
        XCTAssertEqual(links.map(\.url.host), ["a.example", "b.example"])
    }

    func testBrokenCardsAreDroppedNotShown() {
        XCTAssertNil(ChatCard.parse("{\"type\":\"carousel\""))
        XCTAssertNil(ChatCard.parse("{\"type\":\"inconnu\",\"items\":[1]}"))
        XCTAssertNil(ChatCard.parse("{\"type\":\"carousel\",\"items\":[]}"))
        XCTAssertNil(ChatCard.parse("[1,2]"))
    }

    func testLinksAreFoundOutsideCodeAndCards() {
        let reply = """
        Lis https://example.com/article. Et aussi (https://other.example/a?b=1).

        ```
        https://code.example
        ```

        ```ui
        {"type":"links","items":["https://card.example"]}
        ```
        - https://example.com/article
        """
        XCTAssertEqual(ChatCard.links(in: reply).map(\.absoluteString), ["https://example.com/article", "https://other.example/a?b=1"])
    }

    // MARK: speech

    func testFencedBlocksAreNeverSpoken() {
        let reply = "Voici les options.\n\n```ui\n{\"type\":\"carousel\"}\n```\n\nJe te laisse choisir."
        XCTAssertEqual(SpokenTextFilter.strip(reply), "Voici les options.\n\n\nJe te laisse choisir.")
        XCTAssertEqual(SpokenTextFilter.strip("Du code :\n```swift\nlet a = 1\n```\nFin."), "Du code :\nFin.")
        XCTAssertEqual(SpokenTextFilter.strip("Un `inline` reste lu."), "Un `inline` reste lu.")
    }

    func testTheFilterGivesTheSameResultWhateverTheChunking() {
        let reply = "Bonjour !\n  ```ui\n{\"a\":1}\n  ```\nSuite du texte, avec ``deux`` accents.\n~~~\nx\n~~~\nFin"
        let expected = SpokenTextFilter.strip(reply)
        XCTAssertFalse(expected.contains("{")); XCTAssertTrue(expected.hasSuffix("Fin"))
        let characters = Array(reply)
        for size in 1...7 {
            var filter = SpokenTextFilter(), out = ""
            for start in stride(from: 0, to: characters.count, by: size) {
                out += filter.feed(String(characters[start..<min(start + size, characters.count)]))
            }
            out += filter.finish()
            XCTAssertEqual(out, expected, "chunk size \(size)")
        }
    }

    func testSpeechIsNotHeldBackOnOrdinaryText() {
        var filter = SpokenTextFilter()
        XCTAssertEqual(filter.feed("Il fera beau"), "Il fera beau", "text that cannot open a fence passes at once")
        XCTAssertEqual(filter.feed(" demain."), " demain.")
    }
}
