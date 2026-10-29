import LinkPresentation
import SafariServices
import SwiftUI

/// Lets a card answer in the conversation (a quick reply), as if typed. Set by the chat. Returns whether the reply was
/// sent; a card marks its choice only then.
struct ChatReplyAction {
    let send: @MainActor (String) -> Bool
}

extension EnvironmentValues {
    @Entry var chatReply: ChatReplyAction? = nil
    /// Only the newest reply's cards still answer: an old « Oui » must not land in today's conversation.
    @Entry var cardsInteractive = true
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

/// Page title, preview picture and site icon, fetched once per address with Apple's LinkPresentation. Pictures are
/// shrunk to what a card shows and kept in a bounded cache (emptied under memory pressure); failures are remembered
/// for a while so a dead link is not fetched again each time its row comes back; at most three pages load at once.
@MainActor final class LinkPreviewStore {
    /// Immutable once built, so it can cross from the fetching task to the views.
    final class Preview: @unchecked Sendable {
        let title: String, image: UIImage?, icon: UIImage?
        init(title: String, image: UIImage?, icon: UIImage?) { self.title = title; self.image = image; self.icon = icon }
    }
    static let shared = LinkPreviewStore()
    private let cache: NSCache<NSURL, Preview> = {
        let cache = NSCache<NSURL, Preview>()
        cache.totalCostLimit = 24 * 1_024 * 1_024
        return cache
    }()
    private var failures: [URL: Date] = [:]
    private var pending: [URL: Task<Preview?, Never>] = [:]
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// What is already known, without waiting (a row that comes back shows its preview at once).
    func cached(_ url: URL) -> Preview? { cache.object(forKey: url as NSURL) }

    func preview(for url: URL) async -> Preview? {
        if let cached = cached(url) { return cached }
        if let failed = failures[url], Date.now.timeIntervalSince(failed) < 600 { return nil }
        if let inFlight = pending[url] { return await inFlight.value }
        let task = Task { @MainActor () -> Preview? in
            await self.acquire()
            defer { self.release() }
            let provider = LPMetadataProvider()
            provider.timeout = 8
            guard let metadata = try? await provider.startFetchingMetadata(for: url) else { return nil }
            let image = await Self.image(metadata.imageProvider, side: 600)
            let icon = await Self.image(metadata.iconProvider, side: 96)
            return Preview(title: metadata.title ?? "", image: image, icon: icon)
        }
        pending[url] = task
        let result = await task.value
        pending[url] = nil
        if let result {
            var cost = 0
            for picture in [result.image, result.icon].compactMap({ $0 }) {
                let pixels = picture.size.width * picture.size.height * picture.scale * picture.scale
                cost += Int(pixels) * 4
            }
            cache.setObject(result, forKey: url as NSURL, cost: cost)
        } else {
            failures[url] = .now
        }
        return result
    }

    private func acquire() async {
        if running < 3 { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }

    private static func image(_ provider: NSItemProvider?, side: CGFloat) async -> UIImage? {   // main actor, like the store
        guard let provider, provider.canLoadObject(ofClass: UIImage.self) else { return nil }
        let loaded: UIImage? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in continuation.resume(returning: object as? UIImage) }
        }
        guard let loaded, max(loaded.size.width, loaded.size.height) > side else { return loaded }
        return await loaded.byPreparingThumbnail(ofSize: CGSize(width: side, height: side * loaded.size.height / max(loaded.size.width, 1))) ?? loaded
    }
}

/// A compact preview of a web page: picture, title and site. Opens in the in-app browser.
struct LinkPreviewRow: View {
    let url: URL
    var fallbackTitle = ""
    @State private var preview: LinkPreviewStore.Preview?
    @Environment(\.openURL) private var openURL

    init(url: URL, fallbackTitle: String = "") {
        self.url = url
        self.fallbackTitle = fallbackTitle
        _preview = State(initialValue: LinkPreviewStore.shared.cached(url))
    }

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
        .task(id: url) { if preview == nil { preview = await LinkPreviewStore.shared.preview(for: url) } }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Ouvre la page")
        .accessibilityIdentifier("link-preview")
    }

    private var host: String { (url.host ?? url.absoluteString).replacingOccurrences(of: "www.", with: "") }
    private var title: String {
        if let title = preview?.title, !title.isEmpty { return title }
        return fallbackTitle.isEmpty ? host : fallbackTitle
    }
}
