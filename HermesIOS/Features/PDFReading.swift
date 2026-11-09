import PDFKit
import UIKit

/// What goes along with a PDF so the agent can read it (Hermes only sees a binary file): its text, extracted on the iPhone,
/// as a small text file; for a scan with no text, its first pages as images, which the agent reads like photos.
enum PDFReading {
    struct Companion: Sendable {
        let name: String, mimeType: String
        let data: Data
        var isImage: Bool { mimeType.hasPrefix("image/") }
    }
    static let textLimit = 80_000, scannedPages = 3

    static func companions(of data: Data, name: String) -> [Companion] {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { return [] }
        let stem = (name as NSString).deletingPathExtension
        let text = (document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 40 {
            let cut = text.count > textLimit ? String(text.prefix(textLimit)) + "\n\n[… texte coupé]" : text
            let pages = document.pageCount == 1 ? "1 page" : "\(document.pageCount) pages"
            let header = "Texte extrait sur l’iPhone du PDF « \(name) » (\(pages)). Le PDF lui-même est joint à part : c’est lui qu’on joint à un courriel.\n\n"
            return [Companion(name: "\(stem) (texte).txt", mimeType: "text/plain", data: Data((header + cut).utf8))]
        }
        return (0..<min(scannedPages, document.pageCount)).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            let image = page.thumbnail(of: CGSize(width: 1600, height: 1600), for: .mediaBox)
            guard let jpeg = image.jpegData(compressionQuality: 0.8) else { return nil }
            return Companion(name: "\(stem) - page \(index + 1).jpg", mimeType: "image/jpeg", data: jpeg)
        }
    }
}
