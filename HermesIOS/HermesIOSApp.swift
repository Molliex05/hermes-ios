import SwiftUI

@main
struct HermesIOSApp: App {
    @UIApplicationDelegateAdaptor(NotificationAppDelegate.self) private var notificationDelegate
    @State private var push = PushNotifications.shared
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    init() {
        AppTheme.configureNavigationBars()
        VoiceSamples.applyLaunchArguments()
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .tint(AppTheme.accent).toggleStyle(AppToggleStyle())
                .task {
                    await model.boot()
                    await VoiceBench.autorun(model)
                    await push.configure(model.connections)
                    #if DEBUG
                    await push.authorizeFixtureIfRequested()
                    #endif
                }
                .task(id: push.pendingTarget?.id) {
                    guard let target = push.pendingTarget else { return }
                    await model.openNotification(target)
                }
                .onOpenURL { model.handle(url: $0) }
                .onChange(of: model.state) { _, value in
                    if value == .connected { Task { await model.refreshWidgets(retryUnavailable: true) } }
                }
                .onChange(of: phase) { _, value in
                    // A temporary inactive phase must not tear down the chat socket.
                    if value == .active { Task { await model.setForeground(true); await push.configure(model.connections); await model.refreshWidgets() } }
                    else if value == .inactive { model.appBecameInactive() }
                    else if value == .background { Task { await model.setForeground(false) } }
                }
        }
    }
}
