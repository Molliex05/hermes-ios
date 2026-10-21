import SwiftUI
import WidgetKit

/// One tap from the Home or Lock Screen to a voice call (`hermesios://voice`, handled by the app).
struct HermesVoiceWidget: Widget {
    static let kind = "HermesVoiceWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: VoiceProvider()) { _ in
            VoiceWidgetView().widgetURL(URL(string: "hermesios://voice"))
                .containerBackground(for: .widget) { WidgetBackground() }
        }
        .configurationDisplayName("Parler à Hermès")
        .description("Démarre une conversation vocale en un geste.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

private struct VoiceEntry: TimelineEntry { let date: Date }

private struct VoiceProvider: TimelineProvider {
    func placeholder(in context: Context) -> VoiceEntry { VoiceEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (VoiceEntry) -> Void) { completion(VoiceEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<VoiceEntry>) -> Void) {
        completion(Timeline(entries: [VoiceEntry(date: .now)], policy: .never))
    }
}

private struct VoiceWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack { AccessoryWidgetBackground(); Image(systemName: "waveform").font(.title2.weight(.semibold)) }
        case .accessoryRectangular:
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.title2.weight(.semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Hermès").font(.headline)
                    Text("Appel vocal").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 4)
        default:
            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(WidgetPalette.accent.gradient).frame(width: 58, height: 58)
                    Image(systemName: "waveform").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                }
                Text("Parler à Hermès").font(.subheadline.weight(.semibold))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
