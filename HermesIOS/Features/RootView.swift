import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    var body: some View {
        Group {
            if model.connections.isEmpty && !model.demo {
                OnboardingView(model: model)
            } else {
                ChatView(model: model)
            }
        }
        .background(AppTheme.background)
        .alert(model.notice == RPCFailure.ownershipMessage ? "Conversation ouverte ailleurs" : "Hermès iOS", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            if model.canContinueInNewChat {
                Button("Nouveau fil avec mon brouillon") { Task { await model.continueInNewChat() } }
            }
            Button("Compris", role: .cancel) { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }
}
