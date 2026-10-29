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
    /// One answer the reader can pick: what it shows, what it sends (often the same), an optional line and symbol.
    struct Option: Equatable, Identifiable {
        let id: Int
        let label: String, reply: String, detail: String, icon: String
    }
    /// A question with its answers; several may be picked when `multiple`.
    struct Question: Equatable, Identifiable {
        let id: Int
        let prompt: String
        let options: [Option]
        let multiple: Bool
    }
    /// Answers to pick: one or several questions, asked one at a time, sent together as one message.
    struct Choices: Equatable {
        let questions: [Question]
        /// Whether a free answer (« Autre réponse… ») is offered.
        let other: Bool
        /// A few short follow-ups with nothing to explain: shown as quick-reply pills under the reply.
        var isQuick: Bool {
            guard questions.count == 1, let only = questions.first else { return false }
            return !only.multiple && only.prompt.isEmpty && only.options.count <= 4
                && only.options.allSatisfy { $0.detail.isEmpty && $0.icon.isEmpty && $0.label.count <= 28 }
        }
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
    case choices(Choices)
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
                let valid = (lat.map { (-90...90).contains($0) } ?? false) && (lon.map { (-180...180).contains($0) } ?? false) && (lat != 0 || lon != 0)
                guard !name.isEmpty || !address.isEmpty || valid else { return nil }
                return Place(id: index, name: name, address: address, note: clean(value["note"].string, 120), phone: clean(value["phone"].string, 30),
                             latitude: valid ? lat : nil, longitude: valid ? lon : nil, url: webURL(value["url"].string))
            }
            return items.isEmpty ? nil : .places(title: title, items: items)
        case "choices":
            let asked = json["questions"].array.isEmpty ? [json] : Array(json["questions"].array.prefix(6))
            let questions = asked.enumerated().compactMap { index, value -> Question? in
                let options = list(firstNonNull(value, "options", "items", "choices")).enumerated().compactMap { number, option -> Option? in
                    let plain = display(option)                                    // a bare answer: "Oui", or a number such as 2
                    let label = clean(plain.isEmpty ? firstString(option, "label", "text", "title", "reply") : plain, 80)
                    guard !label.isEmpty else { return nil }
                    let reply = clean(plain.isEmpty ? firstString(option, "reply", "send") : "", 160)
                    return Option(id: number, label: label, reply: reply.isEmpty ? label : reply,
                                  detail: clean(firstString(option, "detail", "description", "subtitle"), 100), icon: symbolName(option["icon"].string))
                }
                guard !options.isEmpty else { return nil }
                let several: Bool = if case .bool(let flag) = firstNonNull(value, "multiple", "multi", "multi_select") { flag } else { false }
                return Question(id: index, prompt: clean(firstString(value, "prompt", "question", "title"), 160), options: Array(options.prefix(8)), multiple: several)
            }
            let other: Bool = if case .bool(let flag) = json["other"] { flag } else { true }
            return questions.isEmpty ? nil : .choices(Choices(questions: questions, other: other))
        case "metrics":
            let items = list(json["items"]).enumerated().compactMap { index, value -> Metric? in
                let label = clean(value["label"].string, 40), shown = clean(display(value["value"]), 30)
                guard !label.isEmpty, !shown.isEmpty else { return nil }
                let trend = Trend(rawValue: value["trend"].string.lowercased()) ?? inferTrend(value["delta"])
                return Metric(id: index, label: label, value: shown, delta: clean(display(value["delta"]), 24), trend: trend)
            }
            return items.isEmpty ? nil : .metrics(title: title, items: Array(items.prefix(8)))
        case "weather":
            let now = !json["now"].isNull ? json["now"] : !json["actuel"].isNull ? json["actuel"] : json
            let days = list(json["days"].isNull ? json["jours"] : json["days"]).enumerated().compactMap { index, value -> Day? in
                var label = clean(value["day"].string.isEmpty ? value["label"].string : value["day"].string, 16)
                if label.isEmpty, let when = date(value["date"].string) {      // the meteo tool gives a date: show its weekday
                    label = when.formatted(.dateTime.weekday(.abbreviated)).capitalized
                }
                guard !label.isEmpty else { return nil }
                return Day(id: index, label: label, condition: clean(firstString(value, "condition", "conditions"), 40),
                           high: degrees(value, "high", "max_c", "max"), low: degrees(value, "low", "min_c", "min"))
            }
            let weather = Weather(place: clean(json["place"].string.isEmpty ? json["lieu"].string : json["place"].string, 60),
                                  condition: clean(firstString(now, "condition", "conditions"), 40),
                                  temperature: degrees(now, "temp", "temperature", "temperature_c"), feelsLike: degrees(now, "feels", "feels_like", "ressenti_c"),
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
            let points = Array(json["points"].array.suffix(400).enumerated().compactMap { index, value -> Point? in
                // A point: {"label","value"}, {"x","y"}, a bare number, or a ["mai", 3200] pair.
                let pair = value.array.count == 2 ? value.array : []
                guard let y = number(value["value"]) ?? number(value["y"]) ?? number(value) ?? pair.last.flatMap(number) else { return nil }
                let named = display(value["label"]).isEmpty ? display(value["x"]) : display(value["label"])
                let label = clean(named.isEmpty ? pair.first.map(display) ?? "" : named, 16)
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
            let total = json["total"].string.isEmpty ? json["total"] : JSONValue.object(["value": json["total"]])
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
                let done: Bool? = switch value["done"] {
                case .bool(let flag): flag
                case .string(let word): ["true", "oui", "yes", "fait"].contains(word.lowercased()) ? true : ["false", "non", "no"].contains(word.lowercased()) ? false : nil
                default: nil
                }
                return Exercise(id: index, name: name, sets: clean(display(value["sets"]), 24), weight: clean(display(value["weight"]), 20),
                                note: clean(value["note"].string, 30), done: done)
            }
            let workout = Workout(title: title, subtitle: clean(json["subtitle"].string, 80), stats: stats(json["stats"]), exercises: exercises)
            return exercises.isEmpty && workout.stats.isEmpty ? nil : .workout(workout)
        case "route":
            var points = json["points"].array.compactMap { value -> Coordinate? in
                let lat = number(value.array.first ?? value["lat"]) ?? number(value["latitude"])
                let lon = value.array.count > 1 ? number(value.array[1]) : number(value["lon"]) ?? number(value["lng"]) ?? number(value["longitude"])
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
                    let words = clean(line.string.isEmpty ? firstString(line, "text", "title") : line.string, 160)
                    guard !words.isEmpty else { return nil }
                    return BriefLine(id: index, time: clean(display(line["time"]), 12), text: words, detail: clean(display(line["detail"]), 60),
                                     url: webURL(line["url"].string), reply: clean(line["reply"].string, 120))
                }
                guard !text.isEmpty || !lines.isEmpty || !news.isEmpty else { return nil }
                return BriefSection(id: index, kind: kind, title: heading, text: text, lines: lines, articles: news)
            }
            let sky = json["weather"]
            let weather = sky.object.isEmpty ? nil
                : BriefWeather(temperature: degrees(sky, "temp", "temperature", "temperature_c"), high: degrees(sky, "high", "max_c"), low: degrees(sky, "low", "min_c"),
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
        case "warning", "warn", "degraded", "dégradé", "attention", "orange", "restarting", "starting", "paused", "en pause": .warning
        case "down", "error", "failed", "critical", "unhealthy", "exited", "dead", "stopped", "offline", "arrêté", "arrete", "hors ligne",
             "panne", "en panne", "red", "rouge", "erreur": .down
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
        if trimmed.count > 10, trimmed.firstMatch(of: /^\d{4}-\d{2}-\d{2}/) != nil {
            // A full date and time is read on the phone's clock, never digit by digit: its offset matters.
            if text.hasSuffix("t24:00") || text.hasSuffix("t24:00:00") || text.hasSuffix(" 24:00") { return 24 * 60 }
            guard let moment = date(trimmed) else { return nil }
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
        if hour == 24 && minute == 0 { return 24 * 60 }
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
            let endsLater = day(slot.end).map { slotDay != nil && $0 != slotDay } ?? false     // a shift or trip over midnight
            let end = endsLater ? 24 * 60 : minutes(slot.end).map { $0 >= start ? $0 : 24 * 60 } ?? start
            latest = max(latest ?? end, end)
        }
        return gaps
    }

    /// Which of the phone's calendar events a card means: the same title (or one inside the other, « Barbier » for
    /// « Barbier du Village ») on the same day, the closest to the card's time first; failing that, the only event that
    /// starts at that very time. nil when nothing fits or the choice would be a guess.
    static func bestEventMatch(title: String, start: Date, among candidates: [(title: String, start: Date)]) -> Int? {
        let wanted = folded(title)
        func likeness(_ name: String) -> Double {
            let other = folded(name)
            guard !other.isEmpty, !wanted.isEmpty else { return 0 }
            return other == wanted ? 2 : other.contains(wanted) || wanted.contains(other) ? 1 : 0
        }
        let scored = candidates.enumerated().compactMap { index, candidate -> (index: Int, score: Double)? in
            let titleScore = likeness(candidate.title), gap = abs(candidate.start.timeIntervalSince(start))
            guard titleScore > 0, Calendar.current.isDate(candidate.start, inSameDayAs: start) else { return nil }
            return (index, titleScore * 1_000 - gap / 60)
        }
        if let best = scored.max(by: { $0.score < $1.score }) { return best.index }
        // A card with a date and no time starts at midnight, like the day's all-day events: no guessing then.
        guard Calendar.current.startOfDay(for: start) != start else { return nil }
        let sameTime = candidates.indices.filter { abs(candidates[$0].start.timeIntervalSince(start)) < 90 }
        return sameTime.count == 1 ? sameTime[0] : nil
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_CA")).filter { $0.isLetter || $0.isNumber }
    }

    /// The day a summary is about, as it is written (« Jeudi 29 octobre », « 1er novembre 2026 ») or in ISO: the
    /// closest such day to `now` when the year is left out. nil when the text names no day.
    static func spokenDay(_ raw: String, near now: Date = .now) -> Date? {
        let calendar = Calendar.current
        if let moment = date(raw) { return calendar.startOfDay(for: moment) }
        let text = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_CA")).lowercased()
        let months = ["janvier", "fevrier", "mars", "avril", "mai", "juin", "juillet", "aout", "septembre", "octobre", "novembre", "decembre"]
        guard let match = text.firstMatch(of: /(\d{1,2})(?:er)?\s+([a-z]+)(?:\s+(\d{4}))?/), let day = Int(match.1),
              let month = months.firstIndex(of: String(match.2)).map({ $0 + 1 }) else { return nil }
        let year = calendar.component(.year, from: now)
        let years = match.3.flatMap { Int($0) }.map { [$0] } ?? [year - 1, year, year + 1]
        return years.compactMap { calendar.date(from: DateComponents(year: $0, month: month, day: day)) }
            .filter { calendar.component(.month, from: $0) == month }                  // « 31 novembre » is no day
            .min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
    }

    /// The local day of an ISO date or date and time, as « 2026-10-29 »; nil without a date.
    static func day(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text.count >= 10, let moment = date(text) else { return nil }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: moment)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// An ISO date, with or without a time, an offset (written with or without a space) or fractions of a second. A time
    /// without an offset is Montréal's, as the agents are told to write it; a bare date is a day on this phone's calendar.
    static func date(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text.count >= 10, text.first?.isNumber == true else { return nil }
        if text.count == 10 { return dayFormatter.date(from: text) }
        if let full = try? Date(text, strategy: .iso8601) { return full }
        if let full = fractionalISO.date(from: text) { return full }
        for formatter in timeFormatters { if let moment = formatter.date(from: text) { return moment } }
        return nil
    }

    // Built once: parsing runs for every slot of an agenda on each render. Each formatter keeps its own fixed format,
    // which makes sharing them safe (DateFormatter parsing is thread-safe; only changing its format is not).
    nonisolated(unsafe) private static let dayFormatter = formatter("yyyy-MM-dd", zone: .autoupdatingCurrent)
    nonisolated(unsafe) private static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let timeFormatters: [DateFormatter] =
        ["yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss XXXXX", "yyyy-MM-dd HH:mm:ssXXXXX",
         "yyyy-MM-dd HH:mm:ss XXXXX", "yyyy-MM-dd HH:mmXXXXX"].map { formatter($0, zone: .gmt) }
        + ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"]
            .map { formatter($0, zone: TimeZone(identifier: "America/Toronto") ?? .autoupdatingCurrent) }

    private static func formatter(_ format: String, zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone; formatter.dateFormat = format
        return formatter
    }

    static func clean(_ value: String, _ limit: Int) -> String {
        let collapsed = value.split(whereSeparator: { $0.isNewline }).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return collapsed.count > limit ? String(collapsed.prefix(limit - 1)) + "…" : collapsed
    }

    private static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .number(let n): return n.isFinite ? n : nil
        case .string(let s):
            // The first number written, the way people write it: « 12 400 $ », « 8,2 km », « 1,234.56 », « 1.234,56 »,
            // « 4,000 », « −5,2 », « 4.5/5 ». « 140–160 g » is 140, never 140160.
            let text = s.replacingOccurrences(of: "\u{2212}", with: "-").replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: "\u{202F}", with: " ")
            guard let match = text.firstMatch(of: /-?\d{1,3}(?: \d{3})+(?:[.,]\d+)?|-?\d+(?:[.,]\d+)*/) else { return nil }
            var token = String(match.output).replacingOccurrences(of: " ", with: "")
            let commas = token.filter { $0 == "," }.count, dots = token.filter { $0 == "." }.count
            if commas > 0 && dots > 0 {                                  // the last separator marks the decimals
                let decimalIsComma = (token.lastIndex(of: ",") ?? token.startIndex) > (token.lastIndex(of: ".") ?? token.startIndex)
                token = token.filter { $0 != (decimalIsComma ? "." : ",") }.replacingOccurrences(of: ",", with: ".")
            } else if commas > 0 {
                token = token.firstMatch(of: /^-?\d{1,3}(?:,\d{3})+$/) != nil ? token.replacingOccurrences(of: ",", with: "")
                    : commas == 1 ? token.replacingOccurrences(of: ",", with: ".") : ""
            } else if dots > 1 {
                token = token.firstMatch(of: /^-?\d{1,3}(?:\.\d{3})+$/) != nil ? token.replacingOccurrences(of: ".", with: "") : ""
            }
            return Double(token).flatMap { $0.isFinite ? $0 : nil }
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

    /// A temperature in °C under the first of these keys present; anything no weather can reach is dropped.
    private static func degrees(_ value: JSONValue, _ keys: String...) -> Double? {
        for key in keys { if let reading = number(value[key]) { return (-90...60).contains(reading) ? reading : nil } }
        return nil
    }

    private static func firstNonNull(_ value: JSONValue, _ keys: String...) -> JSONValue {
        keys.lazy.map { value[$0] }.first { !$0.isNull } ?? .null
    }

    private static func firstString(_ value: JSONValue, _ keys: String...) -> String {
        keys.lazy.map { value[$0].string }.first { !$0.isEmpty } ?? ""
    }

    private static func inferTrend(_ delta: JSONValue) -> Trend {
        if case .number(let change) = delta { return change > 0 ? .up : change < 0 ? .down : .flat }
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

    /// Web links written in a reply's own text, for link previews: at most `limit`, in order, without duplicates. Previews
    /// are fetched without a tap, so links in quotes (a relayed email) or code are left out, and so are private hosts and
    /// links that act when opened (sign-in, confirmation, unsubscribe, tokens).
    static func links(in markdown: String, limit: Int = 3) -> [URL] {
        var urls: [URL] = [], seen = Set<String>()
        for block in ChatMarkdown.parse(markdown) {
            let text: String
            switch block {
            case .paragraph(let t), .heading(_, let t): text = t
            case .item(_, _, let t, _): text = t
            default: continue
            }
            let prose = text.replacing(/`[^`\n]*`/, with: " ")
            for match in prose.matches(of: /https?:\/\/[^\s<>\[\]"'`]+/) {
                var candidate = String(match.output)
                // Markup and punctuation around a link are not part of it; a closing parenthesis is, when it is balanced.
                while let last = candidate.last {
                    if ".,;:!?*_~\u{201D}\u{2019}\u{00BB}\u{2026}".contains(last) { candidate.removeLast(); continue }
                    if last == ")", candidate.filter({ $0 == ")" }).count > candidate.filter({ $0 == "(" }).count { candidate.removeLast(); continue }
                    break
                }
                guard let url = webURL(candidate), previewable(url) else { continue }
                var key = url.absoluteString.lowercased()
                if key.hasSuffix("/") { key.removeLast() }
                guard seen.insert(key).inserted else { continue }
                urls.append(url)
                if urls.count == limit { return urls }
            }
        }
        return urls
    }

    /// Whether a page may be fetched for a preview without a tap.
    static func previewable(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), url.port == nil || url.port == 443 || url.port == 80 else { return false }
        let local = host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".internal") || host.hasSuffix(".ts.net")
            || host.firstMatch(of: /^(?:127\.|10\.|192\.168\.|169\.254\.|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|172\.(?:1[6-9]|2\d|3[01])\.)/) != nil
            || host.contains(":")                                                                   // an IPv6 literal
        guard !local else { return false }
        // Whole words of the path or of a parameter name: « /login », « ?token= », but not « apple-keynote ».
        let acting = /(?i)(?:^|[\/_.\-=&?])(token|access_token|auth|apikey|api_key|key|sig|signature|session|code|otp|password|reset|verify|verification|confirm|confirmation|unsubscribe|desabonnement|magic|login|signin|logout|invite)(?:$|[\/_.\-=&?])/
        return url.path.firstMatch(of: acting) == nil && ("?" + (url.query ?? "")).firstMatch(of: acting) == nil
    }

    /// The reply as plain text, for copying or sharing: each card becomes a few readable lines instead of its JSON.
    static func plainText(_ text: String) -> String {
        var out: [String] = [], open: ChatMarkdown.Fence?, card: [String]? = nil
        for line in ChatMarkdown.normalized(text).components(separatedBy: "\n") {
            if let current = open {
                if current.closes(line) {
                    open = nil
                    if let json = card { out.append(contentsOf: summary(json.joined(separator: "\n"))); card = nil } else { out.append(line) }
                } else if card != nil { card?.append(line) } else { out.append(line) }
                continue
            }
            if let start = ChatMarkdown.fence(line) {
                open = start
                if isCardFence(start.language) { card = [] } else { out.append(line) }
                continue
            }
            out.append(line)
        }
        if let json = card { out.append(contentsOf: summary(json.joined(separator: "\n"))) }     // a card left open at the end
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A card in a few lines of text; nothing when it cannot be read.
    static func summary(_ json: String) -> [String] {
        guard let card = parse(json) else { return [] }
        func joined(_ parts: String...) -> String { parts.filter { !$0.isEmpty }.joined(separator: " · ") }
        var lines: [String]
        switch card {
        case .carousel(let title, let items): lines = [title] + items.map { joined($0.title, $0.subtitle, $0.price, $0.url?.absoluteString ?? "") }
        case .places(let title, let items): lines = [title] + items.map { joined($0.name, $0.address, $0.phone) }
        case .choices(let choices): lines = choices.questions.flatMap { [$0.prompt] + $0.options.map { "• " + $0.label } }
        case .metrics(let title, let items): lines = [title] + items.map { joined($0.label + " : " + $0.value, $0.delta) }
        case .weather(let w): lines = [joined(w.place, w.temperature.map { "\(Int($0.rounded()))°" } ?? "", w.condition)]
                + w.days.map { joined($0.label, $0.condition, $0.low.map { "\(Int($0.rounded()))°" } ?? "", $0.high.map { "\(Int($0.rounded()))°" } ?? "") }
        case .event(let e): lines = [joined(e.title, e.start, e.end, e.location, e.calendar)]
        case .links(let title, let items): lines = [title] + items.map { joined($0.title, $0.url.absoluteString) }
        case .chart(let c): lines = [joined(c.title, c.value, c.delta)] + c.points.map { "\($0.label) : \($0.value.formatted())" + (c.unit.isEmpty ? "" : " \(c.unit)") }
        case .progress(let title, let items): lines = [title] + items.map { "\($0.label) : \($0.value.formatted()) / \($0.goal.formatted()) \($0.unit)" }
        case .list(let title, let items, let total): lines = [title] + items.map { joined($0.title, $0.subtitle, $0.value) } + [total.map { "\($0.label) : \($0.value)" } ?? ""]
        case .agenda(let title, let items): lines = [title] + items.map { joined($0.start, $0.end, $0.title, $0.location) }
        case .workout(let w): lines = [joined(w.title, w.subtitle)] + w.stats.map { "\($0.label) : \($0.value)" } + w.exercises.map { joined($0.name, $0.sets, $0.weight) }
        case .route(let r): lines = [r.title] + r.stats.map { "\($0.label) : \($0.value)" }
        case .status(let st): lines = [joined(st.title, st.subtitle)] + st.gauges.map { "\($0.label) : \(Int(($0.fraction * 100).rounded())) %" } + st.items.map { joined($0.name, $0.detail) }
        case .news(let title, let items): lines = [title] + items.map { joined($0.title, $0.source, $0.url?.absoluteString ?? "") }
        case .brief(let b): lines = [joined(b.greeting, b.date)] + b.sections.flatMap { section in
                [section.title] + (section.text.isEmpty ? [] : [section.text]) + section.lines.map { joined($0.time, $0.text, $0.detail) }
                    + section.articles.map { joined($0.title, $0.source) } } + [b.focus]
        }
        return lines.filter { !$0.isEmpty }
    }

    /// The reply without its ```ui cards (code and everything else kept).
    static func stripCards(_ text: String) -> String {
        ChatMarkdown.withoutCards(text).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a reply holds at least one card fence, by the same rules as the renderer.
    static func hasCards(_ text: String) -> Bool {
        guard text.contains("```") || text.contains("~~~") else { return false }      // most replies: no fence at all
        return ChatMarkdown.withoutCards(text).hadCards
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
