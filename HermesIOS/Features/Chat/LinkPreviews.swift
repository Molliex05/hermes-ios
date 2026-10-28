import LinkPresentation
import SafariServices
import SwiftUI

/// Lets a card answer in the conversation (a quick reply), as if typed. Set by the chat.
struct ChatReplyAction {
    let send: @MainActor (String) -> Void
}

extension EnvironmentValues {
    @Entry var chatReply: ChatReplyAction? = nil
}

/// A web page shown in the in-app browser, so reading a link never leaves the conversation.
struct WebPage: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(AppTheme.accent)
        controller.dismissButtonStyle = .close
        return controller
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Page title, preview picture and site icon, fetched once per address with Apple's LinkPresentation and kept in memory.
@MainActor final class LinkPreviewStore {
    struct Preview { let title: String; let image: UIImage?; let icon: UIImage? }
    static let shared = LinkPreviewStore()
    private var cache: [URL: Preview] = [:]
    private var pending: [URL: Task<Preview?, Never>] = [:]

    func preview(for url: URL) async -> Preview? {
        if let cached = cache[url] { return cached }
        if let running = pending[url] { return await running.value }
        let task = Task { @MainActor () -> Preview? in
            let provider = LPMetadataProvider()
            provider.timeout = 8
            guard let metadata = try? await provider.startFetchingMetadata(for: url) else { return nil }
            let title = metadata.title ?? ""
            let image = await Self.image(metadata.imageProvider)
            let icon = await Self.image(metadata.iconProvider)
            return Preview(title: title, image: image, icon: icon)
        }
        pending[url] = task
        let result = await task.value
        pending[url] = nil
        if let result { cache[url] = result }
        return result
    }

    private static func image(_ provider: NSItemProvider?) async -> UIImage? {   // main actor, like the store
        guard let provider, provider.canLoadObject(ofClass: UIImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in continuation.resume(returning: object as? UIImage) }
        }
    }
}

/// A compact preview of a web page: picture, title and site. Opens in the in-app browser.
struct LinkPreviewRow: View {
    let url: URL
    var fallbackTitle = ""
    @State private var preview: LinkPreviewStore.Preview?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { Haptics.select(); openURL(url) } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.accent.opacity(0.10))
                    if let image = preview?.image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else if let icon = preview?.icon {
                        Image(uiImage: icon).resizable().scaledToFit().padding(12)
                    } else {
                        Image(systemName: "globe").foregroundStyle(AppTheme.accent)
                    }
                }
                .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        if let icon = preview?.icon, preview?.image != nil { Image(uiImage: icon).resizable().frame(width: 14, height: 14).clipShape(RoundedRectangle(cornerRadius: 3)) }
                        Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(AppTheme.line))
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            Button { UIPasteboard.general.url = url } label: { Label("Copier le lien", systemImage: "link") }
            ShareLink(item: url) { Label("Partager", systemImage: "square.and.arrow.up") }
        }
        .task(id: url) { if preview == nil { preview = await LinkPreviewStore.shared.preview(for: url) } }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("link-preview")
    }

    private var host: String { (url.host ?? url.absoluteString).replacingOccurrences(of: "www.", with: "") }
    private var title: String {
        if let title = preview?.title, !title.isEmpty { return title }
        return fallbackTitle.isEmpty ? host : fallbackTitle
    }
}
