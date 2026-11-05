import SwiftUI

// Email cards (see `ChatCard.Email`): the inbox as a list, one message read, a triage. Every action asks Jarvis in the
// conversation (summarise, draft a reply, archive), with a sentence the app writes from the message id; Jarvis can save
// drafts and file mail, never send or delete. « Gmail » opens the message itself.

// MARK: - Shared pieces

/// The sender's initial on a colour of its own, the same for every message from them.
struct EmailAvatar: View {
    let sender: ChatCard.Sender
    var size: CGFloat = 34
    private var tint: Color {
        let seed = (sender.address.isEmpty ? sender.label : sender.address).lowercased().unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0x7FFF_FFFF }
        let palettes = AgentLook.Palette.allCases
        return palettes[seed % palettes.count].main
    }
    var body: some View {
        Text(sender.initial).font(.system(size: size * 0.42, weight: .bold, design: .rounded)).foregroundStyle(.white)
            .frame(width: size, height: size).background(tint.gradient, in: Circle())
            .accessibilityHidden(true)
    }
}

enum MailDate {
    private static let french = Locale(identifier: "fr_CA")
    /// « 10 h 03 » today, « Hier », « lun. » this week, « 12 oct. » this year, « 12/10/2025 » before.
    static func short(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(.dateTime.hour().minute().locale(french)) }
        if calendar.isDateInYesterday(date) { return "Hier" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, (0..<7).contains(days) {
            return date.formatted(.dateTime.weekday(.abbreviated).locale(french))
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) { return date.formatted(.dateTime.day().month(.abbreviated).locale(french)) }
        return date.formatted(.dateTime.day().month(.twoDigits).year().locale(french))
    }
    /// « samedi 1 novembre, 10 h 03 », for the message read.
    static func long(_ date: Date) -> String { date.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute().locale(french)) }
}

private struct MailChip: View {
    let text: String, symbol: String
    var tint: Color = .secondary
    var body: some View {
        Label(text, systemImage: symbol).font(.caption2.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(tint).background(tint.opacity(0.12), in: Capsule())
    }
}

/// What can be done with one message: ask Jarvis to summarise it, draft a reply or archive it, or open it in Gmail.
struct EmailActions: View {
    enum Action: String, CaseIterable { case reply, summarize, archive }
    let email: ChatCard.Email
    var offered: [Action] = Action.allCases
    /// Follow-ups written by the agent, sent as they are.
    var suggestions: [String] = []
    @Environment(\.openURL) private var openURL
    @Environment(\.chatReply) private var reply
    @Environment(\.cardsInteractive) private var interactive
    @State private var asked: Set<String> = []
    private var live: Bool { reply != nil && interactive && !email.messageID.isEmpty }

    var body: some View {
        FlowLayout(spacing: 8) {
            if live {
                ForEach(offered, id: \.self) { action in
                    pill(label(action), symbol: symbol(action), key: action.rawValue, primary: action == offered.first) { sentence(action) }
                }
            }
            if reply != nil && interactive {
                ForEach(suggestions, id: \.self) { text in pill(text, symbol: nil, key: text, primary: false) { text } }
            }
            if let url = email.gmailURL {
                Button { Haptics.select(); openURL(url) } label: {
                    Label("Gmail", systemImage: "arrow.up.right.square").font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .foregroundStyle(AppTheme.accent).background(AppTheme.accent.opacity(0.12), in: Capsule())
                }.buttonStyle(PressableStyle()).accessibilityLabel("Ouvrir dans Gmail")
            }
        }
    }

    private func label(_ action: Action) -> String {
        switch action { case .reply: "Répondre"; case .summarize: "Résumer"; case .archive: "Archiver" }
    }
    private func symbol(_ action: Action) -> String {
        switch action { case .reply: "arrowshape.turn.up.left"; case .summarize: "text.alignleft"; case .archive: "archivebox" }
    }
    private func sentence(_ action: Action) -> String {
        switch action {
        case .reply: "Prépare une réponse à \(email.reference)."
        case .summarize: "Résume \(email.reference)."
        case .archive: "Archive \(email.reference)."
        }
    }

