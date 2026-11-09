import QuickLook
import QuickLookThumbnailing
import SwiftUI

/// The files waiting in the composer: a photo as its picture, a document as a small card with its first page, its type and
/// its size. Touch one to look at it (Quick Look); the corner button takes it off. A file being added shows as a
/// placeholder in the row.
struct AttachmentTray: View {
    let items: [DraftAttachment]
    let importing: Bool
    let locked: Bool
    let fileURL: (DraftAttachment) async -> URL?
    let remove: (DraftAttachment) -> Void
    @State private var preview: URL?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    AttachmentTile(item: item, locked: locked, fileURL: fileURL, remove: { remove(item) }) {
                        Task { if let url = await fileURL(item) { preview = url } }
                    }
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
                if importing {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.background)
                        .frame(width: 64, height: 64).overlay(ProgressView())
                        .accessibilityLabel("Ajout d’un fichier")
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 2)
            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: items.map(\.id))
            .animation(.easeOut(duration: 0.2), value: importing)
        }
        .quickLookPreview($preview)
        .accessibilityIdentifier("pending-attachments")
    }
}

private struct AttachmentTile: View {
    let item: DraftAttachment
    let locked: Bool
    let fileURL: (DraftAttachment) async -> URL?
    let remove: () -> Void
    let open: () -> Void
    @State private var thumbnail: UIImage?
    private var kind: AttachmentKind { AttachmentKind.of(name: item.name, mimeType: item.mimeType) }
    private var photo: Bool { kind == .image }

    var body: some View {
        Button { Haptics.select(); open() } label: { photo ? AnyView(picture) : AnyView(card) }
            .buttonStyle(PressableStyle())
            .overlay(alignment: .topTrailing) {
                if !locked {
                    Button { Haptics.select(); withAnimation { remove() } } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 20, height: 20).background(.black.opacity(0.62), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                            .frame(width: 36, height: 36).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).offset(x: 10, y: -10)
                    .accessibilityLabel("Retirer \(item.name)")
                }
            }
            .contextMenu {
                Button { open() } label: { Label("Aperçu", systemImage: "eye") }
                if !locked { Button(role: .destructive) { remove() } label: { Label("Retirer", systemImage: "trash") } }
            }
            .task(id: item.id) { await loadThumbnail() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(kind.label(for: item.name)), \(item.name), \(size)")
            .accessibilityHint("Touchez pour l’aperçu")
    }

    private var picture: some View {
        ZStack {
            AppTheme.background
            if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() } else { Image(systemName: kind.symbol).foregroundStyle(.secondary) }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppTheme.line))
    }

    private var card: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(AppTheme.surface)
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: kind.symbol).font(.system(size: 18)).foregroundStyle(tint)
                }
            }
            .frame(width: 38, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(AppTheme.line))
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.caption.weight(.semibold)).foregroundStyle(.primary).lineLimit(2).truncationMode(.middle)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Text(kind.label(for: item.name)).font(.caption2.weight(.bold)).foregroundStyle(tint)
                    Text("· \(size)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 104, alignment: .leading)
        }
        .padding(.leading, 8).padding(.trailing, 10)
        .frame(height: 64)
        .background(AppTheme.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppTheme.line))
    }

    private var tint: Color {
        switch kind {
        case .pdf: Color(red: 0.84, green: 0.25, blue: 0.2)
        case .sheet: Color(red: 0.2, green: 0.55, blue: 0.33)
        case .slides: Color(red: 0.9, green: 0.5, blue: 0.15)
        case .document: Color(red: 0.24, green: 0.42, blue: 0.75)
        default: AppTheme.accent
        }
    }

    private var size: String { ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file) }

    private func loadThumbnail() async {
        guard thumbnail == nil, let url = await fileURL(item) else { return }
        let side: CGFloat = photo ? 64 : 48
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: UIScreen.main.scale, representationTypes: .thumbnail)
        if let made = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail = made.uiImage }
    }
}

/// The files of a message you sent, above its bubble: their type and name.
struct SentAttachmentChips: View {
    let files: [String]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(files, id: \.self) { name in
                let kind = AttachmentKind.of(name: name)
                HStack(spacing: 7) {
                    Image(systemName: kind.symbol).font(.system(size: 13)).foregroundStyle(AppTheme.accent)
                        .frame(width: 26, height: 26).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(name).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        Text(kind.label(for: name)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
                .frame(maxWidth: 240, alignment: .leading)
                .background(AppTheme.userBubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppTheme.userBubbleLine))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Pièce jointe : \(name)")
            }
        }
    }
}
