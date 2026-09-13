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
        .alert("Hermès iOS", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("Compris", role: .cancel) { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }
}
