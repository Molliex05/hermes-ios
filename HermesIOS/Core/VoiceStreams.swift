import Foundation

/// One microphone meter frame, measured on the audio thread. `duration` is the buffer's
/// own length (frames / sample rate): detectors never assume a polling interval.
struct VoiceLevel: Sendable, Equatable {
    let time: Double
    let duration: Double
    /// Signed 16-bit RMS scale (0...32767), the unit of Hermes' `silence_threshold`.
    let rms: Double

    init(time: Double, duration: Double, rms: Double) {
        self.time = time; self.duration = duration
        self.rms = rms.isFinite ? min(32767, max(0, rms)) : 0
    }
}

/// Stateful mono conversion to Hermes' 16 kHz live-STT contract. Integer ratios use the
/// server's box average (`tools/transcription_streaming.Resampler`); others interpolate.
struct VoicePCMResampler {
    static let targetRate = 16_000.0
    let sourceRate: Double
    private let step: Int?
    private var carry: [Float] = []
    private var position = 0.0

    init(sourceRate: Double) {
        let rate = sourceRate.isFinite && sourceRate >= 8_000 ? sourceRate : Self.targetRate
        self.sourceRate = rate
        let ratio = rate / Self.targetRate
        step = abs(ratio - ratio.rounded()) < 0.000_001 && ratio.rounded() >= 1 ? Int(ratio.rounded()) : nil
    }

    mutating func process(_ samples: [Float]) -> [Int16] {
        samples.withUnsafeBufferPointer { process($0) }
    }

    mutating func process(_ input: UnsafeBufferPointer<Float>) -> [Int16] {
        guard !input.isEmpty else { return [] }
        if step == 1 { return input.map(Self.int16) }
        let data = carry + input
        var output: [Int16] = []
        if let step {
            let usable = data.count - data.count % step
            output.reserveCapacity(usable / step)
            var index = 0
            while index < usable {
                var sum: Float = 0
                for offset in 0..<step { sum += Self.finite(data[index + offset]) }
                output.append(Self.int16(sum / Float(step)))
                index += step
            }
            carry = Array(data[usable...])
            return output
        }
        let ratio = sourceRate / Self.targetRate
        var position = self.position
        let last = data.count - 1
        output.reserveCapacity(Int(Double(data.count) / ratio) + 1)
        while position < Double(last) {
            let index = Int(position), fraction = Float(position - Double(index))
            let a = Self.finite(data[index]), b = Self.finite(data[index + 1])
            output.append(Self.int16(a + (b - a) * fraction))
            position += ratio
        }
        let keep = min(Int(position), data.count)
        carry = Array(data[keep...])
        self.position = position - Double(keep)
        return output
    }

    private static func finite(_ value: Float) -> Float { value.isFinite ? value : 0 }
    static func int16(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16(max(-32768, min(32767, (value * 32767).rounded())))
    }
}

enum VoiceWAV {
    /// Mono s16le WAV: the compact `/api/audio/transcribe` fallback body.
    static func encode(_ samples: [Int16], sampleRate: Int = 16_000) -> Data {
        let bytes = samples.count * 2
        var data = Data(capacity: 44 + bytes)
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); integer(UInt32(36 + bytes))
        data.append(contentsOf: "WAVEfmt ".utf8); integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(sampleRate)); integer(UInt32(sampleRate) * 2); integer(UInt16(2)); integer(UInt16(16))
        data.append(contentsOf: "data".utf8); integer(UInt32(bytes))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    static func pcm(_ samples: [Int16]) -> Data { samples.withUnsafeBytes { Data($0) } }
}

/// `WS /api/audio/transcribe-stream` (audio.py): hello, binary s16le PCM, `eos`.
/// Disconnecting without `eos` cancels the utterance server-side.
enum TranscribeStreamEvent: Equatable {
    case partial(String), final(String), error(String), ignored

    static let hello = #"{"sample_rate":16000}"#
    static let endOfSpeech = #"{"eos":true}"#
    /// Sent immediately when the profile's provider has no live wire (e.g. groq).
    static let unavailableMessage = "no live STT for the configured provider"

    init(_ text: String) {
        guard let event = try? JSONValue.decode(Data(text.utf8)) else { self = .ignored; return }
        switch event["type"].string {
        case "partial": self = .partial(event["text"].string)
        case "final": self = .final(event["transcript"].string.trimmingCharacters(in: .whitespacesAndNewlines))
        case "error": self = .error(event["message"].string.isEmpty ? "live transcription failed" : event["message"].string)
        default: self = .ignored
        }
    }
}

