import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Bindable var model: AppModel
    @State private var showPhotos = false
    @State private var compressing = false
    @State private var showFiles = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var attachmentContext = ""
    @State private var destination: AppDestination?
    @State private var pinnedToBottom = true
    @State private var draggingHistory = false
    @State private var bottomVisible = true
    @State private var toolsExpanded = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if model.transcript.messages.isEmpty && model.transcript.approval == nil && model.transcript.clarification == nil && model.transcript.credential == nil { emptyChat }
                else { messages }
            }
            .background(AppTheme.background)
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $destination) { page in
                SpacesView(model: model, initial: page == .spaces ? nil : page)
                    .overlay(alignment: .top) { ToastBanner(model: model) }
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(30)
            }
            .confirmationDialog("Résumer le contexte de cette conversation ?", isPresented: $compressing, titleVisibility: .visible) {
                Button("Résumer avec Hermes") { Task { await model.compactConversation() } }
            } message: { Text("Hermes conserve l’historique et réduit le contexte utilisé pour les prochaines réponses.") }
            .sheet(isPresented: Binding(get: { model.commandOutput != nil }, set: { if !$0 { model.commandOutput = nil } })) {
                NavigationStack {
                    ScrollView { MarkdownText(text: model.commandOutput ?? "").textSelection(.enabled).padding(24).frame(maxWidth: .infinity, alignment: .leading) }
                        .background(AppTheme.background).navigationTitle("Réponse de Hermes").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fermer", systemImage: "xmark") { model.commandOutput = nil } } }
                }
            }
            .photosPicker(isPresented: $showPhotos, selection: $photos, maxSelectionCount: max(1, 4 - model.attachments.count), matching: .images)
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                let context = attachmentContext
                Task {
                    model.importingAttachments = true
                    defer { model.importingAttachments = false }
                    do {
                        for url in try result.get() {
                            let access = url.startAccessingSecurityScopedResource()
                            defer { if access { url.stopAccessingSecurityScopedResource() } }
                            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                            guard size <= DraftAttachment.maximumBytes else { throw RPCFailure("Choisissez un fichier de 10 Mo maximum.") }
                            let data = try await Task.detached { try Data(contentsOf: url) }.value
                            try await model.addAttachment(data: data, name: url.lastPathComponent, mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", context: context)
                        }
                    } catch is CancellationError { }
                    catch { model.chatError = error.localizedDescription }
                }
            }
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                let context = attachmentContext
                Task {
                    model.importingAttachments = true
                    defer { model.importingAttachments = false; photos = [] }
                    do {
                        for item in items {
                            guard let data = try await item.loadTransferable(type: Data.self) else { throw RPCFailure("Cette photo n’est pas disponible.") }
                            let jpeg = try await Task.detached { try PhotoAttachment.jpeg(data) }.value
                            try await model.addAttachment(data: jpeg, name: "Photo-\(UUID().uuidString.prefix(8)).jpg", mimeType: "image/jpeg", context: context)
                        }
                    } catch is CancellationError { }
                    catch { model.chatError = error.localizedDescription }
                }
            }
            .onChange(of: model.draft) { _, _ in model.draftChanged() }
            .onChange(of: model.selected?.storedID) { _, _ in pinnedToBottom = true; toolsExpanded = false }
            .onChange(of: destination) { _, value in model.setChatVisible(value == nil && bottomVisible) }
            .onChange(of: bottomVisible) { _, visible in model.setChatVisible(destination == nil && visible) }
            .onAppear { model.setChatVisible(destination == nil && bottomVisible) }
            .onDisappear { model.setChatVisible(false) }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.selected?.title ?? "Nouvelle conversation").font(.headline)
                    .lineLimit(dynamicType.isAccessibilitySize ? 2 : 1).truncationMode(.tail)
                if model.state != .connected && !model.demo {
                    ConnectionIndicator(model: model).lineLimit(dynamicType.isAccessibilitySize ? 2 : 1)
                } else {
                    Text([model.agent?.title ?? "Hermes", model.activeConnection?.name ?? (model.demo ? "Aperçu interactif" : "")].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityLabel(model.demo ? "Aperçu interactif" : "Connecté à Hermes")
                        .accessibilityIdentifier("connection-status")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if model.selected != nil {
                Menu {
                    Button("Créer une branche", systemImage: "arrow.triangle.branch") { Task { await model.branchConversation() } }
                    Button("Résumer le contexte", systemImage: "arrow.down.right.and.arrow.up.left") { compressing = true }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .disabled(model.transcript.running || model.sending || model.voiceActive || model.state != .connected)
                    .accessibilityLabel("Actions de la conversation")
            }
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
                        ForEach(model.transcript.messages) { message in
                            MessageView(message: message, agent: model.agent?.title ?? "Hermes")
                                .equatable().id(message.id)
                        }
                        if let activity = model.transcript.activity, model.transcript.running {
                            HStack(spacing: 9) {
                                Image(systemName: "sparkle")
                                    .foregroundStyle(AppTheme.accent)
                                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                                    .accessibilityHidden(true)
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text(model.sending ? "Transmission à Hermès…"
                                         : model.state == .connected && model.transcript.isWaitingForResponse(at: context.date)
                                         ? "En attente de la réponse du modèle…" : activityTitle(activity))
                                        .lineLimit(2)
                                }
                            }.font(.caption).foregroundStyle(.secondary).padding(.leading, 2)
                        }
                        if !model.transcript.toolSteps.isEmpty { toolActivity }
                        if let failure = model.transcript.failure, !failure.isEmpty {
                            Label(failure, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(AppTheme.accent)
                        }
                        if let approval = model.transcript.approval { ApprovalCard(payload: approval, model: model).id(approval["rpc_id"].string + approval["request_id"].string) }
                        if let clarification = model.transcript.clarification { ClarificationCard(payload: clarification, model: model).id(clarification["rpc_id"].string + clarification["request_id"].string) }
                        if let credential = model.transcript.credential { CredentialCard(payload: credential, model: model).id(credential["rpc_id"].string + credential["request_id"].string) }
                        Color.clear.frame(height: 1).id("bottom").background(GeometryReader { marker in
                            Color.clear.preference(key: BottomPreference.self, value: marker.frame(in: .named("chat-scroll")).maxY)
                        })
                    }.padding(.horizontal, 26).padding(.top, 14).padding(.bottom, 20).frame(maxWidth: 720).frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "chat-scroll")
                .scrollDismissesKeyboard(.interactively)
                .chatScrollAnchors()
                .simultaneousGesture(DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        guard abs(value.translation.height) > abs(value.translation.width) else { return }
                        draggingHistory = true
                        if value.translation.height > 5 { pinnedToBottom = false }
                    }
                    .onEnded { _ in draggingHistory = false; if bottomVisible { pinnedToBottom = true } })
                .onPreferenceChange(BottomPreference.self) { y in
                    bottomVisible = y <= geo.size.height + 55
                    if !draggingHistory, bottomVisible { pinnedToBottom = true }
                    if pinnedToBottom, !draggingHistory, y > geo.size.height + 1 { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: model.transcript.messages.last?.text) { _, _ in
                    if pinnedToBottom, !draggingHistory { proxy.scrollTo("bottom", anchor: .bottom) }
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

    private func activityTitle(_ activity: String) -> String {
        guard let step = model.transcript.toolSteps.last(where: { $0.name == activity }) else { return activity }
        return step.title + "…"
    }

    private var toolActivity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { toolsExpanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "wrench.and.screwdriver")
                    Text("\(model.transcript.toolSteps.count) outil\(model.transcript.toolSteps.count > 1 ? "s" : "") utilisé\(model.transcript.toolSteps.count > 1 ? "s" : "")")
                    Image(systemName: toolsExpanded ? "chevron.up" : "chevron.down").font(.caption2)
                }.font(.caption).foregroundStyle(.secondary).frame(minHeight: 44)
            }.buttonStyle(.plain).accessibilityLabel("Activité des outils")
                .accessibilityValue(toolsExpanded ? "Développée" : "Réduite").accessibilityIdentifier("tool-activity")
            if toolsExpanded {
                ForEach(model.transcript.toolSteps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: step.state == .completed ? "checkmark" : step.state == .stopped ? "minus" : "ellipsis")
                            .foregroundStyle(step.state == .running ? AppTheme.accent : .secondary)
                        Text(step.title)
                        Spacer(minLength: 8)
                        Text(step.state == .completed ? "Terminé" : step.state == .stopped ? "Arrêté" : "En cours")
                            .foregroundStyle(.secondary)
                    }.font(.caption).padding(.vertical, 5)
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
            VStack(alignment: .leading, spacing: 4) {
                if !model.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.attachments) { item in
                                HStack(spacing: 7) {
                                    Image(systemName: item.isImage ? "photo" : "doc")
                                    Text(item.name).lineLimit(1).frame(maxWidth: 140)
                                    Button { model.removeAttachment(item) } label: {
                                        Image(systemName: "xmark").frame(width: 32, height: 44)
                                    }.disabled(model.sending).accessibilityLabel("Retirer \(item.name)")
                                }.font(.caption).padding(.leading, 12).background(AppTheme.background, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    }.padding(.horizontal, 4).accessibilityIdentifier("pending-attachments")
                }
                if model.importingAttachments { ProgressView("Ajout…").font(.caption).padding(8) }
                if let error = model.chatError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle").padding(.top, 12)
                        Text(error).font(.caption).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.chatError = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                            .accessibilityLabel("Fermer le message")
                    }.foregroundStyle(AppTheme.accent).padding(.leading, 8).accessibilityIdentifier("chat-error")
                }
                HStack(alignment: .bottom, spacing: 4) {
                    TextField("Message…", text: $model.draft, axis: .vertical)
                        .lineLimit(1...7).font(.body).focused($focused)
                        .padding(.horizontal, 9).padding(.vertical, 8).frame(minHeight: 44)
                        .accessibilityIdentifier("chat-composer")
                    sendButton
                }.padding(.bottom, 4)
                HStack(spacing: 2) {
                    messageActions
                    profileShortcut
                    Button { present(.history) } label: {
                        Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 18)).frame(width: 44, height: 44)
                            .overlay(alignment: .topTrailing) {
                                if model.hasUnread(profile: model.profile) {
                                    Circle().fill(AppTheme.accent).frame(width: 6, height: 6).padding(6)
                                        .accessibilityHidden(true).allowsHitTesting(false)
                                }
                            }
                            .contentShape(Rectangle())
                    }.accessibilityLabel("Conversations du profil actif").accessibilityIdentifier("quick-history")
                    Button { present(.spaces) } label: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 18)).frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }.accessibilityLabel("Outils").accessibilityIdentifier("app-navigation")
                    Button { present(.voice) } label: {
                        Image(systemName: "waveform").font(.system(size: 20)).frame(width: 44, height: 44)
                            .foregroundStyle(AppTheme.accent)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Conversation vocale").accessibilityIdentifier("voice-mode")
                        .disabled(model.sending || model.opening || model.transcript.running || (!model.demo && model.state != .connected))
                }.foregroundStyle(.secondary).buttonStyle(.plain)
            }.padding(10)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 28))
                .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(AppTheme.line))
                .shadow(color: .black.opacity(0.045), radius: 22, y: 6)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("composer-surface")
        }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 8).frame(maxWidth: 750).frame(maxWidth: .infinity)
            .background(AppTheme.background)
    }

    private var messageActions: some View {
        Menu {
            Button("Ajouter une photo", systemImage: "photo") { focused = false; attachmentContext = model.attachmentContext; showPhotos = true }
            Button("Ajouter un fichier", systemImage: "doc") { focused = false; attachmentContext = model.attachmentContext; showFiles = true }
        } label: {
            Image(systemName: "plus").font(.system(size: 20, weight: .regular))
                .foregroundStyle(.secondary).frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }.disabled(model.sending || model.importingAttachments || model.attachments.count >= 4).accessibilityLabel("Ajouter une pièce jointe").accessibilityIdentifier("message-actions")
    }

    private var profileShortcut: some View {
        Button { present(.profiles) } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    AgentAvatar(name: model.agent?.name ?? "default", size: 20)
                    Text(model.agent?.title ?? "Hermes").lineLimit(1).frame(maxWidth: 100)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }.padding(.horizontal, 9)
                HStack(spacing: 4) {
                    AgentAvatar(name: model.agent?.name ?? "default", size: 20)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }.padding(.horizontal, 6)
            }.frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                .background(AppTheme.background, in: Capsule())
                .contentShape(Rectangle())
        }.font(.caption.weight(.medium)).foregroundStyle(.primary)
            .accessibilityLabel("Changer de profil : \(model.agent?.title ?? "Hermes")")
            .accessibilityIdentifier("switch-profile")
    }

    private var sendButton: some View {
        Button {
            Task {
                if model.transcript.running { await model.interrupt() }
                else { pinnedToBottom = true; focused = false; await model.send() }
            }
        } label: {
            Image(systemName: model.transcript.running ? "stop.fill" : "arrow.up")
                .font(.system(size: model.transcript.running ? 13 : 19, weight: .semibold))
                .foregroundStyle(.white).frame(width: 44, height: 44)
                .background(model.canSend || model.transcript.running ? AppTheme.accent : Color.secondary.opacity(0.28), in: Circle())
                .contentShape(Rectangle())
        }.disabled(!model.canSend && !model.transcript.running)
            .accessibilityLabel(model.transcript.running ? "Arrêter la réponse" : "Envoyer")
            .accessibilityIdentifier("send-message")
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
        Task { if await model.answerCredential(text, request: payload) { value = "" }; busy = false }
    }
}

