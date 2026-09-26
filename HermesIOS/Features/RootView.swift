import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    var body: some View {
        Group {
            if model.connections.isEmpty && !model.demo {
                OnboardingView(model: model)
            } else {
                ChatView(model: model).id(model.navigationRevision)
            }
        }
        .background(AppTheme.background)
        .overlay(alignment: .top) { ToastBanner(model: model) }
        .task(id: model.toast) {
            guard model.toast != nil else { return }
            do { try await Task.sleep(for: .seconds(5)); model.toast = nil } catch { }
        }
        .alert(model.notice == RPCFailure.ownershipMessage ? "Conversation ouverte ailleurs" : "Hermès iOS", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            if model.canContinueInNewChat {
                Button("Nouveau fil avec mon brouillon") { Task { await model.continueInNewChat() } }
            }
            Button("Compris", role: .cancel) { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }
}

struct ToastBanner: View {
    let model: AppModel
    var body: some View {
        if let message = model.toast {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.accent)
                Text(message).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                Button { model.toast = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Fermer la confirmation")
            }.padding(.leading, 16).padding(.trailing, 4)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(AppTheme.line))
                .padding(16).accessibilityElement(children: .combine)
        }
    }
}
