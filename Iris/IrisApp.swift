import SwiftUI

@main
struct IrisApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .tint(IrisTheme.accent)
                .task { await model.boot() }
                .onChange(of: phase) { _, value in
                    Task { await model.setForeground(value == .active) }
                }
        }
    }
}
