import Foundation

/// What the transcription of a sound is worth. A car's rumble, a bump or a blinker can pass the level checks; its
/// transcription then comes back as a stock word the recogniser invents from noise (« Yep », « Merci d'avoir regardé »).
/// Such a text is no message, and it never cuts the agent off.
public enum VoiceHeard {
    /// Whole transcriptions that recognisers produce from noise or silence. English fillers are never a French request.
    static let inventions: Set<String> = [
        "yep", "yup", "yeah", "yes", "you", "so", "bye", "bye bye", "thank you", "thank you very much", "thanks",
        "thanks for watching", "thank you for watching", "oh", "uh", "um", "hmm", "hm", "mm", "mhm", "mm hmm", "ah", "euh",
        "heu", "hum", "merci d avoir regarde", "merci d avoir regarde cette video", "sous titrage st 501",
    ]
    /// Pieces of subtitle credits, a classic invention on a noisy recording.
    static let creditPieces = ["amara org", "sous titrage", "sous titres realises"]
    /// One word that is enough to cut the agent off: the ways of saying « wait » or answering it.
    static let interruptions: Set<String> = [
        "stop", "arrete", "arretes", "attends", "attend", "pause", "non", "oui", "ok", "okay", "jarvis", "hermes", "silence", "chut",
    ]

    /// Lower case, no accents or punctuation, single spaces: « Yep. » and « yep » are the same invention.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_CA"))
        let words = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(words).split(separator: " ").joined(separator: " ")
    }

    /// Nothing a person meant to say: empty, an invention, subtitle credits, or a lone letter.
    public static func isNoise(_ text: String) -> Bool {
        let plain = normalized(text)
        if plain.isEmpty || inventions.contains(plain) { return true }
        if creditPieces.contains(where: plain.contains) { return true }
        return plain.count < 2
    }

    /// Enough to stop the agent mid-reply: real words, two or more, or one of the words that ask it to wait.
    public static func confirmsInterruption(_ text: String) -> Bool {
        guard !isNoise(text) else { return false }
        let words = normalized(text).split(separator: " ")
        return words.count >= 2 || words.first.map { interruptions.contains(String($0)) } == true
    }
}
