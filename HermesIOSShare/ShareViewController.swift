import SwiftUI
import UIKit
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

/// « Partager » → Hermès: a link or a text from Safari, Mail, Notes… goes to an agent. The extension only leaves the item
/// in the shared keychain; the app sends it the next time it opens (a notification invites you to open it), so no
/// connection, token or conversation is ever handled in here.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(context: extensionContext)
        let host = UIHostingController(rootView: ShareSheetView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load() }
    }
}

@MainActor @Observable
final class ShareModel {
    enum Phase { case loading, ready, sent, nothingToShare }
    var phase = Phase.loading
    var title = ""
    var text = ""
    var url: URL?
    var note = ""
    var profile = ""
    let profiles = SharedProfiles.read()
    private let context: NSExtensionContext?

    init(context: NSExtensionContext?) {
        self.context = context
        profile = profiles.first?.name ?? ""
    }

    var preview: String { [title, url?.absoluteString ?? "", text].filter { !$0.isEmpty }.joined(separator: "\n") }
    var canSend: Bool { !profile.isEmpty && !preview.isEmpty }

    func load() async {
        let items = context?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        title = items.compactMap { $0.attributedTitle?.string ?? $0.attributedContentText?.string }.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let providers = items.flatMap { $0.attachments ?? [] }
        for provider in providers {
            if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), let found = await Self.load(provider, as: UTType.url, URL.self) { url = found }
            if text.isEmpty, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), let found = await Self.load(provider, as: UTType.plainText, String.self) {
                text = found.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // A page shared from Safari repeats its address as text: keep one of the two.
        if let url, text == url.absoluteString { text = "" }
        if title == url?.absoluteString || title == text { title = "" }
        text = String(text.prefix(4_000)); title = String(title.prefix(200))
        phase = preview.isEmpty ? .nothingToShare : .ready
    }

    private static func load<Value: Sendable>(_ provider: NSItemProvider, as type: UTType, _ kind: Value.Type) async -> Value? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                continuation.resume(returning: item as? Value)
            }
        }
    }

    func send() {
        guard canSend else { return }
        let words = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = SharedItem(profile: profile, text: preview, note: words.isEmpty ? "Je te partage ceci :" : words)
        guard ShareInbox.add(item) else { return }
        phase = .sent
        invite(to: profiles.first { $0.name == profile }?.title ?? profile)
        Task { try? await Task.sleep(for: .seconds(1.2)); finish() }
    }

    /// Opening the app from here is not allowed, so a notification does the inviting: one touch and the app sends it.
    private func invite(to agent: String) {
        let content = UNMutableNotificationContent()
        content.title = "Prêt à envoyer à \(agent)"
        content.body = "Touchez pour ouvrir Hermès : le partage part tout de suite."
        content.sound = nil
        let request = UNNotificationRequest(identifier: "share-\(UUID().uuidString)", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }

    func cancel() { context?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
    func finish() { context?.completeRequest(returningItems: nil) }
}

struct ShareSheetView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .loading: ProgressView()
                case .nothingToShare: message("Rien à envoyer", "Hermès partage les liens et les textes.")
                case .sent: message("Ajouté", "Ouvrez Hermès : le partage part tout de suite.", symbol: "checkmark.circle.fill")
                case .ready: form
                }
            }
            .navigationTitle("Envoyer à un agent").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { model.cancel() }.disabled(model.phase == .sent) }
                ToolbarItem(placement: .confirmationAction) { Button("Envoyer") { model.send() }.fontWeight(.semibold).disabled(!model.canSend || model.phase != .ready) }
            }
        }
    }

    private var form: some View {
        Form {
            Section("Partagé") {
                Text(model.preview).font(.footnote).lineLimit(6).foregroundStyle(.secondary)
            }
            Section {
                if model.profiles.isEmpty {
                    Text("Ouvrez Hermès une fois pour que vos agents apparaissent ici.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Picker("Agent", selection: $model.profile) {
                        ForEach(model.profiles) { Text($0.title.isEmpty ? $0.name : $0.title).tag($0.name) }
                    }
                }
                TextField("Que doit-il en faire ? (facultatif)", text: $model.note, axis: .vertical).lineLimit(1...4)
            }
        }
    }

    private func message(_ title: String, _ detail: String, symbol: String = "tray") -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tint)
            Text(title).font(.headline)
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(24)
    }
}
