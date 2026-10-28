import MapKit
import SwiftUI

/// Draws a ```ui card from an agent reply (see `ChatCard`). While the fence still streams, a quiet placeholder holds its
/// place; a card that cannot be read once complete is simply left out.
struct RichCardView: View, Equatable {
    let json: String
    let complete: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.json == rhs.json && lhs.complete == rhs.complete }

    var body: some View {
        if !complete {
            CardSkeleton()
        } else if let card = ChatCard.parse(json) {
            switch card {
            case .carousel(let title, let items): CarouselCard(title: title, items: items)
            case .places(let title, let items): PlacesCard(title: title, places: items)
            case .choices(let prompt, let options): ChoicesCard(prompt: prompt, options: options)
            case .metrics(let title, let items): MetricsCard(title: title, metrics: items)
            case .weather(let weather): WeatherCard(weather: weather)
            case .event(let event): EventCard(event: event)
            case .links(let title, let items): LinksCard(title: title, links: items)
            case .chart(let chart): ChartCard(chart: chart)
            case .progress(let title, let items): ProgressCard(title: title, goals: items)
            case .list(let title, let items, let total): ListCard(title: title, rows: items, total: total)
            case .agenda(let title, let items): AgendaCard(title: title, slots: items)
            case .workout(let workout): WorkoutCard(workout: workout)
            case .route(let route): RouteCard(route: route)
            case .status(let status): StatusCard(status: status)
            case .news(let title, let items): NewsCard(title: title, articles: items)
            case .brief(let brief): BriefCard(brief: brief)
            }
        }
    }
}

// MARK: - Shared pieces

enum CardStyle {
    static let radius: CGFloat = 20
}

extension View {
    func cardSurface() -> some View {
        background(AppTheme.surface, in: RoundedRectangle(cornerRadius: CardStyle.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CardStyle.radius, style: .continuous).strokeBorder(AppTheme.line))
            .softShadow(0.6)
    }
}

struct CardTitle: View {
    let text: String
    var symbol: String?
    var body: some View {
        if !text.isEmpty {
            Label { Text(text) } icon: { if let symbol { Image(systemName: symbol) } }
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        }
    }
}

/// Where a card leaves the app: Plans, Calendar and the phone go to the system; web pages open in the in-app browser.
@MainActor func openOutside(_ url: URL) { UIApplication.shared.open(url) }

struct CardSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false
    var body: some View {
        RoundedRectangle(cornerRadius: CardStyle.radius, style: .continuous)
            .fill(AppTheme.surface)
            .overlay {
                LinearGradient(colors: [.clear, AppTheme.accent.opacity(0.10), .clear], startPoint: .leading, endPoint: .trailing)
                    .offset(x: phase ? 260 : -260)
                    .clipShape(RoundedRectangle(cornerRadius: CardStyle.radius, style: .continuous))
            }
            .overlay(RoundedRectangle(cornerRadius: CardStyle.radius, style: .continuous).strokeBorder(AppTheme.line))
            .frame(height: 120)
            .onAppear { guard !reduceMotion else { return }; withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) { phase = true } }
            .accessibilityLabel("Carte en préparation")
    }
}

// MARK: - Carousel (products, listings, articles)

private struct CarouselCard: View {
    let title: String
    let items: [ChatCard.Item]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(text: title, symbol: "sparkles")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in CarouselItemCard(item: item, textHeight: items.contains { !$0.badges.isEmpty } ? 124 : 104) }
                }
                .scrollTargetLayout()
                .padding(.vertical, 6)
            }
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, 26, for: .scrollContent)
            .padding(.horizontal, -26)                              // the row bleeds to the screen edges, first card aligned with the text
        }
        .accessibilityIdentifier("card-carousel")
    }
}

