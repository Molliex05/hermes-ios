import AppIntents
import SwiftUI
import WidgetKit

/// « Appeler Jarvis » at the bottom of the Lock Screen, in Control Center or on the Action button: after Face ID the call
/// starts in the Dynamic Island, the app staying closed. The agent is chosen when the control is added.
struct CallControl: ControlWidget {
    static let kind = "org.hermesios.HermesIOS.call"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, intent: CallControlConfiguration.self) { configuration in
            ControlWidgetButton(action: StartCallIntent(agent: configuration.agent)) {
                Label(configuration.agent.map { "Appeler \($0.title)" } ?? "Appeler l’agent", systemImage: "waveform")
            }
        }
        .displayName("Appeler un agent")
        .description("Démarre un appel vocal sans ouvrir l’app, après Face ID.")
    }
}

struct CallControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Agent à appeler"
    @Parameter(title: "Agent") var agent: AgentEntity?
}
