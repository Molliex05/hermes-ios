import Foundation

/// What kind of file an attachment is, from its name (and type when known): its symbol and its short label.
public enum AttachmentKind: Equatable, Sendable {
    case pdf, image, sheet, document, slides, archive, audio, video, other

    public static func of(name: String, mimeType: String = "") -> AttachmentKind {
        let ext = (name as NSString).pathExtension.lowercased(), mime = mimeType.lowercased()
        if ext == "pdf" || mime.contains("pdf") { return .pdf }
        if mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff"].contains(ext) { return .image }
        if ["xls", "xlsx", "csv", "numbers", "tsv"].contains(ext) || mime.contains("sheet") { return .sheet }
        if ["ppt", "pptx", "key"].contains(ext) || mime.contains("presentation") { return .slides }
        if ["doc", "docx", "pages", "txt", "rtf", "md"].contains(ext) || mime.contains("word") || mime.hasPrefix("text/") { return .document }
        if ["zip", "gz", "tar", "rar", "7z"].contains(ext) || mime.contains("zip") { return .archive }
        if mime.hasPrefix("audio/") || ["m4a", "mp3", "wav", "aac", "caf"].contains(ext) { return .audio }
        if mime.hasPrefix("video/") || ["mov", "mp4", "m4v"].contains(ext) { return .video }
        return .other
    }

    public var symbol: String {
        switch self {
        case .pdf: "doc.richtext.fill"
        case .image: "photo.fill"
        case .sheet: "tablecells.fill"
        case .document: "doc.text.fill"
        case .slides: "rectangle.on.rectangle.angled.fill"
        case .archive: "doc.zipper"
        case .audio: "waveform"
        case .video: "film.fill"
        case .other: "doc.fill"
        }
    }

    /// « PDF », « Image », « XLSX »…
    public func label(for name: String) -> String {
        switch self {
        case .pdf: return "PDF"
        case .image: return "Image"
        default:
            let ext = (name as NSString).pathExtension.uppercased()
            return ext.isEmpty || ext.count > 5 ? "Fichier" : ext
        }
    }
}

/// The files of a message you sent, written by the app (« 📎 facture.pdf ») or kept by Hermes in its history
/// (`@file:attachments/facture.pdf`): drawn as chips above the bubble instead of raw lines. The companions the app sends
/// with a PDF (its extracted text, the pages of a scan) are left out: they are the PDF.
public enum SentAttachments {
    public static func split(_ text: String) -> (text: String, files: [String]) {
        var files: [String] = [], kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("📎 ") {
                files.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if trimmed.hasPrefix("@file:"), let name = referenceName(String(trimmed.dropFirst(6))) {
                files.append(name)
            } else {
                kept.append(line)
            }
        }
        let names = files.filter { !$0.isEmpty && !isCompanion($0) }
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        return (kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), unique)
    }

    /// `attachments/facture.pdf`, `"attachments/Mon fichier.pdf"` or a backquoted path: the file's own name.
    private static func referenceName(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'`"))
        guard !value.isEmpty, !value.contains(" ") || raw.first.map({ "\"'`".contains($0) }) == true else { return nil }
        let name = (value.removingPercentEncoding ?? value).split(separator: "/").last.map(String.init) ?? value
        return name.isEmpty ? nil : name
    }

    private static func isCompanion(_ name: String) -> Bool {
        name.hasSuffix(" (texte).txt") || name.firstMatch(of: #/ - page \d+\.jpg$/#) != nil
    }
}
