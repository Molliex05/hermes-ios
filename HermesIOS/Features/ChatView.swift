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
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ChatHeaderContainer(model: model, compress: { compressing = true }, newChat: { model.newChat(); focused = true },
                                    switchAgent: { present(.agents) }, history: { present(.history) }, menu: { present(.menu) })
                ChatTranscriptView(model: model, pinnedToBottom: $pinnedToBottom, bottomVisible: $bottomVisible,
                                   toolsExpanded: $toolsExpanded, suggest: { model.draft = $0; focused = true })
            }
            .background { ChatBackdrop(model: model) }
            // Tapping the chat closes the « + » panel; the composer below stays live.
            .overlay {
                if attachOpen {
                    Color.black.opacity(0.10).ignoresSafeArea().onTapGesture { attachOpen = false }.transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: attachOpen)
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
            .onChange(of: model.selected?.storedID) { _, _ in pinnedToBottom = true; toolsExpanded = false }
            .onChange(of: model.composerFocusRequest) { _, _ in if sheet == nil { focused = true } }
            .task(id: model.pendingVoiceLaunch) {
                guard model.pendingVoiceLaunch else { return }
                model.pendingVoiceLaunch = false
                if sheet != .voice { present(.voice) }
            }
            .onChange(of: sheet) { _, value in model.setChatVisible(value == nil && bottomVisible) }
            .onChange(of: bottomVisible) { _, visible in model.setChatVisible(sheet == nil && visible) }
            .onAppear { model.setChatVisible(sheet == nil && bottomVisible) }
            .onDisappear { model.setChatVisible(false) }
        }
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
            }
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

    private func present(_ page: ChatSheet) {
        focused = false
        sheet = page
    }
}
