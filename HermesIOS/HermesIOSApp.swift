import SwiftUI

@main
struct HermesIOSApp: App {
    @UIApplicationDelegateAdaptor(NotificationAppDelegate.self) private var notificationDelegate
    @State private var push = PushNotifications.shared
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .tint(AppTheme.accent)
                .task {
                    await model.boot()
                    await push.configure(model.connections)
                    #if DEBUG
                    await push.authorizeFixtureIfRequested()
                    #endif
                }
                .task(id: push.pendingTarget?.id) {
                    guard let target = push.pendingTarget else { return }
                    await model.openNotification(target)
                }
                .onChange(of: phase) { _, value in
                    // A temporary inactive phase must not tear down the chat socket.
                    if value == .active { Task { await model.setForeground(true); await push.configure(model.connections) } }
                    else if value == .background { Task { await model.setForeground(false) } }
                }
        }
    }
}
