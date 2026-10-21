import SwiftUI
import WidgetKit

@main
struct HermesIOSWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NorivenFinanceWidget()
        HermesVoiceWidget()
        HermesLiveActivity()
    }
}
