import SwiftUI
import UIKit

/// What the person chose in the « + » panel.
enum AttachChoice { case camera, photos, files }

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
