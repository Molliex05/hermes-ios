import SwiftUI

struct ChatView: View {
    @Bindable var model: AppModel
    @State private var destination: AppDestination?
    @State private var pinnedToBottom = true
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if model.transcript.messages.isEmpty { emptyChat }
                else { messages }
            }
            .background(AppTheme.background)
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $destination) { page in
                SpacesView(model: model, initial: page == .spaces ? nil : page)
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(30)
            }
            .onChange(of: model.draft) { _, _ in model.draftChanged() }
            .onChange(of: model.selected?.storedID) { _, _ in pinnedToBottom = true }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { present(.agents) } label: {
                HStack(spacing: 11) {
                    AgentAvatar(name: model.agent?.name ?? "default", size: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(model.agent?.title ?? "Hermes").font(.headline)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                        ConnectionIndicator(model: model).lineLimit(1)
                    }
                }
            }.buttonStyle(.plain).accessibilityLabel("Choisir un agent").accessibilityIdentifier("quick-agents")
            Spacer()
            RoundButton(symbol: "square.and.pencil", label: "Nouvelle conversation") { model.newChat(); focused = true }
        }.padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 16)
    }

    private func present(_ page: AppDestination) {
        focused = false
        destination = page
    }

    private var emptyChat: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Spacer(minLength: 70)
                AgentMark(size: 48)
                Text("Un peu de place\npour vos idées.").font(.system(size: 37, weight: .regular, design: .serif)).tracking(-1.1)
                Text("Une question, une envie, un projet.\nHermes reprend le fil avec vous.")
                    .foregroundStyle(.secondary).lineSpacing(4)
                VStack(spacing: 10) {
                    suggestion("Faire le point", subtitle: "Retrouver ce qui compte aujourd’hui", symbol: "sun.max", prompt: "Aide-moi à faire le point et à choisir mes priorités pour aujourd’hui.")
                    suggestion("Explorer une idée", subtitle: "Laisser la curiosité faire son chemin", symbol: "sparkle", prompt: "J’ai une idée à explorer. Aide-moi à la préciser.")
                    suggestion("Passer à l’action", subtitle: "Un premier pas, tout simplement", symbol: "arrow.up.right", prompt: "Aide-moi à transformer mon projet en un premier pas concret.")
                }.padding(.top, 14)
            }.padding(28).frame(maxWidth: 640).frame(maxWidth: .infinity, alignment: .center)
        }.scrollDismissesKeyboard(.interactively)
    }

    private func suggestion(_ title: String, subtitle: String, symbol: String, prompt: String) -> some View {
        Button { model.draft = prompt; focused = true } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(AppTheme.accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.tertiary)
            }.padding(17).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 19))
                .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(AppTheme.line))
        }.buttonStyle(.plain)
    }

    private var messages: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 27) {
                        Text("\(model.demo ? "APERÇU" : "VOTRE CONVERSATION") · \(model.agent?.title.uppercased() ?? "HERMES")")
                            .font(.system(size: 10, weight: .medium)).tracking(1.6).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity).padding(.top, 24).padding(.bottom, 4)
                        ForEach(model.transcript.messages) { message in
                            MessageView(message: message, agent: model.agent?.title ?? "Hermes")
                                .id(message.id)
                        }
                        if let activity = model.transcript.activity, model.transcript.running {
                            HStack(spacing: 9) {
                                Image(systemName: "sparkle").foregroundStyle(AppTheme.accent)
                                Text(activity).lineLimit(2)
                            }.font(.caption).foregroundStyle(.secondary).padding(.leading, 2)
                        }
                        if let failure = model.transcript.failure, !failure.isEmpty {
                            Label(failure, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(AppTheme.accent)
                        }
                        if let approval = model.transcript.approval { ApprovalCard(payload: approval, model: model) }
                        if let clarification = model.transcript.clarification { ClarificationCard(payload: clarification, model: model) }
                        if let credential = model.transcript.credential { CredentialCard(payload: credential, model: model) }
                        Color.clear.frame(height: 1).id("bottom").background(GeometryReader { marker in
                            Color.clear.preference(key: BottomPreference.self, value: marker.frame(in: .named("chat-scroll")).maxY)
                        })
                    }.padding(.horizontal, 26).padding(.bottom, 20).frame(maxWidth: 720).frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "chat-scroll")
                .scrollDismissesKeyboard(.interactively)
                .chatScrollAnchors()
                .onPreferenceChange(BottomPreference.self) { y in pinnedToBottom = y < geo.size.height + 100 }
                .onChange(of: model.transcript.messages.last?.text) { _, _ in
                    if pinnedToBottom { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: model.transcript.messages.count) { _, _ in
                    if pinnedToBottom { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !pinnedToBottom {
                        RoundButton(symbol: "arrow.down", label: "Dernier message") {
                            pinnedToBottom = true
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        }.padding(18)
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
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
            HStack(alignment: .bottom, spacing: 10) {
                Button { present(.spaces) } label: {
                    Image(systemName: "circle.grid.2x2").font(.system(size: 21, weight: .regular))
                        .foregroundStyle(.primary).frame(width: 42, height: 44)
                }.accessibilityLabel("Ouvrir les espaces").accessibilityIdentifier("app-navigation")
                TextField("Message…", text: $model.draft, axis: .vertical)
                    .lineLimit(1...7).font(.body).padding(.vertical, 12).focused($focused)
                    .accessibilityIdentifier("chat-composer")
                Button {
                    Task {
                        if model.transcript.running { await model.interrupt() }
                        else { await model.send() }
                    }
                } label: {
                    Image(systemName: model.transcript.running ? "stop.fill" : "arrow.up")
                        .font(.system(size: model.transcript.running ? 13 : 19, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 42, height: 42)
                        .background(model.canSend || model.transcript.running ? AppTheme.accent : Color.secondary.opacity(0.28), in: Circle())
                }.disabled(!model.canSend && !model.transcript.running)
                    .accessibilityLabel(model.transcript.running ? "Arrêter la réponse" : "Envoyer")
                    .accessibilityIdentifier("send-message")
            }.padding(9).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 28))
                .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(AppTheme.line))
                .shadow(color: .black.opacity(0.045), radius: 22, y: 6)
        }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 8).frame(maxWidth: 750).frame(maxWidth: .infinity)
            .background(AppTheme.background)
    }
}

