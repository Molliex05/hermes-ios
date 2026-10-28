import Foundation

/// Rich answer cards. In a text conversation the agent may add a small JSON object in a ```ui fence; the app draws it
/// natively (a carousel of products or listings, places on a map, quick replies, figures, the weather, an event, links).
/// Everything is validated here: web links only (http/https), bounded counts and lengths. Anything unreadable is dropped,
/// never shown as raw JSON. No server change: the format is taught to the agent in its instructions.
enum ChatCard: Equatable {
    struct Item: Equatable, Identifiable {
        let id: Int
        let title: String, subtitle: String, price: String
        let image: URL?, url: URL?
        let badges: [String]
        let rating: Double?
    }
    struct Place: Equatable, Identifiable {
        let id: Int
        let name: String, address: String, note: String, phone: String
        let latitude: Double?, longitude: Double?
        let url: URL?
        var hasCoordinate: Bool { latitude != nil && longitude != nil }
        /// What to look up on the map when no coordinate is given.
        var query: String { [name, address].filter { !$0.isEmpty }.joined(separator: ", ") }
    }
    enum Trend: String, Equatable { case up, down, flat }
    struct Metric: Equatable, Identifiable {
        let id: Int
        let label: String, value: String, delta: String
        let trend: Trend
    }
    struct Day: Equatable, Identifiable {
        let id: Int
        let label: String, condition: String
        let high: Double?, low: Double?
    }
    struct Weather: Equatable {
        let place: String, condition: String
        let temperature: Double?, feelsLike: Double?
        let days: [Day]
    }
    struct Event: Equatable {
        let title: String, start: String, end: String, location: String, calendar: String
        let url: URL?
    }
    struct Link: Equatable, Identifiable {
        let id: Int
        let url: URL
        let title: String
    }

    case carousel(title: String, items: [Item])
    case places(title: String, items: [Place])
    case choices(prompt: String, options: [String])
    case metrics(title: String, items: [Metric])
    case weather(Weather)
    case event(Event)
    case links(title: String, items: [Link])

    static let maxItems = 12

    static func isCardFence(_ language: String) -> Bool {
        ["ui", "hermes-ui", "card", "carte"].contains(language.trimmingCharacters(in: .whitespaces).lowercased())
    }

    static func parse(_ text: String) -> ChatCard? {
        guard let json = try? JSONValue.decode(Data(text.utf8)), !json.object.isEmpty else { return nil }
        let title = clean(json["title"].string, 80)
        switch kind(json["type"].string) {
        case "carousel":
            let items = list(json["items"]).enumerated().compactMap { index, value -> Item? in
                let name = clean(value["title"].string.isEmpty ? value["name"].string : value["title"].string, 90)
                guard !name.isEmpty || webURL(value["url"].string) != nil else { return nil }
                return Item(id: index, title: name, subtitle: clean(value["subtitle"].string, 120), price: clean(value["price"].string, 30),
                            image: webURL(value["image"].string), url: webURL(value["url"].string),
                            badges: list(value["badges"]).map { clean($0.string, 24) }.filter { !$0.isEmpty }.prefix(4).map { $0 },
                            rating: number(value["rating"]).map { min(5, max(0, $0)) })
            }
            return items.isEmpty ? nil : .carousel(title: title, items: items)
        case "places":
            let items = list(json["items"]).enumerated().compactMap { index, value -> Place? in
                let name = clean(value["name"].string.isEmpty ? value["title"].string : value["name"].string, 80)
                let address = clean(value["address"].string, 140)
                let lat = number(value["lat"]) ?? number(value["latitude"]), lon = number(value["lon"]) ?? number(value["lng"]) ?? number(value["longitude"])
                let valid = lat.map { (-90...90).contains($0) } ?? false && lon.map { (-180...180).contains($0) } ?? false
                guard !name.isEmpty || !address.isEmpty || valid else { return nil }
                return Place(id: index, name: name, address: address, note: clean(value["note"].string, 120), phone: clean(value["phone"].string, 30),
                             latitude: valid ? lat : nil, longitude: valid ? lon : nil, url: webURL(value["url"].string))
            }
            return items.isEmpty ? nil : .places(title: title, items: items)
        case "choices":
            let options = list(json["options"]).compactMap { value -> String? in
                let text = clean(value.string.isEmpty ? (value["reply"].string.isEmpty ? value["label"].string : value["reply"].string) : value.string, 80)
                return text.isEmpty ? nil : text
            }
            return options.isEmpty ? nil : .choices(prompt: clean(json["prompt"].string, 120), options: Array(options.prefix(6)))
        case "metrics":
            let items = list(json["items"]).enumerated().compactMap { index, value -> Metric? in
                let label = clean(value["label"].string, 40), shown = clean(display(value["value"]), 30)
                guard !label.isEmpty, !shown.isEmpty else { return nil }
                let trend = Trend(rawValue: value["trend"].string.lowercased()) ?? inferTrend(value["delta"])
                return Metric(id: index, label: label, value: shown, delta: clean(display(value["delta"]), 24), trend: trend)
            }
            return items.isEmpty ? nil : .metrics(title: title, items: Array(items.prefix(8)))
        case "weather":
            let now = json["now"].isNull ? json : json["now"]
            let days = list(json["days"]).enumerated().compactMap { index, value -> Day? in
                let label = clean(value["day"].string.isEmpty ? value["label"].string : value["day"].string, 16)
                guard !label.isEmpty else { return nil }
                return Day(id: index, label: label, condition: clean(value["condition"].string, 40), high: number(value["high"]), low: number(value["low"]))
            }
            let weather = Weather(place: clean(json["place"].string, 60), condition: clean(now["condition"].string, 40),
                                  temperature: number(now["temp"]) ?? number(now["temperature"]), feelsLike: number(now["feels"]) ?? number(now["feels_like"]),
                                  days: Array(days.prefix(7)))
            return weather.temperature == nil && weather.days.isEmpty ? nil : .weather(weather)
        case "event":
            let event = Event(title: clean(json["title"].string, 90), start: clean(json["start"].string, 40), end: clean(json["end"].string, 40),
                              location: clean(json["location"].string, 120), calendar: clean(json["calendar"].string, 40), url: webURL(json["url"].string))
            return event.title.isEmpty ? nil : .event(event)
        case "links":
            let items = list(json["items"]).enumerated().compactMap { index, value -> Link? in
                guard let url = webURL(value.string.isEmpty ? value["url"].string : value.string) else { return nil }
                return Link(id: index, url: url, title: clean(value["title"].string, 90))
            }
            return items.isEmpty ? nil : .links(title: title, items: items)
        default:
            return nil
        }
    }

