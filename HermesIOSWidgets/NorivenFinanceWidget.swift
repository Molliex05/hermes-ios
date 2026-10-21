import SwiftUI
import WidgetKit

/// Noriven's month at a glance. Reads the snapshot the app saved in the App Group; never touches the network.
/// Amounts are `privacySensitive`, so the Lock Screen hides them until the iPhone is unlocked.
struct NorivenFinanceWidget: Widget {
    static let kind = "NorivenFinanceWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: FinanceProvider()) { entry in
            FinanceWidgetView(entry: entry)
                .widgetURL(URL(string: "hermesios://open"))
                .containerBackground(for: .widget) { WidgetBackground() }
        }
        .configurationDisplayName("Noriven · Finances")
        .description("Revenu, dépenses et profit du mois, et le MRR.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}
