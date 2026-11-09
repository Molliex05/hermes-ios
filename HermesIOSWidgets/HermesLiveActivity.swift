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
                DynamicIslandExpandedRegion(.leading) {
                    ActivityOrb(state: context.state, profile: context.attributes.profile, size: ActivityStyle.detailed(context) == nil ? 44 : 34).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if ActivityStyle.detailed(context) != nil { CallIconButtons(muted: context.state.muted).padding(.trailing, 4) }
                    else { ActivityClock(state: context.state).padding(.trailing, 6) }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(context.state.title).font(.headline).lineLimit(1)
                        Text(context.isStale && context.attributes.kind == "call" ? "Appel interrompu" : context.state.detail).font(.subheadline).foregroundStyle(ActivityStyle.detailColor(context.state)).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let detailed = ActivityStyle.detailed(context) {
                        GlanceDetail(glance: detailed).padding(.top, 2)
                    } else {
                        VStack(spacing: 6) {
                            if let glance = context.state.glance, !context.isStale { GlanceCard(glance: glance) }
                            ActivityButtons(kind: context.attributes.kind, state: context.state, stale: context.isStale, compact: context.state.glance != nil)
                        }.padding(.top, 4)
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

    /// A call's card with rows of its own (forecast, appointments, emails, figures): drawn in full, the call's buttons
    /// shrinking to two round icons beside the title so everything fits the 160 points iOS allows.
    static func detailed(_ context: ActivityViewContext<HermesActivityAttributes>) -> CardGlance? {
        guard context.attributes.kind == "call", !context.isStale, let glance = context.state.glance, !glance.rows.isEmpty else { return nil }
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
        if let detailed = ActivityStyle.detailed(context) { detailedBody(detailed) } else { standardBody }
    }

    /// A card in full: the call folds into one line (agent, state, mute and hang up) above it.
    private func detailedBody(_ detailed: CardGlance) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                ActivityOrb(state: context.state, profile: context.attributes.profile, size: 28)
                (Text(context.state.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                 + Text("  ·  \(context.state.detail)").font(.subheadline).foregroundStyle(ActivityStyle.detailColor(context.state)))
                    .lineLimit(1)
                Spacer(minLength: 6)
                CallIconButtons(muted: context.state.muted)
            }
            GlanceDetail(glance: detailed)
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var standardBody: some View {
        VStack(spacing: glance == nil ? 12 : 8) {
            HStack(spacing: 12) {
                ActivityOrb(state: context.state, profile: context.attributes.profile, size: glance == nil ? 50 : 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                    Text(context.isStale && context.attributes.kind == "call" ? "Appel interrompu" : context.state.detail).font(.subheadline).foregroundStyle(ActivityStyle.detailColor(context.state)).lineLimit(1)
                }
                Spacer(minLength: 8)
                ActivityClock(state: context.state)
            }
            if let glance { GlanceCard(glance: glance) }
            ActivityButtons(kind: context.attributes.kind, state: context.state, stale: context.isStale, compact: glance != nil)
        }.padding(.horizontal, 16).padding(.vertical, glance == nil ? 14 : 10)
    }
}

/// The newest card of the call, made small: its symbol, title and figure, then one or two short lines.
private struct GlanceCard: View {
    let glance: CardGlance
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: glance.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(ActivityStyle.accent)
                .frame(width: 30, height: 30).background(ActivityStyle.accent.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(glance.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                if let line = glance.lines.first { Text(line).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1) }
                if glance.lines.count > 1 { Text(glance.lines[1]).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if !glance.value.isEmpty {
                Text(glance.value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Mute and hang up as two round icons, when a full card takes the room of the large buttons.
private struct CallIconButtons: View {
    let muted: Bool
    var body: some View {
        HStack(spacing: 8) {
            Button(intent: ToggleMuteIntent()) {
                Image(systemName: muted ? "mic.fill" : "mic.slash.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(.white.opacity(0.16), in: Circle())
            }.buttonStyle(.plain).accessibilityLabel(muted ? "Activer le micro" : "Couper le micro")
            Button(intent: EndCallIntent()) {
                Image(systemName: "phone.down.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(Color(red: 0.86, green: 0.24, blue: 0.20), in: Circle())
            }.buttonStyle(.plain).accessibilityLabel("Raccrocher")
        }
    }
}

/// The card as the chat would show it, in what a Live Activity allows: its header, then up to three rows (the days of a
/// forecast, appointments, emails, figures with their trend, objectives with their bar).
private struct GlanceDetail: View {
    let glance: CardGlance
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: glance.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(ActivityStyle.accent)
                    .frame(width: 24, height: 24).background(ActivityStyle.accent.opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(glance.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                    if let line = glance.lines.first { Text(line).font(.caption2).foregroundStyle(.white.opacity(0.65)).lineLimit(1) }
                }
                Spacer(minLength: 4)
                if !glance.value.isEmpty {
                    Text(glance.value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            ForEach(Array(glance.rows.enumerated()), id: \.offset) { _, row in GlanceRow(row: row) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct GlanceRow: View {
    let row: CardGlance.Row
    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 7) {
                if !row.symbol.isEmpty {
                    Image(systemName: row.symbol).font(.system(size: row.symbol == "circle.fill" ? 6 : 11, weight: .semibold))
                        .foregroundStyle(row.symbol == "circle.fill" ? ActivityStyle.accent : .white.opacity(0.8)).frame(width: 16)
                }
                Text(row.label).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1).layoutPriority(1)
                if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1) }
                Spacer(minLength: 4)
                if !row.value.isEmpty { Text(row.value).font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(.white.opacity(0.85)).lineLimit(1) }
            }
            if let progress = row.progress {
                ProgressView(value: progress).tint(ActivityStyle.accent).scaleEffect(x: 1, y: 0.7, anchor: .center)
            }
        }
    }
}
