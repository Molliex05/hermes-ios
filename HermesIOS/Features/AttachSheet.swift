import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What the person chose in the « + » panel, or pasted (a photo or a PDF from the clipboard).
enum AttachChoice { case camera, photos, files, paste([NSItemProvider]) }

/// What can be pasted as an attachment.
let pastableTypes: [UTType] = [.pdf, .image]

/// The composer's « + »: a small card that springs up just above the field, with three round choices. It lives in the
/// composer itself, so it rides on top of the keyboard instead of opening behind it.
struct AttachPanel: View {
    let attached: Int
    let limit: Int
    let choose: (AttachChoice) -> Void

    private var remaining: Int { max(0, limit - attached) }
    private let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)

    var body: some View {
        HStack(spacing: 6) {
            item("Appareil photo", symbol: "camera", enabled: cameraAvailable && remaining > 0, id: "attach-camera") { choose(.camera) }
            item("Photos", symbol: "photo.on.rectangle", enabled: remaining > 0, id: "attach-photos") { choose(.photos) }
            item("Fichiers", symbol: "doc", enabled: remaining > 0, id: "attach-files") { choose(.files) }
        }
        .padding(10)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(AppTheme.line))
        .shadow(color: .black.opacity(0.14), radius: 22, y: 8)
        .accessibilityElement(children: .contain).accessibilityIdentifier("attach-panel")
    }

    private func item(_ title: String, symbol: String, enabled: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.select(); action() }) {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 21, weight: .light)).foregroundStyle(AppTheme.accent)
                    .frame(width: 46, height: 46).background(AppTheme.accent.opacity(0.10), in: Circle())
                Text(title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }.frame(width: 92, height: 86).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
            .accessibilityIdentifier(id)
    }
}

/// The system camera, full screen. Returns the photo as JPEG data; the caller resizes it like any picked photo.
struct CameraPicker: UIViewControllerRepresentable {
    let onPicked: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.92) { parent.onPicked(data) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// Above the composer when the clipboard holds a photo or a PDF: one touch attaches it. Only the kind of content is
/// checked (that never shows iOS's paste banner); the content is read by the system paste button, when touched.
struct PasteChip: View {
    let enabled: Bool
    let choose: (AttachChoice) -> Void
    @State private var copied: UTType?
    @State private var pastedCount = -1

    var body: some View {
        Group {
            if let copied, enabled {
                HStack(spacing: 8) {
                    Image(systemName: copied == .pdf ? "doc.richtext" : "photo").foregroundStyle(AppTheme.accent)
                    Text(copied == .pdf ? "PDF copié" : "Image copiée").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    PasteButton(supportedContentTypes: pastableTypes) { providers in
                        Task { @MainActor in pastedCount = UIPasteboard.general.changeCount; self.copied = nil; choose(.paste(providers)) }
                    }
                    .labelStyle(.titleAndIcon).buttonBorderShape(.capsule).controlSize(.small).tint(AppTheme.accent)
                }
                .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 4)
                .background(AppTheme.surface, in: Capsule()).overlay(Capsule().strokeBorder(AppTheme.line))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .accessibilityIdentifier("paste-chip")
            }
        }
        .onAppear(perform: check)
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in check() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in check() }
    }

    private func check() {
        let board = UIPasteboard.general
        guard board.changeCount != pastedCount else { copied = nil; return }      // already attached
        copied = board.contains(pasteboardTypes: [UTType.pdf.identifier]) ? .pdf : board.hasImages ? .image : nil
    }
}
