import SwiftUI
import WidgetKit

@main
struct HermesIOSWidgetsBundle: WidgetBundle {
    var body: some Widget {
        AgentBoardWidget()
        HermesVoiceWidget()
        HermesLiveActivity()
    }
}
