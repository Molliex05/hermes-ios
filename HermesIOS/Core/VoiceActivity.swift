import Foundation

/// Phone-side endpoint detection on timestamped audio-thread meter frames. The profile's
/// RMS threshold is raised by the measured room floor (onset ×2, silence ×1.5), so a
/// noisy room still reaches end-of-speech instead of recording to the cap.
struct VoiceActivity {
    let threshold: Double
    let silenceDuration: Double
    private(set) var noiseFloor = 0.0
    private(set) var voicedDuration = 0.0
    private(set) var silence = 0.0
    private(set) var elapsed = 0.0
    private(set) var hasSpeech: Bool
    private var evidence = VoiceEvidenceWindow(duration: 0.4)

    /// A barge-in handoff can preserve speech already confirmed in captured pre-roll.
    init(threshold: Double, silenceDuration: Double, confirmedSpeech: Bool = false, noiseFloor: Double = 0) {
        self.threshold = VoicePreferences.bounded(threshold, default: 200, range: 1...32767)
        self.silenceDuration = VoicePreferences.bounded(silenceDuration, default: 3, range: 0.3...30)
        hasSpeech = confirmedSpeech
        adapt(noiseFloor: noiseFloor)
    }

    var onsetLevel: Double { max(threshold, noiseFloor * 2) }
    var silenceLevel: Double { max(threshold, noiseFloor * 1.5) }

    mutating func adapt(noiseFloor value: Double) {
        noiseFloor = VoicePreferences.bounded(value, default: 0, range: 0...2_000)
    }

    mutating func sample(_ level: VoiceLevel) -> Bool { sample(rms: level.rms, duration: level.duration) }
    mutating func sample(decibels: Double, interval: Double) -> Bool { sample(rms: Self.rms(decibels: decibels), duration: interval) }

    mutating func sample(rms: Double, duration interval: Double) -> Bool {
        guard Self.validInterval(interval) else {
            evidence.clear()
            voicedDuration = 0
            return false
        }
        elapsed += interval
        let level = rms.isFinite ? rms : 0
        let above = level > (hasSpeech ? silenceLevel : onsetLevel)
        evidence.append(above: above, duration: interval)
        voicedDuration = evidence.voicedDuration
        // Require 300 ms of voiced evidence in the last 400 ms. Short syllabic
        // dips are allowed, but separated clicks can never accumulate forever.
        if above && voicedDuration + 0.000_001 >= 0.3 {
            hasSpeech = true
            silence = 0
        } else if hasSpeech {
            // A brief noise spike after speech must not keep resetting the
            // endpoint. Resumed speech first has to pass the same confirmation.
            silence += interval
        }
        return hasSpeech && !above && silence + 0.000_001 >= silenceDuration
    }

    /// Linear full-scale amplitude (0...1), not a device-specific display gain.
    static func normalizedLevel(decibels: Double) -> Double {
        guard decibels.isFinite, decibels > -160 else { return 0 }
        return pow(10, min(0, decibels) / 20)
    }

    static func normalizedLevel(rms: Double) -> Double {
        rms.isFinite ? min(1, max(0, rms / 32767)) : 0
    }

    /// Matches Hermes' signed 16-bit RMS scale.
    static func rms(decibels: Double) -> Double { normalizedLevel(decibels: decibels) * 32767 }

    static func validInterval(_ interval: Double) -> Bool {
        interval.isFinite && (0.001...0.25).contains(interval)
    }

    static func isStop(_ text: String, phrases: [String]) -> Bool {
        // Match the native whole-utterance contract. Internal punctuation and
        // spaces carry meaning; “stop the server” is never an exit command.
        let punctuation = CharacterSet(charactersIn: ".,!?;: \t\n\"'")
        let utterance = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().trimmingCharacters(in: punctuation)
        return !utterance.isEmpty && phrases.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == utterance
        }
    }
}

/// A small time-weighted window shared by endpoint and interruption detection.
/// At audio-buffer cadence (~20-50 Hz) this holds only a handful of samples.
struct VoiceEvidenceWindow {
    let duration: Double
    private var samples: [(above: Bool, duration: Double)] = []
    private(set) var span = 0.0
    private(set) var voicedDuration = 0.0

    /// Explicit: with a private stored property the synthesized memberwise initializer is private on older toolchains
    /// (CI's macos-15 runner), so `VoiceActivity` and `VoiceBargeIn` could not build it.
    init(duration: Double) { self.duration = duration }

    mutating func clear() {
        samples.removeAll(keepingCapacity: true); span = 0; voicedDuration = 0
    }

    mutating func append(above: Bool, duration interval: Double) {
        samples.append((above, interval))
        span += interval
        if above { voicedDuration += interval }
        while span > duration, !samples.isEmpty {
            let excess = span - duration
            let removed = min(excess, samples[0].duration)
            span -= removed
            if samples[0].above { voicedDuration -= removed }
            if removed + 0.000_001 >= samples[0].duration { samples.removeFirst() }
            else { samples[0].duration -= removed }
        }
        voicedDuration = min(span, max(0, voicedDuration))
    }
}
