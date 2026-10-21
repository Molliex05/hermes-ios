import SwiftUI

/// Everything the composer shows that does not come from the draft itself.
struct ComposerState: Equatable {
    var running = false
    var canSend = false
    var sending = false
    var importing = false
    var attachments: [DraftAttachment] = []
    var chatError: String?
    var hasUnread = false
    var agentName = "default"
    var agentTitle = "Hermes"
    var voiceDisabled = false
    var attachDisabled = false
    var attachOpen = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.running == rhs.running && lhs.canSend == rhs.canSend && lhs.sending == rhs.sending
            && lhs.importing == rhs.importing && lhs.chatError == rhs.chatError && lhs.hasUnread == rhs.hasUnread
            && lhs.agentName == rhs.agentName && lhs.agentTitle == rhs.agentTitle
            && lhs.voiceDisabled == rhs.voiceDisabled && lhs.attachDisabled == rhs.attachDisabled && lhs.attachOpen == rhs.attachOpen
            && lhs.attachments.map(\.id) == rhs.attachments.map(\.id) && lhs.attachments.map(\.name) == rhs.attachments.map(\.name)
    }
}

/// Reads the model (including `transcript.running` through `canSend`) and passes values down.
/// The composer below re-renders on typing or when one of these values flips, never per token.
struct ChatComposerContainer: View {
    let model: AppModel
    var focused: FocusState<Bool>.Binding
    @Binding var attachOpen: Bool
    let present: (ChatSheet) -> Void
    let attach: (AttachChoice) -> Void
    let willSend: () -> Void

    var body: some View {
        let running = model.transcript.running
        let attachments = model.attachments
        let state = ComposerState(
            running: running,
            canSend: model.canSend,
            sending: model.sending,
            importing: model.importingAttachments,
            attachments: attachments,
            chatError: model.chatError,
            hasUnread: model.hasUnread(profile: model.profile),
            agentName: model.agent?.name ?? "default",
            agentTitle: model.agent?.title ?? "Hermes",
            voiceDisabled: model.sending || model.opening || running || (!model.demo && model.state != .connected),
            attachDisabled: model.sending || model.importingAttachments || attachments.count >= 4,
            attachOpen: attachOpen
        )
        ChatComposer(model: model, state: state, focused: focused, attachOpen: $attachOpen, present: present,
                     attach: attach, willSend: willSend).equatable()
    }
}

struct ChatComposer: View, Equatable {
    @Bindable var model: AppModel
    let state: ComposerState
    var focused: FocusState<Bool>.Binding
    @Binding var attachOpen: Bool
    let present: (ChatSheet) -> Void
    let attach: (AttachChoice) -> Void
    let willSend: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.state == rhs.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.attachOpen {
                AttachPanel(attached: state.attachments.count, limit: 4, choose: attach)
                    .transition(.scale(scale: 0.86, anchor: .bottomLeading).combined(with: .opacity))
            }
            if model.draft.hasSuffix("@") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.profiles) { agent in
                            Button { model.draft += agent.name + " " } label: {
                                HStack(spacing: 7) { AgentAvatar(name: agent.name, size: 24); Text(agent.title).font(.caption) }
                                    .padding(8).background(AppTheme.surface, in: Capsule())
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if !state.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(state.attachments) { item in
                                HStack(spacing: 7) {
                                    Image(systemName: item.isImage ? "photo" : "doc")
                                    Text(item.name).lineLimit(1).frame(maxWidth: 140)
                                    Button { model.removeAttachment(item) } label: {
                                        Image(systemName: "xmark").frame(width: 32, height: 44)
                                    }.disabled(state.sending).accessibilityLabel("Retirer \(item.name)")
                                }.font(.caption).padding(.leading, 12).background(AppTheme.background, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    }.padding(.horizontal, 4).accessibilityIdentifier("pending-attachments")
                }
                if state.importing { ProgressView("Ajout…").font(.caption).padding(8) }
                if let error = state.chatError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle").padding(.top, 12)
                        Text(error).font(.caption).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.chatError = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                            .accessibilityLabel("Fermer le message")
                    }.foregroundStyle(AppTheme.accent).padding(.leading, 8).accessibilityIdentifier("chat-error")
                }
                HStack(alignment: .bottom, spacing: 2) {
                    messageActions
                    TextField("Demander à \(state.agentTitle)", text: $model.draft, axis: .vertical)
                        .lineLimit(1...6).font(.body).focused(focused)
                        .padding(.vertical, 8).frame(minHeight: 44)
                        .accessibilityIdentifier("chat-composer")
                    trailingButton
                }
            }.padding(.horizontal, 6).padding(.vertical, 4)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(AppTheme.line))
                .shadow(color: .black.opacity(0.06), radius: 18, y: 5)
                .animation(.spring(response: 0.32, dampingFraction: 0.82), value: showsSend)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("composer-surface")
        }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 8).frame(maxWidth: 750).frame(maxWidth: .infinity)
            .animation(.spring(response: 0.34, dampingFraction: 0.8), value: state.attachOpen)
            .onChange(of: model.draft) { _, _ in model.draftChanged() }
    }

    private var messageActions: some View {
        Button { Haptics.select(); attachOpen.toggle() } label: {
            Image(systemName: "plus").font(.system(size: 19, weight: .light))
                .foregroundStyle(state.attachOpen ? AppTheme.accent : .secondary)
                .rotationEffect(.degrees(state.attachOpen ? 45 : 0))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(state.attachDisabled && state.attachments.count < 4)
            .accessibilityLabel(state.attachOpen ? "Fermer les pièces jointes" : "Ajouter une pièce jointe").accessibilityIdentifier("message-actions")
    }

    /// Voice while the field is empty; send (or stop) as soon as there is something to send or a reply is running.
    private var showsSend: Bool {
        state.running || state.sending || !state.attachments.isEmpty || !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder private var trailingButton: some View {
        if showsSend { sendButton.transition(.scale(scale: 0.6).combined(with: .opacity)) }
        else { voiceButton.transition(.scale(scale: 0.6).combined(with: .opacity)) }
    }

    private var voiceButton: some View {
        Button { Haptics.select(); present(.voice) } label: {
            Image(systemName: "waveform").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 40, height: 40).background(AppTheme.accent, in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Conversation vocale").accessibilityIdentifier("voice-mode")
            .disabled(state.voiceDisabled).opacity(state.voiceDisabled ? 0.45 : 1)
    }

    private var sendButton: some View {
        Button {
            Task {
                // Read live state at tap time rather than the last rendered value.
                if model.transcript.running { await model.interrupt() }
                else { Haptics.send(); willSend(); await model.send() }
            }
        } label: {
            Image(systemName: state.running ? "stop.fill" : "arrow.up")
                .font(.system(size: state.running ? 13 : 18, weight: .semibold))
                .foregroundStyle(.white).frame(width: 40, height: 40)
                .background(state.canSend || state.running ? AppTheme.accent : Color.secondary.opacity(0.28), in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!state.canSend && !state.running)
            .accessibilityLabel(state.running ? "Arrêter la réponse" : "Envoyer")
            .accessibilityIdentifier("send-message")
    }
}
