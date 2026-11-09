import Foundation

struct DraftAttachment: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var mimeType: String
    var size: Int
    var remotePath: String?
    var remoteReference: String?
    var runtimeID: String?
    /// What was sent along with a PDF so the agent can read it: its text as a file reference, or its first pages as images
    /// when it is a scan. Uploaded with it, for the same runtime.
    var extraReferences: [String]?
    var extraImagePaths: [String]?
    var isPDF: Bool { mimeType == "application/pdf" || (name as NSString).pathExtension.lowercased() == "pdf" }
    var isImage: Bool { mimeType.hasPrefix("image/") && ["png", "jpg", "jpeg", "webp", "gif"].contains((name as NSString).pathExtension.lowercased()) }
    static let maximumBytes = 10 * 1024 * 1024
    static let maximumCount = 4
}
