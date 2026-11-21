import AppIntents
import SwiftUI
import WidgetKit

/// One tap from the Home or Lock Screen to a voice call with the chosen agent. After Face ID the call starts without
/// opening the app (`StartCallIntent`) and shows in the Dynamic Island.
struct HermesVoiceWidget: Widget {
    static let kind = "HermesVoiceWidget"

    /// Kept out of CarPlay (iOS 26 and later): its Face ID cannot pass with the iPhone locked in the car, where
    /// « Appeler en voiture » is the one to use.
    private static var outOfCar: [WidgetLocation] {
        if #available(iOS 26.0, *) { [.carPlay] } else { [] }
    }

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
        .disfavoredLocations(Self.outOfCar, for: [.systemSmall])
    }
}

/// The call button for CarPlay's Dashboard: no Face ID, since it only works while the iPhone is connected to the car
/// (`CarCallIntent`). Elsewhere it says so; on the Home Screen « Appeler un agent » is the one to use.
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
    /// False in CarPlay and StandBy: no page around the button, which is read from a distance.
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    @Environment(\.colorScheme) private var scheme
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
            if inCar || !showsBackground { carButton } else { homeButton }
        }
    }

    /// In the car: one large disc in the agent's colours, its name, and what the tap does.
    private var carButton: some View {
        let palette = AgentLook.standard(for: agent?.id ?? "hermes").palette
        return VStack(alignment: .leading, spacing: 2) {
            ZStack {
                Circle().fill(LinearGradient(colors: [palette.light, palette.main], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: inCar ? "car.fill" : "waveform").font(.title.weight(.semibold)).foregroundStyle(.white)
            }
            .frame(width: 62, height: 62)
            .shadow(color: palette.main.opacity(0.35), radius: 8, y: 3)
            Spacer(minLength: 4)
            Text(name).font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(inCar ? "Parler sans déverrouiller" : "Appel vocal").font(.subheadline.weight(.medium))
                .foregroundStyle(scheme == .dark ? palette.light : palette.main).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(showsBackground ? 14 : 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine).accessibilityLabel("Appeler \(name)")
    }

    private var homeButton: some View {
            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(WidgetPalette.accent.gradient).frame(width: 58, height: 58)
                    Image(systemName: inCar ? "car.fill" : "waveform").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                }
                Text("Parler à \(name)").font(.subheadline.weight(.semibold))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
