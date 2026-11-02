import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// What the chat presents over itself. Each is one sheet; anything deeper is pushed inside it.
enum ChatSheet: String, Identifiable {
    case menu, agents, history, voice
    var id: String { rawValue }
}

/// Owns presentation state only. It reads no transcript property, so streamed tokens never
/// re-evaluate it: the header, transcript and composer each observe what they display and hand
/// plain values to Equatable views (see Features/Chat).
struct ChatView: View {
    @Bindable var model: AppModel
    @State private var showPhotos = false
    @State private var compressing = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var attachOpen = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var attachmentContext = ""
    @State private var sheet: ChatSheet?
    @State private var pinnedToBottom = true
    @State private var bottomVisible = true
    @State private var toolsExpanded = false
    /// A web page opened from a reply, shown in the in-app browser.
    @State private var webPage: WebPage?
    @State private var eventPage: EventPage?
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ChatHeaderContainer(model: model, compress: { compressing = true }, newChat: { model.newChat(); focused = true },
                                    history: { present(.history) }, menu: { present(.menu) })
                ChatTranscriptView(model: model, pinnedToBottom: $pinnedToBottom, bottomVisible: $bottomVisible,
                                   toolsExpanded: $toolsExpanded, suggest: { model.draft = $0; focused = true })
            }
            // A full page over the chat (voice, menu, history, a web or event page): the chat's orbs rest meanwhile. Set
            // here, below the sheets, so the voice page's own orb keeps moving.
            .environment(\.orbsAsleep, (sheet != nil && sheet != .agents) || webPage != nil || eventPage != nil)
            .background { ChatBackdrop(model: model) }
            // Links in replies open their app when they are universal links (Gmail, GitHub, YouTube…), otherwise the in-app
            // browser; quick-reply cards answer as if typed.
            .environment(\.openURL, OpenURLAction { url in
                guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return .systemAction }
                Task { @MainActor in
                    if await UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { return }
                    if sheet == nil { webPage = WebPage(url: url) }
                }
                return .handled
            })
            .environment(\.chatReply, ChatReplyAction { text in reply(text) })
            .environment(\.draftOutbox, model.demo ? nil : DraftOutbox(
                load: { [profile = model.chatProfile] id in try await model.loadDraft(id, profile: profile) },
                send: { [profile = model.chatProfile] draft in try await model.sendDraft(draft, profile: profile) }))
            .environment(\.calendarEvent, CalendarEventAction { request in showEvent(request) })
            .sheet(item: $webPage) { page in SafariView(url: page.url).ignoresSafeArea() }
            .sheet(item: $eventPage) { page in EventPageView(event: page.event) { eventPage = nil }.ignoresSafeArea() }
            // Tapping the chat closes the « + » panel; the composer below stays live.
            .overlay {
                if attachOpen {
                    Color.black.opacity(0.10).ignoresSafeArea().onTapGesture { attachOpen = false }.transition(.opacity)
                }
            }
            // The composer's own spring (ChatComposer): the conversation makes room for the « + » panel at the panel's pace.
            .animation(.spring(response: 0.34, dampingFraction: 0.8), value: attachOpen)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ChatComposerContainer(
                    model: model, focused: $focused, attachOpen: $attachOpen, present: present,
                    attach: chooseAttachment,
                    willSend: { pinnedToBottom = true; focused = false; attachOpen = false })
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $sheet) { page in
                Group {
                    switch page {
                    case .menu: MenuView(model: model).presentationDetents([.large])
                    case .agents: QuickProfilePicker(model: model)
                    case .history: NavigationStack { SessionsView(model: model) }.presentationBackground(AppTheme.background).presentationDetents([.large])
                    case .voice: VoiceView(app: model, returnToChat: { sheet = nil }).presentationDetents([.large])
                    }
                }
                .environment(\.returnToChat, ReturnToChat { sheet = nil })
                .overlay(alignment: .top) { ToastBanner(model: model) }
                .overlay { NoticeDialog(model: model) }
                .sheetChrome()
            }
            .appConfirm("Résumer le contexte de cette conversation ?", isPresented: $compressing) {
                Button("Résumer avec Hermes") { Task { await model.compactConversation() } }
            } message: { Text("Hermes conserve l’historique et réduit le contexte utilisé pour les prochaines réponses.") }
            .sheet(isPresented: Binding(get: { model.commandOutput != nil }, set: { if !$0 { model.commandOutput = nil } })) {
                NavigationStack {
                    ScrollView { MarkdownText(text: model.commandOutput ?? "").textSelection(.enabled).padding(24).frame(maxWidth: .infinity, alignment: .leading) }
                        .background(AppTheme.background).navigationTitle("Réponse de Hermes").navigationBarTitleDisplayMode(.inline)
                        .toolbar { AppToolbarItem(placement: .confirmationAction) { AppCloseButton { model.commandOutput = nil } } }
                }.presentationBackground(AppTheme.background).presentationCornerRadius(30).presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { data in importImage(data, name: "Photo-\(UUID().uuidString.prefix(8)).jpg") }.ignoresSafeArea()
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
            // Another conversation starts at its end, title shown. A conversation that opens through the skeleton has no list
            // to report its position meanwhile, so the previous one's (read up, title folded) must not linger.
            .onChange(of: model.selected?.storedID) { _, _ in pinnedToBottom = true; bottomVisible = true; toolsExpanded = false }
            .onChange(of: model.navigationRevision) { _, _ in closePresentations() }
            .onChange(of: model.composerFocusRequest) { _, _ in if sheet == nil { focused = true } }
            .task(id: model.pendingVoiceLaunch) {
                guard model.pendingVoiceLaunch else { return }
                model.pendingVoiceLaunch = false
                if sheet != .voice { present(.voice) }
            }
            .onChange(of: sheet) { _, _ in updateVisibility() }
            .onChange(of: webPage) { _, _ in updateVisibility() }
            .onChange(of: eventPage?.id) { _, _ in updateVisibility() }
            .onChange(of: bottomVisible) { _, _ in updateVisibility() }
            .onAppear { updateVisibility() }
            .onDisappear { model.setChatVisible(false) }
        }
        // The current agent's illustration and motion, for the header, the empty chat, replies and the voice screen.
        .environment(\.agentLook, AgentLooks.shared.look(for: model.profile))
    }

    private func chooseAttachment(_ choice: AttachChoice) {
        attachOpen = false
        focused = false
        attachmentContext = model.attachmentContext
        // Let the panel fold away before the system surface opens.
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            switch choice {
            case .camera: showCamera = true
            case .photos: showPhotos = true
            case .files: showFiles = true
            case .paste(let providers): importPasted(providers)
            }
        }
    }

    /// Photos and PDFs from the clipboard: a photo goes through the usual resize, a PDF is kept as it is (the agent reads its
    /// text, extracted when it is sent, and can attach it to a draft).
    private func importPasted(_ providers: [NSItemProvider]) {
        let context = attachmentContext
        Task {
            model.importingAttachments = true
            defer { model.importingAttachments = false }
            do {
                for provider in providers.prefix(max(0, DraftAttachment.maximumCount - model.attachments.count)) {
                    let tag = UUID().uuidString.prefix(8)
                    if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                        let data = try await provider.data(for: .pdf)
                        let base = (provider.suggestedName ?? "").trimmingCharacters(in: .whitespaces)
                        let name = base.isEmpty ? "Document-\(tag).pdf" : base.lowercased().hasSuffix(".pdf") ? base : base + ".pdf"
                        try await model.addAttachment(data: data, name: name, mimeType: "application/pdf", context: context)
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                        let data = try await provider.data(for: .image)
                        let jpeg = try await Task.detached { try PhotoAttachment.jpeg(data) }.value
                        try await model.addAttachment(data: jpeg, name: "Image-\(tag).jpg", mimeType: "image/jpeg", context: context)
                    }
                }
            } catch is CancellationError { }
            catch { model.chatError = error.localizedDescription }
        }
    }

    /// A photo taken with the camera goes through the same resize-and-attach path as a picked one.
    private func importImage(_ data: Data, name: String) {
        let context = attachmentContext
        Task {
            model.importingAttachments = true
            defer { model.importingAttachments = false }
            do {
                let jpeg = try await Task.detached { try PhotoAttachment.jpeg(data) }.value
                try await model.addAttachment(data: jpeg, name: name, mimeType: "image/jpeg", context: context)
            } catch is CancellationError { }
            catch { model.chatError = error.localizedDescription }
        }
    }

    /// A quick reply from a card: sent at once as its own message when Hermès is free (the draft and its attachments stay
    /// as they are). Otherwise nothing is sent and the card stays open; an empty field gets the text, ready to send.
    private func reply(_ text: String) -> Bool {
        guard model.canSendQuickReply else {
            if model.draft.isEmpty { model.draft = text; focused = true }
            return false
        }
        pinnedToBottom = true
        Task { await model.sendQuickReply(text) }
        return true
    }

    /// The chat counts as seen (no banner, read marks) only when nothing covers it and its end is on screen.
    private func updateVisibility() { model.setChatVisible(sheet == nil && webPage == nil && eventPage == nil, atBottom: bottomVisible) }

    /// A card's event: its page from the phone's calendars, else Calendar on that day.
    private func showEvent(_ request: CalendarEventRequest) {
        Task {
            guard let event = await CalendarLink.find(request), sheet == nil, webPage == nil else { return CalendarLink.openDay(request.start) }
            eventPage = EventPage(event: event)
        }
    }

    /// A conversation opened from outside (a notification, a routine's result): everything over the chat closes as if the
    /// user had closed it. The chat used to be rebuilt instead, which redrew it from scratch under the closing sheet and
    /// could leave it counted as hidden (the old copy's `onDisappear` running after the new one's `onAppear`).
    private func closePresentations() {
        sheet = nil; webPage = nil; eventPage = nil; compressing = false
        showCamera = false; showPhotos = false; showFiles = false; attachOpen = false
        model.commandOutput = nil
    }

    /// One presentation at a time: the in-app browser closes first, then the sheet opens once it is gone.
    private func present(_ page: ChatSheet) {
        focused = false
        guard webPage != nil || eventPage != nil else { sheet = page; return }
        webPage = nil; eventPage = nil
        Task { try? await Task.sleep(for: .milliseconds(450)); sheet = page }
    }
}
