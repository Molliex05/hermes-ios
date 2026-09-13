import Foundation

struct DraftAttachment: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var mimeType: String
    var size: Int
    var remotePath: String?
    var remoteReference: String?
    var runtimeID: String?
    var isImage: Bool { mimeType.hasPrefix("image/") && ["png", "jpg", "jpeg", "webp", "gif"].contains((name as NSString).pathExtension.lowercased()) }
    static let maximumBytes = 10 * 1024 * 1024
    static let maximumCount = 4
}
