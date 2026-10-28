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
    /// A label and a figure, as written by the agent (« Distance », « 8,2 km »).
    struct Stat: Equatable, Identifiable {
        let id: Int
        let label: String, value: String
    }
    struct Point: Equatable, Identifiable {
        let id: Int
        let label: String
        let value: Double
    }
    struct Chart: Equatable {
        let title: String, unit: String, value: String, delta: String
        let trend: Trend
        let bars: Bool
        let points: [Point]
        let goal: Double?
    }
    struct Goal: Equatable, Identifiable {
        let id: Int
        let label: String, unit: String
        let value: Double, goal: Double
        var progress: Double { goal > 0 ? value / goal : 0 }
    }
    enum Tone: String, Equatable { case positive, negative, warning, neutral }
    struct Row: Equatable, Identifiable {
        let id: Int
        let title: String, subtitle: String, value: String, badge: String, icon: String
        let tone: Tone
        let url: URL?
        /// Sent as Maxime's message when the row is touched.
        let reply: String
    }
    struct Slot: Equatable, Identifiable {
        let id: Int
        let title: String, start: String, end: String, location: String, calendar: String
    }
    struct Exercise: Equatable, Identifiable {
        let id: Int
        let name: String, sets: String, weight: String, note: String
        let done: Bool?
    }
    struct Workout: Equatable {
        let title: String, subtitle: String
        let stats: [Stat]
        let exercises: [Exercise]
    }
    struct Coordinate: Equatable {
        let latitude: Double, longitude: Double
    }
    struct Route: Equatable {
        let title: String
        let stats: [Stat]
        let points: [Coordinate]
    }
    enum Health: String, Equatable { case ok, warning, down, unknown }
    /// A share of a whole: CPU, memory, disk.
    struct Gauge: Equatable, Identifiable {
        let id: Int
        let label: String, unit: String
        let value: Double, maximum: Double
        var fraction: Double { maximum > 0 ? min(max(value / maximum, 0), 1) : 0 }
    }
    struct Check: Equatable, Identifiable {
        let id: Int
        let name: String, detail: String
        let state: Health
    }
    /// A server, a service or anything that is up or down.
    struct Status: Equatable {
        let title: String, subtitle: String
        let state: Health
        let gauges: [Gauge]
        let items: [Check]
    }
    /// A news article, as the `nouvelles` tool returns it (French keys accepted).
    struct Article: Equatable, Identifiable {
        let id: Int
        let title: String, source: String, time: String, summary: String
        let url: URL?, image: URL?
    }
    enum BriefKind: String, Equatable { case agenda, training, nutrition, email, news, health, money, tasks, weather, note }
    struct BriefLine: Equatable, Identifiable {
        let id: Int
        let time: String, text: String, detail: String
        let url: URL?
        let reply: String
    }
    struct BriefSection: Equatable, Identifiable {
        let id: Int
        let kind: BriefKind
        let title: String, text: String
        let lines: [BriefLine]
        let articles: [Article]
    }
    struct BriefWeather: Equatable {
        let temperature: Double?, high: Double?, low: Double?
        let condition: String
    }
    /// The morning summary: a greeting, the weather, the sections the agent chose that day, one thing to keep in mind.
    struct Brief: Equatable {
        let greeting: String, date: String, focus: String
        let weather: BriefWeather?
        let sections: [BriefSection]
    }

    case carousel(title: String, items: [Item])
    case places(title: String, items: [Place])
    case choices(prompt: String, options: [String])
    case metrics(title: String, items: [Metric])
    case weather(Weather)
    case event(Event)
    case links(title: String, items: [Link])
    case chart(Chart)
    case progress(title: String, items: [Goal])
    case list(title: String, items: [Row], total: Stat?)
    case agenda(title: String, items: [Slot])
    case workout(Workout)
    case route(Route)
    case status(Status)
    case news(title: String, items: [Article])
    case brief(Brief)

    static let maxItems = 12
    /// Lists and agendas are read through, so they hold more (a week of shifts, a month of expenses).
    static let maxRows = 30
    static let maxPoints = 31
    static let maxRoutePoints = 400

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
        case "chart":
            // Oldest to newest: a long series keeps its most recent points.
            let points = Array(json["points"].array.prefix(400).enumerated().compactMap { index, value -> Point? in
                guard let y = number(value["value"]) ?? number(value["y"]) ?? number(value) else { return nil }
                let label = clean(display(value["label"]).isEmpty ? display(value["x"]) : display(value["label"]), 16)
                return Point(id: index, label: label.isEmpty ? String(index + 1) : label, value: y)
            }.suffix(maxPoints))
            guard points.count >= 2 else { return nil }
            let style = json["style"].string.lowercased()
            return .chart(Chart(title: title, unit: clean(json["unit"].string, 12), value: clean(display(json["value"]), 30),
                                delta: clean(display(json["delta"]), 24),
                                trend: Trend(rawValue: json["trend"].string.lowercased()) ?? inferTrend(json["delta"]),
                                bars: ["bar", "bars", "barres", "histogramme", "colonnes"].contains(style),
                                points: points, goal: number(json["goal"]) ?? number(json["objectif"])))
        case "progress":
            let items = list(json["items"]).enumerated().compactMap { index, value -> Goal? in
                let label = clean(value["label"].string, 30)
                guard !label.isEmpty, let current = number(value["value"]), let goal = number(value["goal"]) ?? number(value["target"]), goal > 0 else { return nil }
                return Goal(id: index, label: label, unit: clean(value["unit"].string, 10), value: max(0, current), goal: goal)
            }
            return items.isEmpty ? nil : .progress(title: title, items: Array(items.prefix(6)))
        case "list":
            let items = list(json["items"], limit: maxRows).enumerated().compactMap { index, value -> Row? in
                let name = clean(value["title"].string.isEmpty ? value["name"].string : value["title"].string, 80)
                guard !name.isEmpty else { return nil }
                return Row(id: index, title: name, subtitle: clean(value["subtitle"].string, 120), value: clean(display(value["value"]), 24),
                           badge: clean(value["badge"].string, 20), icon: symbolName(value["icon"].string),
                           tone: Tone(rawValue: value["tone"].string.lowercased()) ?? .neutral,
                           url: webURL(value["url"].string), reply: clean(value["reply"].string, 120))
            }
            let total = json["total"]
            let summary = clean(display(total["value"]), 24).isEmpty ? nil
                : Stat(id: 0, label: clean(total["label"].string.isEmpty ? "Total" : total["label"].string, 30), value: clean(display(total["value"]), 24))
            return items.isEmpty ? nil : .list(title: title, items: items, total: summary)
        case "agenda":
            let items = list(json["items"], limit: maxRows).enumerated().compactMap { index, value -> Slot? in
                let name = clean(value["title"].string, 80), start = clean(value["start"].string, 40)
                guard !name.isEmpty, !start.isEmpty else { return nil }
                return Slot(id: index, title: name, start: start, end: clean(value["end"].string, 40),
                            location: clean(value["location"].string, 100), calendar: clean(value["calendar"].string, 40))
            }
            return items.isEmpty ? nil : .agenda(title: title, items: items)
        case "workout":
            let exercises = list(json["exercises"].isNull ? json["items"] : json["exercises"]).enumerated().compactMap { index, value -> Exercise? in
                let name = clean(value["name"].string.isEmpty ? value["title"].string : value["name"].string, 60)
                guard !name.isEmpty else { return nil }
                let done: Bool? = if case .bool(let flag) = value["done"] { flag } else { nil }
                return Exercise(id: index, name: name, sets: clean(display(value["sets"]), 24), weight: clean(display(value["weight"]), 20),
                                note: clean(value["note"].string, 30), done: done)
            }
            let workout = Workout(title: title, subtitle: clean(json["subtitle"].string, 80), stats: stats(json["stats"]), exercises: exercises)
            return exercises.isEmpty && workout.stats.isEmpty ? nil : .workout(workout)
        case "route":
            var points = json["points"].array.compactMap { value -> Coordinate? in
                let lat = number(value.array.first ?? value["lat"]), lon = value.array.count > 1 ? number(value.array[1]) : number(value["lon"]) ?? number(value["lng"])
                guard let lat, let lon, (-90...90).contains(lat), (-180...180).contains(lon), lat != 0 || lon != 0 else { return nil }
                return Coordinate(latitude: lat, longitude: lon)
            }
            if points.count > maxRoutePoints {                       // keep the shape: evenly spaced samples, first and last kept
                let step = Double(points.count - 1) / Double(maxRoutePoints - 1)
                points = (0..<maxRoutePoints).map { points[Int((Double($0) * step).rounded())] }
            }
            return points.count < 2 ? nil : .route(Route(title: title, stats: stats(json["stats"]), points: points))
        case "news":
            let items = articles(json["items"].isNull ? json["articles"] : json["items"], limit: 8)
            return items.isEmpty ? nil : .news(title: title, items: items)
        case "brief":
            let sections = list(json["sections"], limit: 7).enumerated().compactMap { index, value -> BriefSection? in
                let kind = briefKind(value["kind"].string)
                let heading = clean(value["title"].string, 40), text = clean(value["text"].string, 280)
                let news = kind == .news ? articles(value["items"], limit: 4) : []
                let lines = kind == .news ? [] : list(value["items"], limit: 6).enumerated().compactMap { index, line -> BriefLine? in
                    let words = clean(line.string.isEmpty ? line["text"].string : line.string, 160)
                    guard !words.isEmpty else { return nil }
                    return BriefLine(id: index, time: clean(display(line["time"]), 12), text: words, detail: clean(display(line["detail"]), 60),
                                     url: webURL(line["url"].string), reply: clean(line["reply"].string, 120))
                }
                guard !text.isEmpty || !lines.isEmpty || !news.isEmpty else { return nil }
                return BriefSection(id: index, kind: kind, title: heading, text: text, lines: lines, articles: news)
            }
            let sky = json["weather"]
            let weather = sky.object.isEmpty ? nil
                : BriefWeather(temperature: number(sky["temp"]) ?? number(sky["temperature"]), high: number(sky["high"]), low: number(sky["low"]),
                               condition: clean(sky["condition"].string, 40))
            let brief = Brief(greeting: clean(json["greeting"].string.isEmpty ? json["title"].string : json["greeting"].string, 60),
                              date: clean(json["date"].string, 40), focus: clean(json["focus"].string, 200), weather: weather, sections: sections)
            return sections.isEmpty && brief.focus.isEmpty ? nil : .brief(brief)
        case "status":
            let gauges = list(json["gauges"]).enumerated().compactMap { index, value -> Gauge? in
                let label = clean(value["label"].string, 20), unit = clean(value["unit"].string, 8)
                guard !label.isEmpty, let current = number(value["value"]) else { return nil }
                let maximum = number(value["max"]) ?? (unit == "%" ? 100 : nil)
                guard let maximum, maximum > 0 else { return nil }
                return Gauge(id: index, label: label, unit: unit, value: max(0, current), maximum: maximum)
            }
            let items = list(json["items"]).enumerated().compactMap { index, value -> Check? in
                let name = clean(value["name"].string.isEmpty ? value["title"].string : value["name"].string, 50)
                return name.isEmpty ? nil : Check(id: index, name: name, detail: clean(display(value["detail"]), 60), state: health(value["state"].string))
            }
            guard !gauges.isEmpty || !items.isEmpty else { return nil }
            let given = json["state"].string
            let derived = items.isEmpty ? (gauges.contains { $0.fraction >= 0.9 } ? Health.warning : .ok) : worst(items.map(\.state))
            return .status(Status(title: title, subtitle: clean(json["subtitle"].string, 100),
                                  state: given.isEmpty ? derived : health(given),
                                  gauges: Array(gauges.prefix(4)), items: items))
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
        case "chart", "graph", "graphique", "courbe", "barres", "series", "série", "tendance": "chart"
        case "progress", "progression", "objectifs", "goals", "rings", "anneaux", "macros": "progress"
        case "list", "liste", "rows", "lignes", "transactions", "depenses", "dépenses", "courriels", "emails", "inbox": "list"
        case "agenda", "schedule", "horaire", "journee", "journée", "planning", "timeline": "agenda"
        case "workout", "entrainement", "entraînement", "seance", "séance", "training": "workout"
        case "route", "parcours", "trace", "tracé", "course", "run": "route"
        case "status", "etat", "état", "serveur", "server", "vps", "services", "monitoring": "status"
        case "news", "nouvelles", "actualites", "actualités", "articles", "presse": "news"
        case "brief", "matin", "morning", "resume", "résumé", "digest", "bulletin": "brief"
        default: ""
        }
    }

    private static func articles(_ value: JSONValue, limit: Int) -> [Article] {
        Array(list(value, limit: limit).enumerated().compactMap { index, item -> Article? in
            let title = clean(item["title"].string.isEmpty ? item["titre"].string : item["title"].string, 160)
            guard !title.isEmpty, let url = webURL(item["url"].string) else { return nil }
            let time = item["time"].string.isEmpty ? item["il_y_a"].string : item["time"].string
            let summary = item["summary"].string.isEmpty ? item["resume"].string : item["summary"].string
            return Article(id: index, title: title, source: clean(item["source"].string, 40), time: clean(time, 24),
                           summary: clean(summary, 240), url: url, image: webURL(item["image"].string))
        })
    }

    private static func briefKind(_ raw: String) -> BriefKind {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "agenda", "calendrier", "calendar", "journee", "journée", "aujourd'hui", "quart": .agenda
        case "training", "entrainement", "entraînement", "workout", "sport", "séance", "seance": .training
        case "nutrition", "nourriture", "repas", "food", "alimentation": .nutrition
        case "email", "emails", "courriels", "courriel", "mail": .email
        case "news", "nouvelles", "actualites", "actualités", "presse": .news
        case "health", "sante", "santé", "sommeil", "sleep", "poids": .health
        case "money", "finances", "finance", "argent", "budget": .money
        case "tasks", "taches", "tâches", "rappels", "todo": .tasks
        case "weather", "meteo", "météo": .weather
        default: .note
        }
    }

    /// « healthy », « running », « en panne »…: the words a tool or the agent may use for a state.
    static func health(_ raw: String) -> Health {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "ok", "up", "healthy", "running", "online", "en ligne", "green", "vert", "success", "succès": .ok
        case "warning", "warn", "degraded", "dégradé", "attention", "orange", "stale", "restarting", "starting": .warning
        case "down", "error", "failed", "critical", "unhealthy", "exited", "dead", "panne", "en panne", "red", "rouge", "erreur": .down
        default: .unknown
        }
    }

    /// The state of the whole: one service down is a failure; something unchecked next to healthy services needs a look.
    private static func worst(_ states: [Health]) -> Health {
        if states.contains(.down) { return .down }
        if states.contains(.warning) { return .warning }
        if states.contains(.unknown) { return states.contains(.ok) ? .warning : .unknown }
        return .ok
    }

    private static func list(_ value: JSONValue, limit: Int = maxItems) -> [JSONValue] { Array(value.array.prefix(limit)) }

    private static func stats(_ value: JSONValue) -> [Stat] {
        Array(list(value).enumerated().compactMap { index, item -> Stat? in
            let label = clean(item["label"].string, 24), shown = clean(display(item["value"]), 24)
            return label.isEmpty || shown.isEmpty ? nil : Stat(id: index, label: label, value: shown)
        }.prefix(4))
    }

    /// An SF Symbol name as the agent may write it (« server.rack »); anything else is dropped and the row shows its initial.
    private static func symbolName(_ raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return name.count <= 48 && !name.isEmpty && name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." }) ? name : ""
    }

    /// Minutes after midnight, on this phone's clock, for an ISO date and time (« …T10:45:00Z » is 06:45 in Montréal),
    /// « 07:00 », « 7 h 30 », « 17h » or « 5:30 PM »; nil for a bare date.
    static func minutes(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces), text = trimmed.lowercased()
        if trimmed.count > 10, let moment = date(trimmed) {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: moment)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        guard let match = text.firstMatch(of: /(?:^|\D)(\d{1,2})\s*[:h]\s*(\d{2})?(?!\d)(\s*[ap]\.?\s?m\b)?/), var hour = Int(match.1) else { return nil }
        let minute = match.2.flatMap { Int($0) } ?? 0
        if let suffix = match.3 {
            let afternoon = suffix.contains("p")
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (afternoon ? 12 : 0)
        }
        return hour < 24 && minute < 60 ? hour * 60 + minute : nil
    }

    /// Free time before each slot, in minutes, keyed by slot id. It runs from the latest end so far that day, so a shift
    /// that spans a meeting stays busy; a slot that ends past midnight keeps the rest of the day busy.
    static func freeTime(_ slots: [Slot]) -> [Int: Int] {
        var gaps: [Int: Int] = [:], latest: Int?, currentDay: String?
        for slot in slots {
            guard let start = minutes(slot.start) else { continue }
            let slotDay = day(slot.start)
            if slotDay != currentDay { latest = nil; currentDay = slotDay }
            if let latest, start > latest { gaps[slot.id] = start - latest }
            let end = minutes(slot.end).map { $0 >= start ? $0 : 24 * 60 } ?? start
            latest = max(latest ?? end, end)
        }
        return gaps
    }

    /// The local day of an ISO date or date and time, as « 2026-10-29 »; nil without a date.
    static func day(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text.count >= 10, let moment = date(text) else { return nil }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: moment)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// An ISO date, with or without a time, an offset or fractions of a second. Without an offset the time is local.
    static func date(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text.count >= 10, text.first?.isNumber == true else { return nil }
        if let full = try? Date(text, strategy: .iso8601) { return full }
        let precise = ISO8601DateFormatter(); precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let full = precise.date(from: text) { return full }
        let local = DateFormatter(); local.locale = Locale(identifier: "en_US_POSIX"); local.timeZone = .current
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = pattern
            if let moment = local.date(from: text) { return moment }
        }
        return nil
    }

    static func clean(_ value: String, _ limit: Int) -> String {
        let collapsed = value.split(whereSeparator: { $0.isNewline }).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return collapsed.count > limit ? String(collapsed.prefix(limit - 1)) + "…" : collapsed
    }

    private static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .number(let n): return n.isFinite ? n : nil
        case .string(let s):
            var text = s.replacingOccurrences(of: "\u{2212}", with: "-")
            // « 1,234.56 » and « 4,000 » use the comma for thousands; « 8,2 » uses it for decimals.
            if text.contains(".") || text.firstMatch(of: /\d,\d{3}(?!\d)/) != nil && text.firstMatch(of: /,\d{1,2}(?!\d)/) == nil {
                text = text.replacingOccurrences(of: ",", with: "")
            }
            let digits = text.replacingOccurrences(of: ",", with: ".").filter { "0123456789.-".contains($0) }
            return Double(digits).flatMap { $0.isFinite ? $0 : nil }
        default: return nil
        }
    }

    private static func display(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? String(Int(n)) : String(n)
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
