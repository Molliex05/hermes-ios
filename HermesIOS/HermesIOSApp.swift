import SwiftUI

@main
struct HermesIOSApp: App {
    @UIApplicationDelegateAdaptor(NotificationAppDelegate.self) private var notificationDelegate
    @State private var push = PushNotifications.shared
    @State private var model: AppModel
    @Environment(\.scenePhase) private var phase

    init() {
        AppTheme.configureNavigationBars()
        VoiceSamples.applyLaunchArguments()
        let model = AppModel()
        _model = State(initialValue: model)
        // A call started from the Lock Screen may launch the app in the background, with no window: the model is ready here.
        CallLauncher.start = { profile in await model.startBackgroundCall(profile: profile) }
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .tint(AppTheme.accent).toggleStyle(AppToggleStyle())
                .task {
                    await model.boot()
                    model.collectShares()
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
                    if value == .active { model.collectShares(); Task { await model.setForeground(true); await push.configure(model.connections); await model.refreshWidgets() } }
                    else if value == .inactive { model.appBecameInactive() }
                    else if value == .background { Task { await model.setForeground(false) } }
                }
        }
    }
}
