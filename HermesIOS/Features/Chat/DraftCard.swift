import LocalAuthentication
import SwiftUI

/// An email the agent wrote and saved as a Gmail draft: read it here, ask for a change, then send it yourself. The agent
/// cannot send: « Relire et envoyer » reads the draft as Gmail holds it, shows it, and sends it after Face ID; without a
/// draft id (an older card) it opens in Gmail instead.
struct DraftCard: View {
    let draft: ChatCard.Draft
    @Environment(\.openURL) private var openURL
    @Environment(\.chatReply) private var reply
    @Environment(\.cardsInteractive) private var interactive
    @Environment(\.draftOutbox) private var outbox
    @State private var expanded = false
    @State private var asked: String?
    @State private var reviewing = false
    @State private var sent = false
    @ScaledMetric private var labelWidth: CGFloat = 22

    private static let drafts = URL(string: "https://mail.google.com/mail/u/0/#drafts")!
    private static let changes = ["Plus court", "Plus formel", "Plus chaleureux"]
    private var live: Bool { reply != nil && interactive && asked == nil && !sent }
    private var sendable: Bool { outbox != nil && !draft.draftID.isEmpty }
    private var noriven: Bool { MailID.isNoriven(draft.draftID) }
    private var long: Bool { draft.body.count > 280 || draft.body.filter(\.isNewline).count > 5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: sent ? "paperplane.fill" : "envelope.open.fill").font(.caption.weight(.bold)).foregroundStyle(AppTheme.accent)
                Text(sent ? "Courriel envoyé" : "Brouillon à relire").font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                if !draft.to.isEmpty { field("À", draft.to) }
                if !draft.cc.isEmpty { field("Cc", draft.cc) }
                if !draft.subject.isEmpty { Text(draft.subject).font(.headline).fixedSize(horizontal: false, vertical: true).padding(.top, 2) }
            }
            if !draft.body.isEmpty {
                Text(draft.body).font(.subheadline).lineLimit(expanded ? nil : 6).fixedSize(horizontal: false, vertical: true)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppTheme.line))
                if long {
                    Button(expanded ? "Réduire" : "Tout voir") { withAnimation(.snappy(duration: 0.25)) { expanded.toggle() } }
                        .font(.caption.weight(.semibold)).buttonStyle(.plain).foregroundStyle(AppTheme.accent)
                }
            }
            if !draft.attachments.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(draft.attachments, id: \.self) { name in
                        Label(name, systemImage: "paperclip").font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(AppTheme.line.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            FlowLayout(spacing: 8) {
                if sent {
                    Label("Envoyé", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 11).foregroundStyle(.green).background(Color.green.opacity(0.12), in: Capsule())
                } else if sendable {
                    Button { Haptics.select(); reviewing = true } label: {
                        Label("Relire et envoyer", systemImage: "paperplane").font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 11).foregroundStyle(.white).background(AppTheme.accent, in: Capsule())
                    }.buttonStyle(PressableStyle()).accessibilityIdentifier("draft-review")
                }
                if !noriven {
                    Button { Haptics.select(); openURL(draft.url ?? Self.drafts) } label: {
                        Label("Ouvrir dans Gmail", systemImage: "arrow.up.right.square").font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 11)
                            .foregroundStyle(sendable || sent ? AppTheme.accent : .white)
                            .background(sendable || sent ? AppTheme.accent.opacity(0.12) : AppTheme.accent, in: Capsule())
                    }.buttonStyle(PressableStyle())
                }
                if !sent {
                    ForEach(Self.changes, id: \.self) { change in
                        Button {
                            guard live, let reply, reply.send("\(change) pour ce brouillon.") else { return }
                            Haptics.send(); asked = change
                        } label: {
                            Text(asked == change ? "\(change) · demandé" : change).font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 11)
                                .foregroundStyle(AppTheme.accent).background(AppTheme.accent.opacity(0.12), in: Capsule())
                        }.buttonStyle(PressableStyle()).disabled(!live).opacity(live || asked == change ? 1 : 0.5)
                    }
                }
            }
            Text(caption).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14).cardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card-draft")
        .onAppear { sent = !draft.draftID.isEmpty && SentDrafts.contains(draft.draftID) }
        .sheet(isPresented: $reviewing) {
            if let outbox { DraftSendSheet(draftID: draft.draftID, outbox: outbox) { sent = true } }
        }
    }

    private var caption: String {
        if noriven { return sent ? "Envoyé par vous." : "Rien ne part sans vous : vous relisez le brouillon tel qu’il est dans la boîte, puis Face ID signe l’envoi." }
        return sent ? "Envoyé depuis Gmail, par vous." : sendable ? "Rien ne part sans vous : vous relisez le brouillon tel qu’il est dans Gmail, puis Face ID."
            : "Rien n’est envoyé : c’est vous qui envoyez, depuis Gmail."
    }

    private func field(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(minWidth: labelWidth, alignment: .leading)
            Text(value).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The draft as Gmail holds it, every recipient (Bcc too) and attachment shown, sent only after Face ID. If the draft
/// changed after it was read here, the server refuses and the sheet reads it again.
struct DraftSendSheet: View {
    let draftID: String
    let outbox: DraftOutbox
    let onSent: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: OutboxDraft?
    @State private var problem: String?
    @State private var sending = false
    @State private var done = false
    private var noriven: Bool { MailID.isNoriven(draftID) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").font(.subheadline.weight(.medium)).foregroundStyle(.orange)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    if let draft { content(draft) } else if problem == nil { ProgressView(noriven ? "Lecture du brouillon…" : "Lecture du brouillon dans Gmail…").frame(maxWidth: .infinity).padding(.top, 40) }
                }
                .padding(16)
            }
            .background(AppTheme.background)
            .navigationTitle(done ? "Envoyé" : "Relire avant d’envoyer").navigationBarTitleDisplayMode(.inline)
            .toolbar { AppToolbarItem(placement: .cancellationAction) { AppCloseButton { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                if let draft, !done {
                    Button { Task { await send(draft) } } label: {
                        HStack(spacing: 8) {
                            if sending { ProgressView().tint(.white) } else { Image(systemName: "faceid") }
                            Text(sending ? "Envoi…" : "Envoyer")
                        }
                        .font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(draft.hasRecipient ? AppTheme.accent : Color.gray, in: Capsule())
                    }
                    .buttonStyle(PressableStyle()).disabled(sending || !draft.hasRecipient)
                    .padding(.horizontal, 16).padding(.bottom, 8).background(AppTheme.background)
                    .accessibilityIdentifier("draft-send")
                }
            }
            .task { await load() }
        }
        .presentationBackground(AppTheme.background).presentationCornerRadius(30).presentationDragIndicator(.visible)
        .interactiveDismissDisabled(sending)
    }

    @ViewBuilder private func content(_ draft: OutboxDraft) -> some View {
        if done {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundStyle(.green)
                Text("Courriel envoyé").font(.title3.weight(.semibold))
                Text(noriven ? "Il est dans « Envoyés » de \(draft.mailbox.isEmpty ? "la boîte" : draft.mailbox)." : "Il est dans « Envoyés » de Gmail.").font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.top, 40)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !draft.mailbox.isEmpty { row("De", draft.mailbox) }
                row("À", draft.to)
                if !draft.cc.isEmpty { row("Cc", draft.cc) }
                if !draft.bcc.isEmpty { row("Cci", draft.bcc, warn: true) }
                if !draft.hasRecipient { Text(noriven ? "Aucun destinataire : demande à l’agent de l’ajouter." : "Aucun destinataire : ajoute-le dans Gmail.").font(.caption).foregroundStyle(.orange) }
            }
            Text(draft.subject.isEmpty ? "(sans objet)" : draft.subject).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text(draft.body).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(AppTheme.line))
            if draft.truncated { Text("Texte long : la fin n’est pas affichée ici, elle sera envoyée telle quelle.").font(.caption).foregroundStyle(.secondary) }
            if !draft.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pièces jointes").font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase)
                    ForEach(draft.attachments) { file in
                        HStack(spacing: 8) {
                            Image(systemName: file.type.contains("pdf") ? "doc.richtext" : file.type.hasPrefix("image/") ? "photo" : "paperclip").foregroundStyle(AppTheme.accent)
                            Text(file.name).font(.subheadline).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            if file.size > 0 { Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
    }

    private func row(_ name: String, _ value: String, warn: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(warn ? .orange : .secondary).frame(width: 34, alignment: .leading)
            Text(value).font(.subheadline).foregroundStyle(warn ? .orange : .primary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func load() async {
        do { draft = try await outbox.load(draftID); problem = nil }
        catch { problem = error.localizedDescription }
    }

    private func send(_ shown: OutboxDraft) async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        if !shown.needsDeviceApproval {                                     // a Noriven send asks for Face ID when it signs
            let context = LAContext()
            do {
                guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Envoyer ce courriel") else { return }
            } catch { return }                                              // cancelled: nothing happens
        }
        do {
            try await outbox.send(shown)
            Haptics.send(); done = true; onSent()
            try? await Task.sleep(for: .seconds(1.2))
            dismiss()
        } catch ApprovalKey.Failure.cancelled {
            return
        } catch let failure as RPCFailure where failure.code == 409 {
            draft = nil
            await load()                                                    // show what the mailbox holds now
            problem = failure.localizedDescription
        } catch {
            problem = error.localizedDescription
        }
    }
}
