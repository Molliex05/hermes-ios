import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @State private var tab = 0
    var body: some View {
        Group {
            if model.connections.isEmpty && !model.demo {
                OnboardingView(model: model)
            } else {
                TabView(selection: $tab) {
                    ChatView(model: model).tabItem { Label("Conversation", systemImage: "bubble.left.and.bubble.right") }.tag(0)
                    AgentsView(model: model, openChat: { tab = 0 }).tabItem { Label("Agents", systemImage: "square.grid.2x2") }.tag(1)
                    SettingsView(model: model).tabItem { Label("Réglages", systemImage: "slider.horizontal.3") }.tag(2)
                }
            }
        }
        .background(AppTheme.background)
        .alert("Hermès iOS", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("Compris", role: .cancel) { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }
}
