import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Lock Screen card and Dynamic Island for a voice call or a reply in progress, with buttons that act on it
/// (mute, end the call, stop the reply) through `LiveActivityIntent`s handled by the app.
struct HermesLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HermesActivityAttributes.self) { context in
            LockScreenActivity(context: context)
                .activityBackgroundTint(ActivityStyle.card)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: context.attributes.kind == "call" ? "hermesios://voice" : "hermesios://open"))
        } dynamicIsland: { context in
            DynamicIsland {
                // A card on show takes the whole island: nothing of the call around it.
                DynamicIslandExpandedRegion(.leading) {
                    if ActivityStyle.shown(context) == nil { ActivityOrb(state: context.state, profile: context.attributes.profile, size: 44).padding(.leading, 4) }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if ActivityStyle.shown(context) == nil { ActivityClock(state: context.state).padding(.trailing, 6) }
                }
                DynamicIslandExpandedRegion(.center) {
                    if ActivityStyle.shown(context) == nil {
                        VStack(spacing: 1) {
                            Text(context.state.title).font(.headline).lineLimit(1)
                            Text(context.isStale && context.attributes.kind == "call" ? "Appel interrompu" : context.state.detail).font(.subheadline).foregroundStyle(ActivityStyle.detailColor(context.state)).lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let glance = ActivityStyle.shown(context) {
                        GlanceView(glance: glance)
                    } else {
                        ActivityButtons(kind: context.attributes.kind, state: context.state, stale: context.isStale).padding(.top, 6)
                    }
                }
            } compactLeading: {
                ActivityOrb(state: context.state, profile: context.attributes.profile, size: 22)
            } compactTrailing: {
                if context.state.isFinished { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(ActivityStyle.accent) }
                else if context.state.muted { Image(systemName: "mic.slash.fill").font(.caption).foregroundStyle(ActivityStyle.accent) }
                else if let glance = context.state.glance, !context.isStale {
                    if !glance.value.isEmpty, glance.value.count <= 5 { Text(glance.value).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(ActivityStyle.accent) }
                    else { Image(systemName: glance.symbol).font(.caption).foregroundStyle(ActivityStyle.accent) }
                }
                else { ActivityClock(state: context.state).frame(maxWidth: 46) }
            } minimal: {
                ActivityOrb(state: context.state, profile: context.attributes.profile, size: 20)
            }
            .keylineTint(ActivityStyle.accent)
        }
    }
}

private enum ActivityStyle {
    static let accent = Color(red: 0.95, green: 0.42, blue: 0.30)
    static let card = Color(red: 0.10, green: 0.09, blue: 0.09)

    static func orbPhase(_ state: HermesActivityAttributes.ContentState) -> OrbPhase {
        if state.isFinished || state.muted { return .idle }
        switch state.phase {
        case "listening": return .listening
        case "speaking": return .speaking
        case "thinking", "working": return .thinking
        default: return .idle
        }
    }

    /// The call's newest card: shown alone, the call's orb, state and buttons giving it their room (the 160 points iOS
    /// allows). The compact island still shows the call; hanging up stays possible by voice or from the app.
    static func shown(_ context: ActivityViewContext<HermesActivityAttributes>) -> CardGlance? {
        guard context.attributes.kind == "call", !context.isStale, let glance = context.state.glance else { return nil }
        return glance
    }

    static func detailColor(_ state: HermesActivityAttributes.ContentState) -> Color {
        state.isFinished || state.phase == "paused" || state.muted ? .white.opacity(0.65) : accent
    }
}