private struct CarouselItemCard: View {
    let item: ChatCard.Item
    /// The same for every card of a row, so the row stays aligned.
    let textHeight: CGFloat
    @Environment(\.openURL) private var openURL
    var body: some View {
        Button { if let url = item.url { Haptics.select(); openURL(url) } } label: {
            VStack(alignment: .leading, spacing: 0) {
                CardImage(image: item.image, page: item.url).frame(width: 236, height: 150).clipped()
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    if !item.badges.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(item.badges, id: \.self) { badge in
                                Text(badge).font(.caption2.weight(.medium)).lineLimit(1)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(AppTheme.line, in: Capsule())
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline) {
                        if !item.price.isEmpty { Text(item.price).font(.headline).foregroundStyle(AppTheme.accent).lineLimit(1) }
                        Spacer(minLength: 4)
                        if let rating = item.rating {
                            Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(.orange).labelStyle(.titleAndIcon)
                        } else if item.url != nil {
                            Image(systemName: "arrow.up.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        }
                    }
                }.padding(12).frame(width: 236, height: textHeight, alignment: .topLeading)
            }
            .cardSurface()
            .clipShape(RoundedRectangle(cornerRadius: CardStyle.radius, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            if let url = item.url {
                Button { openURL(url) } label: { Label("Ouvrir", systemImage: "safari") }
                Button { UIPasteboard.general.url = url } label: { Label("Copier le lien", systemImage: "link") }
                ShareLink(item: url) { Label("Partager", systemImage: "square.and.arrow.up") }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The picture of a card: the given image, else the page's own preview picture, else a soft placeholder.
struct CardImage: View {
    let image: URL?
    let page: URL?
    @State private var preview: UIImage?
    var body: some View {
        ZStack {
            LinearGradient(colors: [AppTheme.accent.opacity(0.18), AppTheme.accent.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                AsyncImage(url: image, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                    if let picture = phase.image { picture.resizable().scaledToFill().transition(.opacity) }
                    else if phase.error != nil { placeholder }
                    else { ProgressView().tint(.secondary) }
                }
            } else if let preview {
                Image(uiImage: preview).resizable().scaledToFill().transition(.opacity)
            } else {
                placeholder
            }
        }
        .task(id: page) {
            guard image == nil, let page, preview == nil else { return }
            if let fetched = await LinkPreviewStore.shared.preview(for: page)?.image { withAnimation(.easeOut(duration: 0.25)) { preview = fetched } }
        }
    }
    private var placeholder: some View {
        Image(systemName: "photo").font(.title2).foregroundStyle(AppTheme.accent.opacity(0.5))
    }
}

// MARK: - Places on a map

private struct ResolvedPlace: Identifiable, Equatable {
    let id: Int
    let place: ChatCard.Place
    let coordinate: CLLocationCoordinate2D
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.coordinate.latitude == rhs.coordinate.latitude && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

private struct PlacesCard: View {
    let title: String
    let places: [ChatCard.Place]
    @State private var resolved: [ResolvedPlace] = []
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(text: title, symbol: "map")
            VStack(spacing: 0) {
                Button { Haptics.select(); expanded = true } label: {
                    PlacesMap(places: resolved, interactive: false).frame(height: 180)
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption.weight(.bold))
                                .padding(8).background(.thinMaterial, in: Circle()).padding(10)
                        }
                }.buttonStyle(.plain).accessibilityLabel("Agrandir la carte")
                ForEach(places) { place in
                    if place.id > 0 { Divider().padding(.leading, 52) }
                    PlaceRow(index: place.id + 1, place: place, coordinate: resolved.first { $0.id == place.id }?.coordinate)
                }
            }
            .cardSurface()
            .clipShape(RoundedRectangle(cornerRadius: CardStyle.radius, style: .continuous))
        }
        .task { resolved = await PlaceResolver.resolve(places) }
        .sheet(isPresented: $expanded) {
            NavigationStack {
                PlacesMap(places: resolved, interactive: true).ignoresSafeArea(edges: .bottom)
                    .navigationTitle(title.isEmpty ? "Carte" : title).navigationBarTitleDisplayMode(.inline)
                    .toolbar { AppToolbarItem(placement: .confirmationAction) { AppCloseButton { expanded = false } } }
            }.presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .accessibilityIdentifier("card-places")
    }
}

private struct PlacesMap: View {
    let places: [ResolvedPlace]
    let interactive: Bool
    var body: some View {
        Map(initialPosition: framing, interactionModes: interactive ? .all : []) {
            ForEach(places) { item in
                Marker(item.place.name.isEmpty ? item.place.address : item.place.name, monogram: Text("\(item.id + 1)"), coordinate: item.coordinate)
                    .tint(AppTheme.accent)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .id(places.map(\.id))                                     // reframe once places are found
        .overlay { if places.isEmpty { ProgressView().tint(.secondary) } }
    }

    /// Room around the pins: a balloon rises above its point, a label hangs below it, and Apple's logo sits in the bottom corner.
    private var framing: MapCameraPosition {
        let lats = places.map(\.coordinate.latitude), lons = places.map(\.coordinate.longitude)
        guard let south = lats.min(), let north = lats.max(), let west = lons.min(), let east = lons.max() else { return .automatic }
        let latSpan = max((north - south) * 2.4, 0.012), lonSpan = max((east - west) * 1.6, 0.012)
        let center = CLLocationCoordinate2D(latitude: (north + south) / 2 - latSpan * 0.03, longitude: (east + west) / 2)
        return .region(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan)))
    }
}

private struct PlaceRow: View {
    let index: Int
    let place: ChatCard.Place
    let coordinate: CLLocationCoordinate2D?
    @Environment(\.openURL) private var openURL
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index)").font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(AppTheme.accent, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                if !place.name.isEmpty { Text(place.name).font(.subheadline.weight(.semibold)) }
                if !place.address.isEmpty { Text(place.address).font(.caption).foregroundStyle(.secondary) }
                if !place.note.isEmpty { Text(place.note).font(.caption).foregroundStyle(.secondary) }
                HStack(spacing: 8) {
                    pill("Itinéraire", "arrow.triangle.turn.up.right.diamond.fill", prominent: true) { openOutside(directions) }
                    if let phone = phoneURL { pill("Appeler", "phone.fill") { openOutside(phone) } }
                    if let url = place.url { pill("Site", "safari") { openURL(url) } }
                }.padding(.top, 4)
            }
            Spacer(minLength: 0)
        }.padding(12)
    }

    private var directions: URL {
        var parts = URLComponents(string: "https://maps.apple.com/")!
        let target = coordinate.map { "\($0.latitude),\($0.longitude)" } ?? place.query
        parts.queryItems = [URLQueryItem(name: "daddr", value: target), URLQueryItem(name: "q", value: place.name.isEmpty ? place.address : place.name)]
        return parts.url!
    }

    private var phoneURL: URL? {
        let digits = place.phone.filter { $0.isNumber || $0 == "+" }
        return digits.count >= 7 ? URL(string: "tel:\(digits)") : nil
    }

    private func pill(_ title: String, _ symbol: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button { Haptics.select(); action() } label: {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(prominent ? Color.white : AppTheme.accent)
                .background(prominent ? AppTheme.accent : AppTheme.accent.opacity(0.12), in: Capsule())
        }.buttonStyle(PressableStyle())
    }
}

/// Places without coordinates are looked up on Apple's map service (no location permission needed).
private enum PlaceResolver {
    @MainActor static func resolve(_ places: [ChatCard.Place]) async -> [ResolvedPlace] {
        var found: [ResolvedPlace] = []
        for place in places {
            if let lat = place.latitude, let lon = place.longitude {
                found.append(ResolvedPlace(id: place.id, place: place, coordinate: .init(latitude: lat, longitude: lon))); continue
            }
            guard !place.query.isEmpty else { continue }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = place.query
            guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { continue }
            found.append(ResolvedPlace(id: place.id, place: place, coordinate: coordinate(of: item)))
        }
        return found
    }

    @MainActor private static func coordinate(of item: MKMapItem) -> CLLocationCoordinate2D {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return item.location.coordinate }
        #endif
        return item.placemark.coordinate
    }
}

// MARK: - Quick replies

private struct ChoicesCard: View {
    let prompt: String
    let options: [String]
    @Environment(\.chatReply) private var reply
    @State private var chosen: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !prompt.isEmpty { Text(prompt).font(.subheadline).foregroundStyle(.secondary) }
            FlowLayout(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    Button {
                        guard chosen == nil else { return }
                        Haptics.send(); chosen = option; reply?.send(option)
                    } label: {
                        HStack(spacing: 6) {
                            if chosen == option { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                            Text(option).font(.subheadline.weight(.medium)).multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .foregroundStyle(chosen == option ? Color.white : AppTheme.accent)
                        .background(chosen == option ? AppTheme.accent : AppTheme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(AppTheme.accent.opacity(chosen == option ? 0 : 0.45)))
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(chosen != nil && chosen != option)
                    .opacity(chosen != nil && chosen != option ? 0.45 : 1)
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: chosen)
        .accessibilityIdentifier("card-choices")
    }
}

/// Wraps its children onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.init(width: width, height: nil))
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.init(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: .init(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}

// MARK: - Figures

private struct MetricsCard: View {
    let title: String
    let metrics: [ChatCard.Metric]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(text: title, symbol: "chart.bar")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(metrics) { metric in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(metric.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(metric.value).font(.system(.title3, design: .rounded).weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
                        if !metric.delta.isEmpty {
                            Label(metric.delta, systemImage: metric.trend == .up ? "arrow.up.right" : metric.trend == .down ? "arrow.down.right" : "minus")
                                .font(.caption.weight(.semibold)).labelStyle(.titleAndIcon)
                                .foregroundStyle(metric.trend == .up ? Color.green : metric.trend == .down ? AppTheme.accent : .secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    .cardSurface()
                }
            }
        }
        .accessibilityIdentifier("card-metrics")
    }
}

// MARK: - Weather

private struct WeatherCard: View {
    let weather: ChatCard.Weather
    @Environment(\.colorScheme) private var scheme
    private var sky: [Color] {
        let symbol = ChatCard.weatherSymbol(weather.condition)
        if symbol.contains("rain") || symbol.contains("bolt") { return scheme == .dark ? [Color(red: 0.16, green: 0.2, blue: 0.3), Color(red: 0.09, green: 0.11, blue: 0.17)] : [Color(red: 0.42, green: 0.52, blue: 0.66), Color(red: 0.27, green: 0.35, blue: 0.48)] }
        if symbol.contains("snow") || symbol.contains("fog") || symbol == "cloud.fill" { return scheme == .dark ? [Color(red: 0.22, green: 0.25, blue: 0.3), Color(red: 0.12, green: 0.14, blue: 0.18)] : [Color(red: 0.55, green: 0.62, blue: 0.72), Color(red: 0.4, green: 0.47, blue: 0.58)] }
        return scheme == .dark ? [Color(red: 0.12, green: 0.26, blue: 0.48), Color(red: 0.06, green: 0.12, blue: 0.26)] : [Color(red: 0.33, green: 0.6, blue: 0.92), Color(red: 0.2, green: 0.42, blue: 0.78)]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    if !weather.place.isEmpty { Label(weather.place, systemImage: "location.fill").font(.subheadline.weight(.semibold)).labelStyle(.titleAndIcon) }
                    if let temperature = weather.temperature {
                        Text("\(Int(temperature.rounded()))°").font(.system(size: 54, weight: .thin, design: .rounded))
                    }
                    Text(weather.condition).font(.subheadline.weight(.medium))
                    if let feels = weather.feelsLike { Text("Ressenti \(Int(feels.rounded()))°").font(.caption).opacity(0.8) }
                }
                Spacer()
                Image(systemName: ChatCard.weatherSymbol(weather.condition)).symbolRenderingMode(.multicolor).font(.system(size: 46))
            }
            if !weather.days.isEmpty {
                let lows = weather.days.compactMap(\.low), highs = weather.days.compactMap(\.high)
                let minimum = lows.min() ?? 0, maximum = max(highs.max() ?? 1, minimum + 1)
                VStack(spacing: 8) {
                    ForEach(weather.days) { day in
                        HStack(spacing: 10) {
                            Text(Self.shortDay(day.label)).font(.subheadline.weight(.medium)).frame(width: 44, alignment: .leading)
                            Image(systemName: ChatCard.weatherSymbol(day.condition)).symbolRenderingMode(.multicolor).frame(width: 26)
                            Text(day.low.map { "\(Int($0.rounded()))°" } ?? "").font(.subheadline).opacity(0.75).frame(width: 34, alignment: .trailing)
                            GeometryReader { geometry in
                                let low = day.low ?? minimum, high = day.high ?? maximum
                                let start = (low - minimum) / (maximum - minimum), end = (high - minimum) / (maximum - minimum)
                                Capsule().fill(.white.opacity(0.2)).overlay(alignment: .leading) {
                                    Capsule().fill(LinearGradient(colors: [.cyan, .yellow, .orange], startPoint: .leading, endPoint: .trailing))
                                        .frame(width: max(6, geometry.size.width * (end - start))).offset(x: geometry.size.width * start)
                                }
                            }.frame(height: 5)
                            Text(day.high.map { "\(Int($0.rounded()))°" } ?? "").font(.subheadline.weight(.semibold)).frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(LinearGradient(colors: sky, startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: CardStyle.radius, style: .continuous))
        .softShadow(0.8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("card-weather")
    }
}

private extension WeatherCard {
    /// « Jeu 29 oct. » reads as « Jeu »: the column stays aligned, like Apple's own forecast.
    static func shortDay(_ label: String) -> String {
        guard label.count > 5, let first = label.split(separator: " ").first else { return label }
        return String(first).trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
    }
}

// MARK: - Event

struct EventCard: View {
    let event: ChatCard.Event
    @Environment(\.openURL) private var openURL
    private var startDate: Date? { Self.date(event.start) }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Text(startDate.map { $0.formatted(.dateTime.month(.abbreviated)) }?.uppercased() ?? "—")
                    .font(.caption2.weight(.bold)).foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 3)
                    .background(AppTheme.accent)
                Text(startDate.map { $0.formatted(.dateTime.day()) } ?? "?").font(.system(.title2, design: .rounded).weight(.bold))
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .frame(width: 54).background(AppTheme.background).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).font(.headline).lineLimit(2)
                Text(timeRange).font(.subheadline).foregroundStyle(.secondary)
                if !event.location.isEmpty { Label(event.location, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(.secondary) }
                if !event.calendar.isEmpty { Label(event.calendar, systemImage: "calendar").font(.caption).foregroundStyle(.secondary) }
                HStack(spacing: 8) {
                    Button { Haptics.select(); openOutside(calendarURL) } label: {
                        Label("Calendrier", systemImage: "calendar").font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6).foregroundStyle(.white).background(AppTheme.accent, in: Capsule())
                    }.buttonStyle(PressableStyle())
                    if !event.location.isEmpty {
                        Button { Haptics.select(); openOutside(mapsURL) } label: {
                            Label("Plans", systemImage: "map").font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6).foregroundStyle(AppTheme.accent).background(AppTheme.accent.opacity(0.12), in: Capsule())
                        }.buttonStyle(PressableStyle())
                    }
                }.padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14).cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("card-event")
    }

    private var timeRange: String {
        guard let start = startDate else { return event.start }
        let allDay = event.start.count <= 10
        if allDay { return start.formatted(.dateTime.weekday(.wide).day().month(.wide)) }
        let first = start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        guard let end = Self.date(event.end) else { return first }
        return "\(first) – \(end.formatted(.dateTime.hour().minute()))"
    }

    private var calendarURL: URL {
        URL(string: "calshow:\(Int((startDate ?? .now).timeIntervalSinceReferenceDate))")!
    }

    private var mapsURL: URL {
        var parts = URLComponents(string: "https://maps.apple.com/")!
        parts.queryItems = [URLQueryItem(name: "q", value: event.location)]
        return parts.url!
    }

    static func date(_ raw: String) -> Date? { ChatCard.date(raw) }
}

// MARK: - Links

private struct LinksCard: View {
    let title: String
    let links: [ChatCard.Link]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(text: title, symbol: "link")
            ForEach(links) { link in LinkPreviewRow(url: link.url, fallbackTitle: link.title) }
        }
        .accessibilityIdentifier("card-links")
    }
}