private struct BottomPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct MessageView: View, Equatable {
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
                Group {
                    if user { Text(verbatim: message.text).lineSpacing(4) }
                    else { MarkdownText(text: message.text) }
                }
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

struct ApprovalCard: View {
    @State private var persistent = false
    let payload: JSONValue
    let model: AppModel
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Hermes vous demande l’accord", systemImage: "hand.raised").font(.subheadline.weight(.semibold))
            Text(payload["command"].string).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            if !payload["description"].string.isEmpty { Text(payload["description"].string).font(.caption).foregroundStyle(.secondary) }
            if !payload["reason"].string.isEmpty { Text(payload["reason"].string).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Refuser") { answer("deny") }.buttonStyle(.bordered)
                Spacer()
                if payload["choices"].array.contains(.string("once")) {
                    Button("Autoriser une fois") { answer("once") }.buttonStyle(.borderedProminent)
                }
            }.font(.caption).disabled(busy)
            if payload["choices"].array.contains("session") || payload["choices"].array.contains("always") {
                Menu("Autres autorisations") {
                    if payload["choices"].array.contains("session") { Button("Pour cette session") { answer("session") } }
                    if payload["choices"].array.contains("always") { Button("Toujours pour cette règle") { persistent = true } }
                }.font(.caption).disabled(busy)
            }
        }.hermesCard()
            .confirmationDialog("Autoriser durablement cette règle pour cet agent ?", isPresented: $persistent, titleVisibility: .visible) {
                Button("Toujours autoriser cette règle") { answer("always") }
            }
    }
    private func answer(_ choice: String) { busy = true; Task { await model.answerApproval(choice, request: payload); busy = false } }
}

