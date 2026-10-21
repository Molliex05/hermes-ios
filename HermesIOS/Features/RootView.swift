import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    var body: some View {
        Group {
            if model.booting && !model.demo {
                OrbView(phase: .idle, animated: false).frame(width: 84, height: 84)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(AppTheme.background)
            } else if model.connections.isEmpty && !model.demo {
                OnboardingView(model: model)
            } else {
                ChatView(model: model).id(model.navigationRevision)
            }
        }
        .background(AppTheme.background)
        .overlay(alignment: .top) { ToastBanner(model: model) }
        .overlay { NoticeDialog(model: model) }
        .task(id: model.toast) {
            guard model.toast != nil else { return }
            do { try await Task.sleep(for: .seconds(5)); model.toast = nil } catch { }
        }
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

/// Global notices (ownership, failures) as an in-app dialog: usable while a sheet is open, and never a system alert.
struct NoticeDialog: View {
    let model: AppModel
    var body: some View {
        AppDialogOverlay(title: model.notice == RPCFailure.ownershipMessage ? "Conversation ouverte ailleurs" : "Hermès iOS",
                         isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            if model.canContinueInNewChat {
                Button("Nouveau fil avec mon brouillon") { Task { await model.continueInNewChat() } }
            }
            Button("Compris", role: .cancel) { model.notice = nil }
        } message: { Text(model.notice ?? "") }
            .animation(.easeOut(duration: 0.15), value: model.notice)
    }
}
