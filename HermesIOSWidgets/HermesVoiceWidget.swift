import AppIntents
import SwiftUI
import WidgetKit

/// One tap from the Home or Lock Screen to a voice call with the chosen agent. After Face ID the call starts without
/// opening the app (`StartCallIntent`) and shows in the Dynamic Island.
struct HermesVoiceWidget: Widget {
    static let kind = "HermesVoiceWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: VoiceWidgetConfiguration.self, provider: VoiceProvider()) { entry in
            Button(intent: StartCallIntent(agent: entry.agent)) { VoiceWidgetView(agent: entry.agent) }
                .buttonStyle(.plain)
                .containerBackground(for: .widget) { WidgetBackground() }
        }
        .configurationDisplayName("Appeler un agent")
        .description("Démarre un appel vocal en un geste, sans ouvrir l’app.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

/// The call button for CarPlay's Dashboard: no Face ID, since it only works while the iPhone is connected to the car
/// (`CarCallIntent`). Elsewhere it says so; on the Home Screen « Appeler un agent » is the one to use. (« Appeler un agent »
/// stays offered in CarPlay too: marking it out of place there needs iOS 26, and the widgets still start at iOS 18.)
struct CarVoiceWidget: Widget {
    static let kind = "CarVoiceWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: VoiceWidgetConfiguration.self, provider: VoiceProvider()) { entry in
            Button(intent: CarCallIntent(agent: entry.agent)) { VoiceWidgetView(agent: entry.agent, inCar: true) }
                .buttonStyle(.plain)
                .containerBackground(for: .widget) { WidgetBackground() }
        }
        .configurationDisplayName("Appeler en voiture")
        .description("Pour CarPlay : démarre un appel vocal sans déverrouiller l’iPhone, seulement quand il est connecté à la voiture.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
        .disfavoredLocations([.homeScreen], for: [.systemSmall])
    }
}

struct VoiceWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Agent à appeler"
    @Parameter(title: "Agent") var agent: AgentEntity?
}

private struct VoiceEntry: TimelineEntry {
    let date: Date
    let agent: AgentEntity?
}

private struct VoiceProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> VoiceEntry { VoiceEntry(date: .now, agent: nil) }
    func snapshot(for configuration: VoiceWidgetConfiguration, in context: Context) async -> VoiceEntry {
        VoiceEntry(date: .now, agent: configuration.agent)
    }
    func timeline(for configuration: VoiceWidgetConfiguration, in context: Context) async -> Timeline<VoiceEntry> {
        Timeline(entries: [VoiceEntry(date: .now, agent: configuration.agent)], policy: .never)
    }
}

private struct VoiceWidgetView: View {
    let agent: AgentEntity?
    var inCar = false
    @Environment(\.widgetFamily) private var family
    private var name: String { agent?.title ?? "Hermès" }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack { AccessoryWidgetBackground(); Image(systemName: "waveform").font(.title2.weight(.semibold)) }
                .accessibilityLabel("Appeler \(name)")
        case .accessoryRectangular:
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.title2.weight(.semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.headline)
                    Text("Appel vocal").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 4)
        default:
            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(WidgetPalette.accent.gradient).frame(width: 58, height: 58)
                    Image(systemName: inCar ? "car.fill" : "waveform").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                }
                Text("Parler à \(name)").font(.subheadline.weight(.semibold))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
