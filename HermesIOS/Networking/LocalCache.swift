import Foundation

/// Small, device-protected display cache; no model keys or Hermes state live here.
actor LocalCache {
    private let folder: URL
    init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HermesIOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var resource = folder
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? resource.setResourceValues(values)
    }
    private func url(_ key: String) -> URL {
        // Every caller supplies a UUID or a fixed internal key, never a server path.
        folder.appendingPathComponent(key.filter { $0.isLetter || $0.isNumber || $0 == "-" } + ".json")
    }
    func read<T: Decodable & Sendable>(_ type: T.Type, key: String) -> T? {
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    func save<T: Encodable & Sendable>(_ value: T, key: String) throws {
        try JSONEncoder().encode(value).write(to: url(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func remove(_ key: String) throws {
        let path = url(key)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
}
