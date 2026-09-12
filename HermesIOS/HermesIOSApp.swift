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
                    Task { await model.setForeground(value == .active) }
                }
        }
    }
}
