import Foundation

/// Phone-side endpoint detection using the native profile's RMS and silence settings.
struct VoiceActivity {
    let threshold: Double
    let silenceDuration: Double
    var voicedDuration = 0.0
    var silence = 0.0
    var elapsed = 0.0
    var hasSpeech: Bool { voicedDuration >= 0.25 }
    mutating func sample(decibels: Double, interval: Double) -> Bool {
        elapsed += interval
        if pow(10, decibels / 20) * 32767 > threshold {
            voicedDuration += interval; silence = 0
        } else { silence += interval }
        return hasSpeech && silence >= silenceDuration
    }
    static func isStop(_ text: String, phrases: [String]) -> Bool {
        func normalize(_ value: String) -> String {
            value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let utterance = normalize(text)
        return !utterance.isEmpty && phrases.contains { normalize($0) == utterance }
    }
}
