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
        guard case .choices(let quick)? = ChatCard.parse("{\"type\":\"choix\",\"options\":[\"Oui\",{\"label\":\"Plus tard\",\"reply\":\"Rappelle-moi demain\"}]}") else { return XCTFail() }
        XCTAssertEqual(quick.questions[0].options.map(\.label), ["Oui", "Plus tard"])
        XCTAssertEqual(quick.questions[0].options.map(\.reply), ["Oui", "Rappelle-moi demain"], "a label can send another sentence")
        XCTAssertTrue(quick.isQuick, "short follow-ups stay quick-reply pills")
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

    func testChartReadsPointsInEveryShapeAndNeedsTwo() {
        let json = """
        {"type":"graphique","title":"MRR Glutax","style":"bar","unit":"$","delta":"+8 %","goal":"4 000",
         "points":[{"label":"mai","value":3200},{"x":"juin","y":"3 450"},3600,{"label":"août"}]}
        """
        guard case .chart(let chart)? = ChatCard.parse(json) else { return XCTFail() }
        XCTAssertTrue(chart.bars); XCTAssertEqual(chart.unit, "$"); XCTAssertEqual(chart.trend, .up); XCTAssertEqual(chart.goal, 4000)
        XCTAssertEqual(chart.points.map(\.value), [3200, 3450, 3600], "a point without a value is dropped")
        XCTAssertEqual(chart.points.map(\.label), ["mai", "juin", "3"], "a bare number is labelled by its position")
        XCTAssertNil(ChatCard.parse("{\"type\":\"chart\",\"points\":[1]}"), "one point is not a chart")
        let many = (0..<60).map(String.init).joined(separator: ",")
        guard case .chart(let long)? = ChatCard.parse("{\"type\":\"chart\",\"points\":[\(many)]}") else { return XCTFail() }
        XCTAssertEqual(long.points.count, ChatCard.maxPoints); XCTAssertFalse(long.bars)
    }

    func testProgressListAndAgenda() {
        let goals = "{\"type\":\"macros\",\"items\":[{\"label\":\"Calories\",\"value\":1850,\"goal\":2400,\"unit\":\"kcal\"},{\"label\":\"Eau\",\"value\":1,\"goal\":0},{\"label\":\"Protéines\",\"value\":\"120\",\"target\":160}]}"
        guard case .progress(_, let items)? = ChatCard.parse(goals) else { return XCTFail() }
        XCTAssertEqual(items.map(\.label), ["Calories", "Protéines"], "a goal of zero is dropped")
        XCTAssertEqual(items[0].progress, 1850.0 / 2400, accuracy: 0.0001)

        let rows = """
        {"type":"dépenses","title":"Octobre","items":[{"title":"AWS","value":"84,20 $","icon":"server.rack","tone":"negative","reply":"Détaille AWS"},
         {"name":"Figma","icon":"<script>","tone":"bizarre","url":"https://figma.com"},{"subtitle":"sans titre"}],"total":{"value":"1 240 $"}}
        """
        guard case .list(let title, let list, let total)? = ChatCard.parse(rows) else { return XCTFail() }
        XCTAssertEqual(title, "Octobre"); XCTAssertEqual(list.count, 2, "a row needs a title")
        XCTAssertEqual(list[0].icon, "server.rack"); XCTAssertEqual(list[0].tone, .negative); XCTAssertEqual(list[0].reply, "Détaille AWS")
        XCTAssertEqual(list[1].icon, "", "only an SF Symbol name is kept"); XCTAssertEqual(list[1].tone, .neutral); XCTAssertEqual(list[1].url?.host, "figma.com")
        XCTAssertEqual(total, ChatCard.Stat(id: 0, label: "Total", value: "1 240 $"))

        let day = "{\"type\":\"journée\",\"items\":[{\"title\":\"Quart de jour\",\"start\":\"2026-10-29T07:00\",\"end\":\"2026-10-29T19:00\",\"calendar\":\"Travail\"},{\"title\":\"Sans heure\"}]}"
        guard case .agenda(_, let slots)? = ChatCard.parse(day) else { return XCTFail() }
        XCTAssertEqual(slots.count, 1, "a slot needs a start")
        XCTAssertEqual(ChatCard.minutes("2026-10-29T07:00"), 420)
        XCTAssertEqual(ChatCard.minutes("2026-10-29 17:45:00"), 1065)
        XCTAssertEqual(ChatCard.minutes("7 h 30"), 450); XCTAssertEqual(ChatCard.minutes("17h"), 1020)
        XCTAssertNil(ChatCard.minutes("2026-10-29"), "a bare date has no time"); XCTAssertNil(ChatCard.minutes("jeudi")); XCTAssertNil(ChatCard.minutes("25:00"))
    }

    func testWorkoutAndRoute() {
        let workout = """
        {"type":"séance","title":"Push","stats":[{"label":"Volume","value":"8 450 kg"},{"label":"","value":"x"}],
         "exercises":[{"name":"Développé couché","sets":"4 × 8","weight":"80 kg","done":true,"note":"Record"},{"name":"Dips","sets":3},{"sets":"3 × 10"}]}
        """
        guard case .workout(let session)? = ChatCard.parse(workout) else { return XCTFail() }
        XCTAssertEqual(session.stats.map(\.value), ["8 450 kg"]); XCTAssertEqual(session.exercises.count, 2)
        XCTAssertEqual(session.exercises[0].done, true); XCTAssertNil(session.exercises[1].done, "no flag means planned, not missed")
        XCTAssertEqual(session.exercises[1].sets, "3")

        let path = (0..<1_000).map { "[\(45.37 + Double($0) * 0.0001),-73.56]" }.joined(separator: ",")
        guard case .route(let route)? = ChatCard.parse("{\"type\":\"parcours\",\"points\":[\(path),[200,0],{\"lat\":45.5,\"lon\":-73.5}]}") else { return XCTFail() }
        XCTAssertEqual(route.points.count, ChatCard.maxRoutePoints, "a long track is sampled")
        XCTAssertEqual(route.points.first, ChatCard.Coordinate(latitude: 45.37, longitude: -73.56), "the start is kept")
        XCTAssertEqual(route.points.last, ChatCard.Coordinate(latitude: 45.5, longitude: -73.5), "the end is kept, the impossible point dropped")
        XCTAssertNil(ChatCard.parse("{\"type\":\"route\",\"points\":[[45,-73]]}"))
    }

    func testReviewEdgeCases() {
        // A long series keeps its newest points.
        let series = (1...40).map { "{\"label\":\"j\($0)\",\"value\":\($0)}" }.joined(separator: ",")
        guard case .chart(let chart)? = ChatCard.parse("{\"type\":\"chart\",\"points\":[\(series)]}") else { return XCTFail() }
        XCTAssertEqual(chart.points.first?.label, "j10"); XCTAssertEqual(chart.points.last?.label, "j40")

        // Times are read on the phone's clock, whatever the offset written.
        let utc = "2026-10-29T10:45:00Z"
        let local = Calendar.current.dateComponents([.hour, .minute], from: ISO8601DateFormatter().date(from: utc)!)
        XCTAssertEqual(ChatCard.minutes(utc), local.hour! * 60 + local.minute!)
        XCTAssertNotNil(ChatCard.date("2026-10-29T06:45:00.123456-04:00"), "fractions of a second")
        XCTAssertEqual(ChatCard.minutes("07:00 - 15:00"), 420); XCTAssertEqual(ChatCard.minutes("8:00 (matin)"), 480)
        XCTAssertEqual(ChatCard.minutes("5:30 PM"), 1050); XCTAssertEqual(ChatCard.minutes("12:15 am"), 15)
        XCTAssertNil(ChatCard.minutes("7:5")); XCTAssertNil(ChatCard.minutes("25:00"))
        XCTAssertEqual(ChatCard.day("2026-10-29T07:00"), "2026-10-29"); XCTAssertNil(ChatCard.day("07:00"))

        // A shift that spans a meeting stays busy; free time starts at the latest end of the day.
        let slots = [("Quart", "2026-10-29T06:45", "2026-10-29T15:00"), ("Réunion", "2026-10-29T10:00", "2026-10-29T10:30"),
                     ("Dîner", "2026-10-29T12:00", "2026-10-29T13:00"), ("Barbier", "2026-10-29T17:00", "2026-10-29T17:45"),
                     ("Nuit", "2026-10-30T19:00", "2026-10-31T07:00"), ("Tard", "2026-10-30T23:00", "")]
            .enumerated().map { ChatCard.Slot(id: $0.offset, title: $0.element.0, start: $0.element.1, end: $0.element.2, location: "", calendar: "") }
        XCTAssertEqual(ChatCard.freeTime(slots), [3: 120], "no free time inside the shift, none across days, none after a night shift")

        // Numbers as people write them; a huge one never crashes.
        let rows = "{\"type\":\"list\",\"items\":[{\"title\":\"A\",\"value\":1e300},{\"title\":\"B\",\"value\":10000000000000000000}],\"total\":{\"value\":12}}"
        guard case .list(_, let list, let total)? = ChatCard.parse(rows) else { return XCTFail() }
        XCTAssertEqual(list.count, 2); XCTAssertEqual(total?.value, "12")
        let goals = """
        {"type":"progress","items":[{"label":"Pas","value":"4,000","goal":"10,000"},{"label":"Budget","value":"1,234.56","goal":"2 000"},{"label":"Poids","value":"−5,2 kg","goal":"8,5"}]}
        """
        guard case .progress(_, let parsed)? = ChatCard.parse(goals) else { return XCTFail() }
        XCTAssertEqual(parsed.map(\.value), [4000, 1234.56, 0], "a negative value is shown as nothing done")
        XCTAssertEqual(parsed.map(\.goal), [10000, 2000, 8.5])
        XCTAssertNil(ChatCard.parse("{\"type\":\"chart\",\"points\":[\"\(String(repeating: "9", count: 400))\",\"\(String(repeating: "9", count: 400))\"]}"),
                     "infinite values are not points")

        // A GPS dropout at 0,0 is not part of the run.
        guard case .route(let route)? = ChatCard.parse("{\"type\":\"route\",\"points\":[[45.37,-73.56],[0,0],[45.38,-73.55]]}") else { return XCTFail() }
        XCTAssertEqual(route.points.count, 2)
    }

    func testNewsAcceptsTheToolsOwnKeysAndTheBriefKeepsItsSections() {
        let news = """
        {"type":"nouvelles","title":"À la une","articles":[{"titre":"Nos ponts arrivent-ils en fin de vie?","source":"Le Reflet","url":"https://www.lereflet.qc.ca/a","image":"https://img.example/p.jpg","il_y_a":"il y a 4 h","resume":"Le pont Mercier…"},
         {"title":"Sans lien"},{"title":"Lien http","url":"http://example.com"}]}
        """
        guard case .news(let title, let articles)? = ChatCard.parse(news) else { return XCTFail() }
        XCTAssertEqual(title, "À la une"); XCTAssertEqual(articles.map(\.title), ["Nos ponts arrivent-ils en fin de vie?", "Lien http"], "an article needs a web link")
        XCTAssertEqual(articles[0].source, "Le Reflet"); XCTAssertEqual(articles[0].time, "il y a 4 h"); XCTAssertEqual(articles[0].summary, "Le pont Mercier…")

        let brief = """
        {"type":"matin","greeting":"Bonjour Maxime","date":"Jeudi 29 octobre","weather":{"temp":7,"condition":"Nuageux","high":9,"low":2},
         "focus":"Une seule chose : la mobilité après le quart.",
         "sections":[{"kind":"quart","title":"Aujourd’hui","items":[{"time":"06:45","text":"Quart de jour","detail":"jusqu’à 15 h"},"Barbier à 17 h"]},
                     {"kind":"nouvelles","items":[{"titre":"Article","url":"https://example.com/a"}]},
                     {"kind":"courriels","text":"Trois à lire, dont la facture AWS."},
                     {"kind":"inconnu"}]}
        """
        guard case .brief(let morning)? = ChatCard.parse(brief) else { return XCTFail() }
        XCTAssertEqual(morning.greeting, "Bonjour Maxime"); XCTAssertEqual(morning.weather?.high, 9)
        XCTAssertEqual(morning.sections.map(\.kind), [.agenda, .news, .email], "an empty section is dropped")
        XCTAssertEqual(morning.sections[0].lines.map(\.text), ["Quart de jour", "Barbier à 17 h"], "a line may be a plain string")
        XCTAssertEqual(morning.sections[0].lines[0].time, "06:45"); XCTAssertEqual(morning.sections[1].articles.count, 1)
        XCTAssertNil(ChatCard.parse("{\"type\":\"brief\",\"greeting\":\"Bonjour\"}"), "a greeting alone is not a summary")
    }

    func testSecondReviewEdgeCases() {
        // Speech follows the renderer's fences exactly.
        XCTAssertEqual(SpokenTextFilter.strip("```npm install``` lance tout.\nPuis la suite."), "```npm install``` lance tout.\nPuis la suite.",
                       "inline triple-backtick code is text")
        XCTAssertEqual(SpokenTextFilter.strip("Avant\n~~~\n```ui\n{\"a\":1}\n```\n~~~\nFin"), "Avant\nFin", "a fence closes only on its own mark")
        XCTAssertEqual(SpokenTextFilter.strip("Code\r\n```ui\r\n{\"a\":1}\r\n```\r\nFin"), "Code\nFin", "CRLF text")
        XCTAssertEqual(SpokenTextFilter.strip("Voici\n\t```ui\n{}\n```\nFin"), "Voici\nFin", "a tab-indented card")
        var chunked = SpokenTextFilter()
        let pieces = ["Bonjour.\n``", "`ui\n{\"type\":", "\"x\"}\n``", "`\nLa suite."]
        XCTAssertEqual(pieces.map { chunked.feed($0) }.joined() + chunked.finish(), "Bonjour.\nLa suite.")

        // Card detection and copy text use the same fences.
        XCTAssertTrue(ChatCard.hasCards("Voir :\n~~~UI\n{}\n~~~")); XCTAssertFalse(ChatCard.hasCards("```ui json\n{}\n```"))
        let reply = "Six dépenses.\n\n```ui\n{\"type\":\"list\",\"title\":\"Octobre\",\"items\":[{\"title\":\"AWS\",\"value\":\"84,20 $\"}],\"total\":\"84,20 $\"}\n```\n\n```python\nprint(1)\n```"
        XCTAssertEqual(ChatCard.plainText(reply), "Six dépenses.\n\nOctobre\nAWS · 84,20 $\nTotal : 84,20 $\n\n```python\nprint(1)\n```")
        XCTAssertEqual(ChatCard.stripCards(reply), "Six dépenses.\n\n\n```python\nprint(1)\n```")

        // Previews: never quotes, code, private hosts or links that act; markup around a link is not part of it.
        let links = ChatCard.links(in: """
        Lis **https://example.com/a** et https://fr.wikipedia.org/wiki/Saint-Constant_(Québec), aussi https://example.com/a/.
        > https://mail.example.com/unsubscribe?u=1
        `https://code.example/x` https://192.168.1.10/admin https://app.example.com/login?next=1 https://news.example.com/2026/apple-keynote
        """, limit: 6)
        XCTAssertEqual(links.map(\.absoluteString), ["https://example.com/a", "https://fr.wikipedia.org/wiki/Saint-Constant_(Qu%C3%A9bec)",
                                                     "https://news.example.com/2026/apple-keynote"])

        // Numbers: the first one written; huge or impossible temperatures never reach the screen.
        guard case .progress(_, let goals)? = ChatCard.parse("{\"type\":\"progress\",\"items\":[{\"label\":\"Protéines\",\"value\":\"128 g\",\"goal\":\"140–160 g\"},{\"label\":\"Kcal\",\"value\":\"1 850 / 2 400 kcal\",\"goal\":2400}]}") else { return XCTFail() }
        XCTAssertEqual(goals.map(\.goal), [140, 2400]); XCTAssertEqual(goals[1].value, 1850)
        guard case .weather(let tool)? = ChatCard.parse("""
        {"type":"weather","lieu":"Saint-Constant","actuel":{"temperature_c":7,"ressenti_c":4,"conditions":"nuageux"},"jours":[{"date":"2026-10-29","conditions":"pluie","max_c":9,"min_c":2}]}
        """) else { return XCTFail("the meteo tool's own keys") }
        XCTAssertEqual(tool.temperature, 7); XCTAssertEqual(tool.days.first?.high, 9); XCTAssertFalse(tool.days.first?.label.isEmpty ?? true)
        guard case .weather(let absurd)? = ChatCard.parse("{\"type\":\"weather\",\"now\":{\"temp\":1e19},\"days\":[{\"day\":\"Mer\",\"high\":9}]}") else { return XCTFail() }
        XCTAssertNil(absurd.temperature)

        // Times with an offset and no seconds, and over midnight.
        let utc = "2026-10-29T10:45Z"
        let expected = Calendar.current.dateComponents([.hour, .minute], from: ISO8601DateFormatter().date(from: "2026-10-29T10:45:00Z")!)
        XCTAssertEqual(ChatCard.minutes(utc), expected.hour! * 60 + expected.minute!)
        XCTAssertNotNil(ChatCard.date("2026-10-29T06:45-04:00")); XCTAssertNil(ChatCard.minutes("2026-10-29Tbonjour"))
        XCTAssertEqual(ChatCard.minutes("2026-10-29T24:00"), 1440)
        let week = [("Garde", "2026-10-29T08:00", "2026-10-30T09:00"), ("Souper", "2026-10-29T20:00", "2026-10-29T21:00")]
            .enumerated().map { ChatCard.Slot(id: $0.offset, title: $0.element.0, start: $0.element.1, end: $0.element.2, location: "", calendar: "") }
        XCTAssertEqual(ChatCard.freeTime(week), [:], "a slot that runs into the next day keeps the evening busy")

        // Places at 0,0 are a placeholder; states as the instructions define them.
        guard case .places(_, let places)? = ChatCard.parse("{\"type\":\"places\",\"items\":[{\"name\":\"Café\",\"address\":\"12 rue X\",\"lat\":0,\"lon\":0}]}") else { return XCTFail() }
        XCTAssertFalse(places[0].hasCoordinate)
        XCTAssertEqual(["arrêté", "stopped", "hors ligne", "stale", "paused"].map(ChatCard.health), [.down, .down, .down, .unknown, .warning])
    }

    func testACardFindsItsCalendarEvent() {
        let day = ChatCard.date("2026-10-29T17:00")!
        let at = { (time: String) in ChatCard.date("2026-10-29T" + time)! }
        let events: [(title: String, start: Date)] = [("Quart de jour", at("06:45")), ("Barbier du Village", at("17:00")),
                                                       ("Souper chez Julie", at("18:30")), ("Barbier", ChatCard.date("2026-10-30T17:00")!)]
        XCTAssertEqual(ChatCard.bestEventMatch(title: "Barbier du Village", start: day, among: events), 1)
        XCTAssertEqual(ChatCard.bestEventMatch(title: "barbier", start: day, among: events), 1, "case, accents and a shorter title")
        XCTAssertEqual(ChatCard.bestEventMatch(title: "Rendez-vous barbier", start: day, among: events), 1, "the only event at that time")
        XCTAssertEqual(ChatCard.bestEventMatch(title: "Souper chez Julie", start: at("19:00"), among: events), 2, "same title, time moved")
        XCTAssertNil(ChatCard.bestEventMatch(title: "Dentiste", start: at("10:00"), among: events), "nothing fits: no guess")
        let twoAtOnce: [(title: String, start: Date)] = [("Réunion A", day), ("Réunion B", day)]
        XCTAssertNil(ChatCard.bestEventMatch(title: "Appel", start: day, among: twoAtOnce), "two events at that time: no guess")
    }

    func testChoicesAskSeveralQuestionsOneAtATime() {
        let json = """
        {"type":"choices","questions":[
          {"prompt":"Quel budget ?","options":[{"label":"Moins de 450 000 $","detail":"Maisons plus anciennes","icon":"dollarsign.circle"},"450 à 500 000 $"]},
          {"question":"Quels secteurs ?","multiple":true,"choices":["Saint-Constant","Delson","Candiac"]},
          {"prompt":"Sans réponse possible","options":[]}],"other":false}
        """
        guard case .choices(let flow)? = ChatCard.parse(json) else { return XCTFail() }
        XCTAssertEqual(flow.questions.map(\.prompt), ["Quel budget ?", "Quels secteurs ?"], "a question needs answers")
        XCTAssertEqual(flow.questions[0].options[0].detail, "Maisons plus anciennes"); XCTAssertEqual(flow.questions[0].options[0].icon, "dollarsign.circle")
        XCTAssertTrue(flow.questions[1].multiple); XCTAssertFalse(flow.other); XCTAssertFalse(flow.isQuick)
        guard case .choices(let single)? = ChatCard.parse("{\"type\":\"choices\",\"prompt\":\"On réserve ?\",\"options\":[\"Oui\",\"Non\"]}") else { return XCTFail() }
        XCTAssertFalse(single.isQuick, "a question asked in words gets the question card"); XCTAssertTrue(single.other)
    }

    func testStatusDerivesTheWholeFromItsParts() {
        let json = """
        {"type":"vps","title":"noriven-prod","gauges":[{"label":"CPU","value":9,"unit":"%"},{"label":"Mémoire","value":2.1,"max":7.8,"unit":"Go"},{"label":"Disque","value":28},{"label":"","value":1,"max":2}],
         "items":[{"name":"Glutax","state":"healthy"},{"name":"Minori","state":"running"},{"name":"Sauvegardes","state":"unchecked","detail":"Contrôle absent"},{"state":"ok"}]}
        """
        guard case .status(let status)? = ChatCard.parse(json) else { return XCTFail() }
        XCTAssertEqual(status.gauges.map(\.label), ["CPU", "Mémoire"], "a gauge needs a label and a maximum (or a percentage)")
        XCTAssertEqual(status.gauges[0].fraction, 0.09, accuracy: 0.0001)
        XCTAssertEqual(status.items.map(\.state), [.ok, .ok, .unknown], "an item needs a name")
        XCTAssertEqual(status.state, .warning, "something unchecked next to healthy services needs a look")
        guard case .status(let down)? = ChatCard.parse("{\"type\":\"status\",\"items\":[{\"name\":\"API\",\"state\":\"unhealthy\"},{\"name\":\"Web\",\"state\":\"ok\"}]}") else { return XCTFail() }
        XCTAssertEqual(down.state, .down)
        guard case .status(let full)? = ChatCard.parse("{\"type\":\"status\",\"state\":\"ok\",\"gauges\":[{\"label\":\"Disque\",\"value\":95,\"max\":100}]}") else { return XCTFail() }
        XCTAssertEqual(full.state, .ok, "the agent's own verdict wins")
        guard case .status(let busy)? = ChatCard.parse("{\"type\":\"status\",\"gauges\":[{\"label\":\"Disque\",\"value\":120,\"max\":100}]}") else { return XCTFail() }
        XCTAssertEqual(busy.state, .warning); XCTAssertEqual(busy.gauges[0].fraction, 1)
        XCTAssertNil(ChatCard.parse("{\"type\":\"status\",\"title\":\"vide\"}"))
    }
}