/// The app's orb, still: Live Activities redraw only when their state changes. Drawn as a small mark (filling its frame)
/// in its dark colours, since the activity's background is always dark.
private struct ActivityOrb: View {
    let state: HermesActivityAttributes.ContentState
    /// The agent's own illustration (its standard look: the widgets do not see choices made in the app).
    let profile: String
    let size: CGFloat
    var body: some View {
        ZStack {
            OrbView(phase: ActivityStyle.orbPhase(state), animated: false, look: .standard(for: profile), compact: true)
                .environment(\.colorScheme, .dark).frame(width: size, height: size)
            if state.muted {
                Image(systemName: "mic.slash.fill").font(.system(size: size * 0.34, weight: .bold)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 2)
            } else if state.isFinished {
                Image(systemName: "checkmark").font(.system(size: size * 0.38, weight: .bold)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 2)
            }
        }.accessibilityLabel(state.detail)
    }
}

private struct ActivityClock: View {
    let state: HermesActivityAttributes.ContentState
    var body: some View {
        if state.isFinished {
            Text("Prêt").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
        } else {
            Text(state.start, style: .timer).font(.callout.monospacedDigit().weight(.medium)).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.trailing)
        }
    }
}

/// Mute and end for a call, stop for a running reply, nothing once finished.
private struct ActivityButtons: View {
    let kind: String
    let state: HermesActivityAttributes.ContentState
    var stale = false
    /// Shorter buttons when a card shares the space (the activity is at most 160 points tall).
    var compact = false

    var body: some View {
        if stale && kind == "call" {
            EmptyView()
        } else if kind == "call" {
            HStack(spacing: 10) {
                Button(intent: ToggleMuteIntent()) {
                    Label(state.muted ? "Activer le micro" : "Couper le micro", systemImage: state.muted ? "mic.fill" : "mic.slash.fill")
                        .labelStyle(PillLabel(compact: compact)).background(.white.opacity(0.14), in: Capsule())
                }.buttonStyle(.plain)
                Button(intent: EndCallIntent()) {
                    Label("Raccrocher", systemImage: "phone.down.fill").labelStyle(PillLabel(compact: compact)).background(Color(red: 0.86, green: 0.24, blue: 0.20), in: Capsule())
                }.buttonStyle(.plain)
            }
        } else if !state.isFinished {
            Button(intent: StopReplyIntent()) {
                Label("Arrêter la réponse", systemImage: "stop.fill").labelStyle(PillLabel(compact: compact)).background(.white.opacity(0.14), in: Capsule())
            }.buttonStyle(.plain)
        }
    }
}

private struct PillLabel: LabelStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.font(.system(size: 14, weight: .semibold))
            configuration.title.font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
        }.foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: compact ? 34 : 42)
    }
}

private struct LockScreenActivity: View {
    let context: ActivityViewContext<HermesActivityAttributes>
    private var glance: CardGlance? { context.isStale ? nil : context.state.glance }

    var body: some View {
        if let glance = ActivityStyle.shown(context) {
            GlanceView(glance: glance).padding(10)
        } else {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    ActivityOrb(state: context.state, profile: context.attributes.profile, size: 50)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                        Text(context.isStale && context.attributes.kind == "call" ? "Appel interrompu" : context.state.detail).font(.subheadline).foregroundStyle(ActivityStyle.detailColor(context.state)).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    ActivityClock(state: context.state)
                }
                ActivityButtons(kind: context.attributes.kind, state: context.state, stale: context.isStale)
            }.padding(.horizontal, 16).padding(.vertical, 14)
        }
    }
}

/// The card the way the chat draws it: the weather on its sky, the others on white.
private struct CardTheme {
    let background: LinearGradient
    let primary: Color, secondary: Color, icon: Color, iconBackground: Color, bar: Color

    init(_ glance: CardGlance) {
        if let sky = Self.sky(glance.symbol) {
            background = LinearGradient(colors: sky, startPoint: .top, endPoint: .bottom)
            primary = .white; secondary = .white.opacity(0.78); icon = .white; iconBackground = .white.opacity(0.22); bar = .white
        } else {
            background = LinearGradient(colors: [.white, Color(white: 0.96)], startPoint: .top, endPoint: .bottom)
            primary = Color(white: 0.08); secondary = Color(white: 0.08).opacity(0.58)
            icon = ActivityStyle.accent; iconBackground = ActivityStyle.accent.opacity(0.14); bar = ActivityStyle.accent
        }
    }

