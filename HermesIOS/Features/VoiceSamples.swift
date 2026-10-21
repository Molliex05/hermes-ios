import Foundation

/// Optional, off by default: keeps each spoken utterance (16 kHz WAV) with the text the app got for it, in
/// `Documents/voice-samples`, so transcription providers can be compared on the owner's real voice. The audio
/// never leaves the phone unless it is copied out by hand. Switched on/off by a launch argument.
enum VoiceSamples {
    private static let key = "voice.saveSamples"

    static func applyLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--voice-save-samples") { UserDefaults.standard.set(true, forKey: key) }
        if arguments.contains("--voice-save-samples-off") { UserDefaults.standard.set(false, forKey: key) }
    }

    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    private static var directory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("voice-samples", isDirectory: true)
    }

    /// Saves the recording and returns its id (nil when disabled or on failure).
    static func save(_ wav: Data) -> String? {
        guard enabled, let directory else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let id = "\(stamp)-\(UUID().uuidString.prefix(4))"
        do { try wav.write(to: directory.appendingPathComponent("\(id).wav")); return id } catch { return nil }
    }

    static func annotate(_ id: String?, text: String, provider: String) {
        guard let id, let directory else { return }
        let body = ["text": text, "stt": provider]
        if let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("\(id).json"))
        }
    }
}
