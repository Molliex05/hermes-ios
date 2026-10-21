import Foundation

/// Short « I'm on it » phrases, recorded once in the agent's own voice (24 kHz mono 16-bit PCM in the app bundle).
/// Played from the phone the moment the agent has been silent for a beat, so there is no speech-synthesis round trip.
@MainActor
enum VoiceFiller {
    nonisolated static let phrases = ["Je regarde ça.", "Un instant.", "Je vérifie ça."]
    private static let files = ["regarde", "instant", "verifie"]
    private static var last = -1
    nonisolated static let sampleRate = 24000.0

    /// A different phrase each time, never the one just used.
    static func next() -> Data? {
        var index = Int.random(in: 0..<files.count)
        if index == last { index = (index + 1) % files.count }
        last = index
        guard let url = Bundle.main.url(forResource: files[index], withExtension: "pcm") else { return nil }
        return try? Data(contentsOf: url)
    }
}