/// `WS /api/audio/speak-stream` server order: `start` arrives with the first PCM chunk
/// (never before any text is sent), then PCM, then `end`; `fallback` only after `done`.
struct SpeakStreamReader {
    enum Action: Equatable { case prepare(sampleRate: Double), finish, fallback }
    private(set) var sampleRate: Double?
    private(set) var done = false

    mutating func text(_ frame: String) throws -> Action? {
        guard !done else { return nil }
        guard let event = try? JSONValue.decode(Data(frame.utf8)) else { throw RPCFailure("Flux vocal Hermes invalide.") }
        if event["type"].string == "error" || !event["error"].string.isEmpty {
            let message = [event["message"].string, event["error"].string].first { !$0.isEmpty }
            throw RPCFailure(message ?? "Hermes n’a pas pu terminer la lecture vocale.")
        }
        switch event["type"].string {
        case "start":
            let rate = event["sample_rate"].double
            guard (8000...96000).contains(rate), event["channels"].int == 1 else { throw RPCFailure("Format vocal Hermes non pris en charge.") }
            if let sampleRate {
                guard sampleRate == rate else { throw RPCFailure("Format vocal Hermes non pris en charge.") }
                return nil
            }
            sampleRate = rate
            return .prepare(sampleRate: rate)
        case "end": done = true; return .finish
        case "fallback": done = true; return .fallback
        default: return nil
        }
    }

    /// PCM is only valid between `start` and `end`.
    func binary() throws -> Double {
        guard !done, let sampleRate else { throw RPCFailure("Flux vocal Hermes invalide.") }
        return sampleRate
    }
}

/// A streamed reply for speech. Deltas are spoken verbatim; the final `message.complete`
/// text only contributes a strict continuation, so server-side normalization of the
/// final text never interrupts or repeats speech.
struct VoiceReplyText {
    let speaksDeltas: Bool
    private(set) var text = ""
    private(set) var complete = false
    private var final: String?
    var display: String { final ?? text }

    init(speaksDeltas: Bool = true, seed: String = "") { self.speaksDeltas = speaksDeltas; text = seed }

    mutating func append(_ delta: String) -> String {
        guard !complete, !delta.isEmpty else { return "" }
        text += delta
        return speaksDeltas ? delta : ""
    }

    mutating func finish(_ finalText: String) -> String {
        guard !complete else { return "" }
        complete = true
        guard speaksDeltas else {
            if !finalText.isEmpty { final = finalText }
            return display
        }
        guard !finalText.isEmpty else { return "" }
        if finalText.hasPrefix(text) {
            let rest = String(finalText.dropFirst(text.count)); text = finalText
            return rest
        }
        final = finalText
        return ""
    }
}

/// Fail-closed self-capture guard (`tools/voice_mode_transcript.is_tts_echo`): a barge-in
/// transcript that mostly matches what Hermes was saying is speaker bleed, not the user.
enum VoiceEcho {
    static let threshold = 0.6
    static let minimumFragment = 10

    static func isEcho(_ transcript: String, spoken: String) -> Bool {
        let a = normalized(transcript), b = normalized(String(spoken.suffix(1_500)))
        guard !a.isEmpty, !b.isEmpty else { return false }
        if ratio(a[...], b[...]) >= threshold { return true }
        guard a.count >= minimumFragment, a.count < b.count, a.count <= 240 else { return false }
        for start in 0...(b.count - a.count) where ratio(a[...], b[start..<(start + a.count)]) >= threshold { return true }
        return false
    }

    private static func normalized(_ text: String) -> [Character] {
        Array(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased())
    }

    /// difflib.SequenceMatcher ratio (no junk heuristic): 2 × matched / total.
    static func ratio(_ a: ArraySlice<Character>, _ b: ArraySlice<Character>) -> Double {
        let total = a.count + b.count
        guard total > 0 else { return 1 }
        return Double(2 * matches(a, b)) / Double(total)
    }

    private static func matches(_ a: ArraySlice<Character>, _ b: ArraySlice<Character>) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var best = (i: a.startIndex, j: b.startIndex, size: 0)
        var previous = [Int](repeating: 0, count: b.count + 1)
        for i in a.indices {
            var current = [Int](repeating: 0, count: b.count + 1)
            for (offset, j) in b.indices.enumerated() where a[i] == b[j] {
                let size = previous[offset] + 1
                current[offset + 1] = size
                if size > best.size { best = (i - size + 1, j - size + 1, size) }
            }
            previous = current
        }
        guard best.size > 0 else { return 0 }
        return best.size
            + matches(a[a.startIndex..<best.i], b[b.startIndex..<best.j])
            + matches(a[(best.i + best.size)...], b[(best.j + best.size)...])
    }
}