struct CredentialCard: View {
    let payload: JSONValue
    let model: AppModel
    @State private var value = ""
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(payload["event_type"].string == "sudo.request" ? "Accès administrateur demandé" : "Hermes demande un secret", systemImage: "key").font(.subheadline.weight(.semibold))
            if !payload["prompt"].string.isEmpty { Text(payload["prompt"].string).font(.caption).foregroundStyle(.secondary) }
            SecureField("Valeur envoyée directement à Hermes", text: $value).textFieldStyle(.roundedBorder)
            HStack {
                Button("Annuler") { respond("") }.buttonStyle(.bordered)
                Spacer()
                Button("Transmettre") { respond(value) }.buttonStyle(.borderedProminent).disabled(value.isEmpty)
            }.disabled(busy)
            Text("Cette valeur ne sera pas conservée dans l’historique local.").font(.caption2).foregroundStyle(.secondary)
        }.hermesCard()
    }
    private func respond(_ text: String) {
        busy = true
        Task { await model.answerCredential(text); value = ""; busy = false }
    }
}

private struct BottomPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct MessageView: View {
    let message: ChatMessage
    let agent: String
    private var user: Bool { message.role == "user" }
    var body: some View {
        HStack(alignment: .top) {
            if user { Spacer(minLength: 42) }
            VStack(alignment: .leading, spacing: 10) {
                if !user {
                    HStack(spacing: 8) { AgentMark(size: 17); Text(agent).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                }
                MarkdownText(text: message.text)
                    .textSelection(.enabled)
                    .padding(user ? 17 : 0)
                    .background(user ? AppTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 21))
                    .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(user ? AppTheme.line : .clear))
                if message.delivery != .confirmed {
                    Text(message.delivery == .sending ? "Envoi…" : message.delivery == .uncertain ? "Réception à vérifier dans l’historique" : "Non envoyé · copiez pour réessayer")
                        .font(.caption2).foregroundStyle(message.delivery == .sending ? Color.secondary : AppTheme.accent)
                }
            }
            if !user { Spacer(minLength: 5) }
        }
        .contextMenu {
            Button("Copier", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
            ShareLink(item: message.text) { Label("Partager", systemImage: "square.and.arrow.up") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(user ? "user-message" : "assistant-message")
    }
}

struct MarkdownText: View {
    let text: String
    var body: some View {
        let sections = text.components(separatedBy: "```")
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if index % 2 == 1 {
                    let lines = section.components(separatedBy: "\n")
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(lines.first ?? "code").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button { UIPasteboard.general.string = lines.dropFirst().joined(separator: "\n") } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("Copier le code")
                        }
                        ScrollView(.horizontal) { Text(lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .newlines)).font(.system(.caption, design: .monospaced)) }
                    }.padding(15).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                } else if !section.isEmpty {
                    Text(LocalizedStringKey(section)).font(.body).lineSpacing(6).tint(AppTheme.accent)
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

struct ApprovalCard: View {
    let payload: JSONValue
    let model: AppModel
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Hermes vous demande l’accord", systemImage: "hand.raised").font(.subheadline.weight(.semibold))
            Text(payload["command"].string).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            if !payload["reason"].string.isEmpty { Text(payload["reason"].string).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Refuser") { answer("deny") }.buttonStyle(.bordered)
                Spacer()
                if payload["choices"].array.contains(.string("once")) {
                    Button("Autoriser une fois") { answer("once") }.buttonStyle(.borderedProminent)
                }
            }.font(.caption).disabled(busy)
        }.hermesCard()
    }
    private func answer(_ choice: String) { busy = true; Task { await model.answerApproval(choice); busy = false } }
}

struct ClarificationCard: View {
    let payload: JSONValue
    let model: AppModel
    @State private var answer = ""
    @State private var busy = false
    @State private var answered = Set<String>()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("À vous de choisir", systemImage: "bubble.left.and.text.bubble.right").font(.subheadline.weight(.semibold))
            if payload["questions"].array.isEmpty {
                question(payload, qid: nil)
            } else {
                ForEach(Array(payload["questions"].array.enumerated()), id: \.offset) { _, q in
                    if !answered.contains(q["qid"].string) { question(q, qid: q["qid"].string) }
                }
            }
        }.hermesCard()
    }
    @ViewBuilder private func question(_ q: JSONValue, qid: String?) -> some View {
        Text(q["question"].string).font(.subheadline)
        ForEach(Array(q["choices"].array.enumerated()), id: \.offset) { _, choice in
            Button(choice.string) { respond(choice.string, qid: qid) }.buttonStyle(.bordered).disabled(busy)
        }
        HStack {
            TextField("Votre réponse…", text: $answer).textFieldStyle(.roundedBorder)
            Button { respond(answer, qid: qid) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }.disabled(answer.isEmpty || busy)
        }
    }
    private func respond(_ text: String, qid: String?) {
        busy = true
        Task { await model.answerClarification(text, qid: qid); if let qid { answered.insert(qid) }; answer = ""; busy = false }
    }
}