    private func pill(_ text: String, symbol: String?, key: String, primary: Bool, sentence: @escaping () -> String) -> some View {
        let done = asked.contains(key)
        return Button {
            guard !done, let reply, reply.send(sentence()) else { return }
            Haptics.send(); asked.insert(key)
        } label: {
            Label { Text(done ? "\(text) · demandé" : text) } icon: { if let symbol { Image(systemName: done ? "checkmark" : symbol) } }
                .font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 9)
                .foregroundStyle(primary && !done ? .white : AppTheme.accent)
                .background(primary && !done ? AppTheme.accent : AppTheme.accent.opacity(0.12), in: Capsule())
        }.buttonStyle(PressableStyle()).disabled(done)
    }
}

/// A message in a list: who, when, what about, Jarvis's summary or Gmail's snippet. Touched, it shows what can be done.
struct EmailRow: View {
    let email: ChatCard.Email
    @State private var open = false
    @Environment(\.chatReply) private var reply
    @Environment(\.cardsInteractive) private var interactive
    private var opens: Bool { email.gmailURL != nil || (reply != nil && interactive && !email.messageID.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if opens {
                Button { Haptics.select(); withAnimation(.snappy(duration: 0.25)) { open.toggle() } } label: { content.contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityHint(open ? "Masque les actions" : "Montre les actions")
            } else {
                content
            }
            if open { EmailActions(email: email).padding(.leading, 46).transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            EmailAvatar(sender: email.sender)
                .overlay(alignment: .topLeading) {
                    if email.unread { Circle().fill(AppTheme.accent).frame(width: 9, height: 9).overlay(Circle().strokeBorder(AppTheme.surface, lineWidth: 2)).offset(x: -2, y: -2) }
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(email.sender.label).font(.subheadline.weight(email.unread ? .bold : .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if email.hasAttachments { Image(systemName: "paperclip").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).accessibilityLabel("Pièce jointe") }
                    if let date = email.date {
                        Text(MailDate.short(date)).font(.caption.weight(email.unread ? .semibold : .regular)).monospacedDigit()
                            .foregroundStyle(email.unread ? AppTheme.accent : .secondary).lineLimit(1)
                    }
                }
                if !email.subject.isEmpty {
                    Text(email.subject).font(.subheadline.weight(email.unread ? .semibold : .regular)).lineLimit(1)
                }
                if !email.summary.isEmpty {
                    Text(email.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                }
                if email.important || !email.folders.isEmpty {
                    HStack(spacing: 5) {
                        if email.important { MailChip(text: "Important", symbol: "exclamationmark", tint: .orange) }
                        ForEach(email.folders, id: \.self) { MailChip(text: $0, symbol: "folder") }
                    }.padding(.top, 3)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The inbox

struct InboxCard: View {
    let inbox: ChatCard.Inbox
    @State private var expanded = false
    @State private var sortAsked = false
    @Environment(\.chatReply) private var reply
    @Environment(\.cardsInteractive) private var interactive
    private var folds: Bool { inbox.items.count > 6 }
    private var visible: [ChatCard.Email] { folds && !expanded ? Array(inbox.items.prefix(5)) : inbox.items }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                CardTitle(text: inbox.title.isEmpty ? "Courriels" : inbox.title, symbol: "envelope")
                Spacer(minLength: 0)
                if inbox.unread > 0 { MailChip(text: inbox.unread == 1 ? "1 non lu" : "\(inbox.unread) non lus", symbol: "circle.fill", tint: AppTheme.accent) }
            }
            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, email in
                    if index > 0 { Divider().padding(.leading, 60) }
                    EmailRow(email: email)
                }
                if folds {
                    Divider()
                    Button { Haptics.select(); withAnimation(.snappy(duration: 0.3)) { expanded.toggle() } } label: {
                        HStack(spacing: 6) {
                            Text(expanded ? "Réduire" : "Voir les \(inbox.items.count - 5) autres")
                            Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                        }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.accent)
                        .frame(maxWidth: .infinity).padding(.vertical, 11).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                if inbox.ids.count >= 2 && reply != nil && interactive {
                    Divider()
                    Button {
                        guard !sortAsked, let reply, reply.send("Range ces courriels dans leurs dossiers et archive ce qui n’attend rien de moi : \(inbox.ids.joined(separator: ", ")).") else { return }
                        Haptics.send(); sortAsked = true
                    } label: {
                        Label(sortAsked ? "Tri demandé" : "Tout ranger", systemImage: sortAsked ? "checkmark" : "tray.and.arrow.down")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.accent)
                            .frame(maxWidth: .infinity).padding(.vertical, 11).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(sortAsked)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: CardStyle.radius, style: .continuous))
            .cardSurface()
        }
        .accessibilityIdentifier("card-emails")
    }
}

// MARK: - One message, read

struct EmailMessageCard: View {
    let message: ChatCard.Message
    @ScaledMetric private var labelWidth: CGFloat = 22
    private var email: ChatCard.Email { message.email }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "envelope.open.fill").font(.caption.weight(.bold)).foregroundStyle(AppTheme.accent)
                Text("Courriel").font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if email.important { MailChip(text: "Important", symbol: "exclamationmark", tint: .orange) }
                if email.unread { MailChip(text: "Non lu", symbol: "circle.fill", tint: AppTheme.accent) }
            }
            HStack(alignment: .center, spacing: 10) {
                EmailAvatar(sender: email.sender, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(email.sender.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !email.sender.address.isEmpty && !email.sender.name.isEmpty {
                        Text(email.sender.address).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if let date = email.date { Text(MailDate.long(date)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            if !email.to.isEmpty || !email.cc.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    if !email.to.isEmpty { field("À", email.to) }
                    if !email.cc.isEmpty { field("Cc", email.cc) }
                }
            }
            if !email.subject.isEmpty { Text(email.subject).font(.headline).fixedSize(horizontal: false, vertical: true) }
            if !message.due.isEmpty { MailChip(text: message.due, symbol: "clock.badge.exclamationmark", tint: .orange) }
            if !email.summary.isEmpty || !message.points.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if !email.summary.isEmpty { Text(email.summary).font(.subheadline).fixedSize(horizontal: false, vertical: true) }
                    ForEach(message.points, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(AppTheme.accent).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                            Text(point).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppTheme.line))
            }
            if !email.messageID.isEmpty { EmailBodyReader(messageID: email.messageID) }
            if email.hasAttachments {
                FlowLayout(spacing: 6) {
                    ForEach(email.attachments) { file in
                        HStack(spacing: 6) {
                            Image(systemName: symbol(file.kind)).font(.caption.weight(.semibold)).foregroundStyle(AppTheme.accent)
                            Text(file.name).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            if !file.size.isEmpty { Text(file.size).font(.caption2).foregroundStyle(.secondary) }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(AppTheme.line.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    if email.attachments.isEmpty {
                        MailChip(text: email.attachmentCount == 1 ? "1 pièce jointe" : "\(email.attachmentCount) pièces jointes", symbol: "paperclip")
                    }
                }
            }
            if !email.folders.isEmpty {
                HStack(spacing: 5) { ForEach(email.folders, id: \.self) { MailChip(text: $0, symbol: "folder") } }
            }
            EmailActions(email: email, offered: [.reply, .archive], suggestions: message.suggestions)
        }
        .padding(14).cardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card-email")
    }

    private func field(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(minWidth: labelWidth, alignment: .leading)
            Text(value).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func symbol(_ kind: ChatCard.Attachment.Kind) -> String {
        switch kind {
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .sheet: "tablecells"
        case .document: "doc.text"
        case .other: "paperclip"
        }
    }
}

/// The message whole, on request, scrolling inside its card. Someone else's words: plain text, with nothing to tap.
private struct EmailBodyReader: View {
    let messageID: String
    @Environment(\.draftOutbox) private var outbox
    @State private var mail: MailBody?
    @State private var open = false
    @State private var loading = false
    @State private var failure: String?
    @State private var textHeight: CGFloat = 0
    private static let tallest: CGFloat = 380

    var body: some View {
        if outbox != nil {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        Label(open ? "Masquer le courriel" : "Lire le courriel", systemImage: "doc.plaintext")
                        Spacer(minLength: 0)
                        if loading { ProgressView().controlSize(.small) }
                        else { Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0)) }
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.accent)
                    .padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(loading)
                if let failure { Text(failure).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if open, let mail {
                    ScrollView {
                        Text(verbatim: mail.text).font(.subheadline).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .onGeometryChange(for: CGFloat.self, of: \.size.height) { textHeight = $0 }
                    }
                    .frame(height: min(max(textHeight, 60), Self.tallest))
                    .scrollBounceBehavior(.basedOnSize)
                    .background(AppTheme.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppTheme.line))
                    .accessibilityIdentifier("email-body")
                    if mail.truncated { Text("Le courriel continue au-delà de ce qui s’affiche ici.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func toggle() {
        Haptics.select()
        if mail != nil { withAnimation(.snappy(duration: 0.25)) { open.toggle() }; return }
        guard let outbox else { return }
        loading = true; failure = nil
        Task {
            defer { loading = false }
            do {
                let read = try await outbox.read(messageID)
                guard !read.text.isEmpty else { failure = "Ce courriel n’a pas de texte à afficher."; return }
                withAnimation(.snappy(duration: 0.25)) { mail = read; open = true }
            } catch { failure = error.localizedDescription }
        }
    }
}

// MARK: - A triage

struct TriageCard: View {
    let triage: ChatCard.Triage
    private var largest: Int { max(1, triage.folders.map(\.count).max() ?? 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(text: triage.title.isEmpty ? "Tri des courriels" : triage.title, symbol: "tray.full")
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    if triage.total > 0 {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(triage.total)").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                            Text(triage.total == 1 ? "courriel rangé" : "courriels rangés").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        }
                    }
                    if triage.archived > 0 || triage.pendingCount > 0 || triage.drafts > 0 {
                        FlowLayout(spacing: 6) {
                            if triage.archived > 0 { MailChip(text: triage.archived == 1 ? "1 archivé" : "\(triage.archived) archivés", symbol: "archivebox") }
                            if triage.pendingCount > 0 { MailChip(text: "\(triage.pendingCount) à traiter", symbol: "tray", tint: .orange) }
                            if triage.drafts > 0 { MailChip(text: triage.drafts == 1 ? "1 brouillon prêt" : "\(triage.drafts) brouillons prêts", symbol: "square.and.pencil", tint: AppTheme.accent) }
                        }
                    }
                    ForEach(triage.folders) { folder in
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill").font(.subheadline).foregroundStyle(AppTheme.accent.opacity(0.8)).frame(width: 22).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    folderName(folder.name)
                                    Spacer(minLength: 8)
                                    if folder.count > 0 { Text("\(folder.count)").font(.subheadline.weight(.semibold)).monospacedDigit() }
                                }
                                if folder.count > 0 {
                                    GeometryReader { proxy in
                                        Capsule().fill(AppTheme.line)
                                            .overlay(alignment: .leading) { Capsule().fill(AppTheme.accent.opacity(0.7)).frame(width: max(6, proxy.size.width * CGFloat(folder.count) / CGFloat(largest))) }
                                    }.frame(height: 4).accessibilityHidden(true)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(14)
                if !triage.pending.isEmpty {
                    Divider()
                    Text("À traiter").font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase)
                        .padding(.horizontal, 14).padding(.top, 10).accessibilityAddTraits(.isHeader)
                    ForEach(Array(triage.pending.enumerated()), id: \.element.id) { index, email in
                        if index > 0 { Divider().padding(.leading, 60) }
                        EmailRow(email: email)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: CardStyle.radius, style: .continuous))
            .cardSurface()
        }
        .accessibilityIdentifier("card-triage")
    }

    /// « Factures/2026/Hydro » : the parents quiet, the folder itself in full.
    private func folderName(_ path: String) -> some View {
        let parts = path.split(separator: "/").map(String.init)
        let parents = parts.dropLast().joined(separator: " › ")
        let quiet = Text(parents.isEmpty ? "" : parents + " › ").foregroundStyle(.secondary), name = Text(parts.last ?? path).fontWeight(.semibold)
        return Text("\(quiet)\(name)").font(.subheadline).lineLimit(1).truncationMode(.head)
    }
}