    /// The chat's weather card colours (its light look, which stands out on the black of the island).
    private static func sky(_ symbol: String) -> [Color]? {
        let weather = ["sun.max.fill", "cloud.sun.fill", "cloud.fill", "cloud.rain.fill", "cloud.bolt.rain.fill", "snowflake", "cloud.fog.fill"]
        guard weather.contains(symbol) else { return nil }
        if symbol.contains("rain") || symbol.contains("bolt") { return [Color(red: 0.42, green: 0.52, blue: 0.66), Color(red: 0.27, green: 0.35, blue: 0.48)] }
        if symbol == "snowflake" || symbol.contains("fog") || symbol == "cloud.fill" { return [Color(red: 0.55, green: 0.62, blue: 0.72), Color(red: 0.4, green: 0.47, blue: 0.58)] }
        return [Color(red: 0.33, green: 0.6, blue: 0.92), Color(red: 0.2, green: 0.42, blue: 0.78)]
    }
}

/// A card with rows of its own is drawn in full, the others as a header with two lines.
private struct GlanceView: View {
    let glance: CardGlance
    var body: some View {
        if glance.rows.isEmpty { GlanceCard(glance: glance) } else { GlanceDetail(glance: glance) }
    }
}

/// The newest card of the call, made small: its symbol, title and figure, then one or two short lines.
private struct GlanceCard: View {
    let glance: CardGlance
    var body: some View {
        let theme = CardTheme(glance)
        HStack(spacing: 10) {
            Image(systemName: glance.symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.icon)
                .frame(width: 38, height: 38).background(theme.iconBackground, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(glance.title).font(.headline).foregroundStyle(theme.primary).lineLimit(1)
                if let line = glance.lines.first { Text(line).font(.subheadline).foregroundStyle(theme.secondary).lineLimit(1) }
                if glance.lines.count > 1 { Text(glance.lines[1]).font(.footnote).foregroundStyle(theme.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if !glance.value.isEmpty {
                Text(glance.value).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(theme.primary).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(theme.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The card as the chat would show it, in what a Live Activity allows: its header, then up to three rows (the days of a
/// forecast, appointments, emails, figures with their trend, objectives with their bar).
private struct GlanceDetail: View {
    let glance: CardGlance
    var body: some View {
        let theme = CardTheme(glance)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: glance.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.icon)
                    .frame(width: 28, height: 28).background(theme.iconBackground, in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(glance.title).font(.headline).foregroundStyle(theme.primary).lineLimit(1)
                    if let line = glance.lines.first { Text(line).font(.caption).foregroundStyle(theme.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                if !glance.value.isEmpty {
                    Text(glance.value).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(theme.primary).lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            ForEach(Array(glance.rows.enumerated()), id: \.offset) { _, row in GlanceRow(row: row, theme: theme) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(theme.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct GlanceRow: View {
    let row: CardGlance.Row
    let theme: CardTheme
    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 7) {
                if !row.symbol.isEmpty {
                    Image(systemName: row.symbol).font(.system(size: row.symbol == "circle.fill" ? 6 : 11, weight: .semibold))
                        .foregroundStyle(row.symbol == "circle.fill" ? theme.bar : theme.primary.opacity(0.8)).frame(width: 16)
                }
                Text(row.label).font(.footnote.weight(.semibold)).foregroundStyle(theme.primary).lineLimit(1).layoutPriority(1)
                if !row.detail.isEmpty { Text(row.detail).font(.footnote).foregroundStyle(theme.secondary).lineLimit(1) }
                Spacer(minLength: 4)
                if !row.value.isEmpty { Text(row.value).font(.footnote.weight(.medium).monospacedDigit()).foregroundStyle(theme.primary.opacity(0.9)).lineLimit(1) }
            }
            if let progress = row.progress {
                ProgressView(value: progress).tint(theme.bar).scaleEffect(x: 1, y: 0.7, anchor: .center)
            }
        }
    }
}
