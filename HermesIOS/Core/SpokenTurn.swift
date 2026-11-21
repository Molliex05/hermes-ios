import Foundation

/// What a spoken turn tells the agent besides the words. « 🎙️ » marks a spoken turn (the agents' SOUL answers it for the
/// ear). At the wheel, « 🚗 » follows it, with the town when the iPhone knows it: the SOUL then keeps the answer even
/// shorter and uses the place for weather, shops and travel times. The mark stays first so the voice rules still apply.
public enum SpokenTurn {
    public static let voiceMark = "🎙️"
    public static let drivingMark = "🚗"

    public static func text(_ words: String, driving: Bool = false, near place: String? = nil) -> String {
        guard driving else { return "\(voiceMark) \(words)" }
        let town = (place ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        let near = town.isEmpty ? "" : "(près de \(String(town.prefix(60)))) "
        return "\(voiceMark)\(drivingMark) \(near)\(words)"
    }
}
