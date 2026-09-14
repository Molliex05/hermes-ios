import SwiftUI

@main
struct HermesIOSApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .tint(AppTheme.accent)
                .task { await model.boot() }
                .onChange(of: phase) { _, value in
                    // A temporary inactive phase must not tear down the chat socket.
                    if value == .active { Task { await model.setForeground(true) } }
                    else if value == .background { Task { await model.setForeground(false) } }
                }
        }
    }
}
