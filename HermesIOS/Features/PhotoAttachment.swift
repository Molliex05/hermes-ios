import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downsample before decoding so a large HEIC doesn't become a full-resolution bitmap in memory.
enum PhotoAttachment {
    static func jpeg(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3072
              ] as CFDictionary) else { throw RPCFailure("Cette photo n’a pas pu être ouverte.") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw RPCFailure("Impossible de préparer la photo.") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RPCFailure("Impossible de préparer la photo.") }
        return output as Data
    }
}

extension NSItemProvider {
    /// The pasted or shared content of this type, as data.
    @MainActor func data(for type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadDataRepresentation(for: type) { data, error in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? RPCFailure("Ce contenu n’a pas pu être collé.")) }
            }
        }
    }
}