struct ClarificationCard: View {
    let payload: JSONValue
    let model: AppModel
    @State private var answers: [String: String] = [:]
    @State private var selections: [String: Set<String>] = [:]
    @State private var busy = false
    @State private var answered = Set<String>()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("À vous de choisir", systemImage: "bubble.left.and.text.bubble.right").font(.subheadline.weight(.semibold))
            if payload["questions"].array.isEmpty {
                question(payload, qid: nil)
            } else {
                ForEach(Array(payload["questions"].array.enumerated()), id: \.offset) { _, q in
                    if !answered.contains(q["qid"].string) && payload["answers"][q["qid"].string].isNull { question(q, qid: q["qid"].string) }
                }
            }
        }.hermesCard()
    }
    @ViewBuilder private func question(_ q: JSONValue, qid: String?) -> some View {
        Text(q["question"].string).font(.subheadline)
        let key = qid ?? "single"
        ForEach(Array(q["choices"].array.enumerated()), id: \.offset) { _, choice in
            Button {
                if q["multi_select"].bool {
                    if selections[key, default: []].contains(choice.string) { selections[key]?.remove(choice.string) }
                    else { selections[key, default: []].insert(choice.string) }
                } else { respond(choice.string, qid: qid) }
            } label: {
                HStack { Text(choice.string); if selections[key, default: []].contains(choice.string) { Image(systemName: "checkmark") } }
            }.buttonStyle(.bordered).disabled(busy)
        }
        HStack {
            TextField("Votre réponse…", text: Binding(get: { answers[key] ?? "" }, set: { answers[key] = $0 })).textFieldStyle(.roundedBorder)
            Button {
                let selected = q["choices"].array.map(\.string).filter { selections[key, default: []].contains($0) }
                respond((selected + [answers[key] ?? ""]).filter { !$0.isEmpty }.joined(separator: ", "), qid: qid)
            } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .accessibilityLabel("Répondre")
                .disabled(((answers[key] ?? "").isEmpty && selections[key, default: []].isEmpty) || busy)
        }
    }
    private func respond(_ text: String, qid: String?) {
        busy = true
        Task {
            if await model.answerClarification(text, request: payload, qid: qid) {
                if let qid { answered.insert(qid) }
                answers[qid ?? "single"] = ""; selections[qid ?? "single"] = []
            }
            busy = false
        }
    }
}
