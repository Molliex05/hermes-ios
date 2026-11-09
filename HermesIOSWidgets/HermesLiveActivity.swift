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
                DynamicIslandExpandedRegion(.leading) { ActivityOrb(state: context.state, profile: context.attributes.profile, size: 44).padding(.leading, 4) }
                DynamicIslandExpandedRegion(.trailing) { ActivityClock(state: context.state).padding(.trailing, 6) }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(context.state.title).font(.headline).lineLimit(1)
                        Text(context.isStale && context.attributes.kind == "call" ? "Appel interrompu" : context.state.detail).font(.subheadline).foregroundStyle(ActivityStyle.detailColor(context.state)).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        if let glance = context.state.glance, !context.isStale { GlanceCard(glance: glance) }
                        ActivityButtons(kind: context.attributes.kind, state: context.state, stale: context.isStale, compact: context.state.glance != nil)
                    }.padding(.top, 4)
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