    // MARK: helpers

    private static func kind(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "carousel", "carrousel", "products", "produits", "listings", "annonces", "cards", "cartes": "carousel"
        case "places", "place", "lieux", "lieu", "map", "carte", "plan": "places"
        case "choices", "choix", "options", "replies", "reponses", "réponses": "choices"
        case "metrics", "chiffres", "stats", "kpi": "metrics"
        case "weather", "meteo", "météo": "weather"
        case "event", "evenement", "événement", "rendez-vous": "event"
        case "links", "liens", "sources": "links"
        default: ""
        }
    }

    private static func list(_ value: JSONValue) -> [JSONValue] { Array(value.array.prefix(maxItems)) }

    static func clean(_ value: String, _ limit: Int) -> String {
        let collapsed = value.split(whereSeparator: { $0.isNewline }).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return collapsed.count > limit ? String(collapsed.prefix(limit - 1)) + "…" : collapsed
    }

    private static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .number(let n): return n.isFinite ? n : nil
        case .string(let s):
            let digits = s.replacingOccurrences(of: ",", with: ".").filter { "0123456789.-".contains($0) }
            return Double(digits)
        default: return nil
        }
    }

    private static func display(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n ? String(Int(n)) : String(n)
        default: return ""
        }
    }

    private static func inferTrend(_ delta: JSONValue) -> Trend {
        let shown = display(delta).trimmingCharacters(in: .whitespaces)
        if shown.hasPrefix("+") || shown.hasPrefix("↑") { return .up }
        if shown.hasPrefix("-") || shown.hasPrefix("−") || shown.hasPrefix("↓") { return .down }
        return .flat
    }

    /// A web address the app may open or load: http or https with a host, nothing else.
    static func webURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 2_000, let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Web links written in a reply outside code and cards, for link previews: at most `limit`, in order, without duplicates.
    static func links(in markdown: String, limit: Int = 3) -> [URL] {
        var urls: [URL] = [], seen = Set<String>()
        for block in ChatMarkdown.parse(markdown) {
            let text: String
            switch block {
            case .paragraph(let t), .quote(let t), .heading(_, let t): text = t
            case .item(_, _, let t, _): text = t
            default: continue
            }
            for match in text.matches(of: /https?:\/\/[^\s<>()\[\]"'`]+/) {
                var candidate = String(match.output)
                while let last = candidate.last, ".,;:!?".contains(last) { candidate.removeLast() }
                guard let url = webURL(candidate), seen.insert(url.absoluteString).inserted else { continue }
                urls.append(url)
                if urls.count == limit { return urls }
            }
        }
        return urls
    }

    /// The reply without its ```ui cards (for copying or sharing as text); ordinary code fences stay.
    static func stripCards(_ text: String) -> String {
        var out: [Substring] = [], skipping = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if skipping { if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { skipping = false }; continue }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~"), isCardFence(String(trimmed.drop { $0 == "`" || $0 == "~" })) { skipping = true; continue }
            out.append(line)
        }
        return out.joined(separator: "\n").replacingOccurrences(of: "\n\n\n", with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a reply holds at least one card fence (cheap check, no parsing).
    static func hasCards(_ text: String) -> Bool {
        text.contains("```ui") || text.contains("```hermes-ui") || text.contains("```card") || text.contains("```carte")
    }

    /// An SF Symbol for a weather condition written in French or English.
    static func weatherSymbol(_ condition: String) -> String {
        let c = condition.lowercased()
        if c.contains("orage") || c.contains("thunder") { return "cloud.bolt.rain.fill" }
        if c.contains("neige") || c.contains("snow") || c.contains("verglas") { return "cloud.snow.fill" }
        if c.contains("pluie") || c.contains("averse") || c.contains("rain") || c.contains("bruine") || c.contains("drizzle") { return "cloud.rain.fill" }
        if c.contains("brouillard") || c.contains("brume") || c.contains("fog") || c.contains("mist") { return "cloud.fog.fill" }
        if c.contains("vent") || c.contains("wind") { return "wind" }
        if c.contains("partiel") || c.contains("partly") || c.contains("éclaircie") || c.contains("eclaircie") || c.contains("passages nuageux") { return "cloud.sun.fill" }
        if c.contains("nuag") || c.contains("couvert") || c.contains("cloud") || c.contains("overcast") || c.contains("gris") { return "cloud.fill" }
        if c.contains("soleil") || c.contains("ensoleill") || c.contains("dégagé") || c.contains("degage") || c.contains("clear") || c.contains("sun") { return "sun.max.fill" }
        return "thermometer.medium"
    }
}
