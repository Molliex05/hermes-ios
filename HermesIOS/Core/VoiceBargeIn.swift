import Foundation

/// Conservative playback interruption detection using Hermes' native tuning.
/// noiseFloor is a quiet-room RMS measurement (0...32767), never speaker bleed.
/// Echo rejection still depends on the audio route and Apple's voice processing.
struct VoiceBargeIn {
    let threshold: Double
    let graceDuration: Double
    private let enabled: Bool
    private(set) var elapsed = 0.0
    private(set) var triggered = false
    private var evidence = VoiceEvidenceWindow(duration: 0.3)

    init(preferences: VoicePreferences, noiseFloor: Double = 0) {
        enabled = preferences.bargeIn
        graceDuration = preferences.bargeInGraceSeconds
        let floor = VoicePreferences.bounded(noiseFloor, default: 0, range: 0...32767)
        threshold = min(4000, max(1500, preferences.threshold, floor * preferences.bargeInThresholdMultiplier))
    }

    /// Returns true once per detector. Create a fresh instance at playback onset.
    mutating func sample(decibels: Double, interval: Double) -> Bool {
        guard enabled, !triggered else { return false }
        guard VoiceActivity.validInterval(interval) else { evidence.clear(); return false }
        let previous = elapsed
        elapsed += interval
        guard elapsed > graceDuration else { evidence.clear(); return false }
        let observed = elapsed - max(previous, graceDuration)
        let above = VoiceActivity.rms(decibels: decibels) >= threshold
        evidence.append(above: above, duration: observed)
        // Time-weighted majority tolerates a brief dip without mistaking sparse
        // clicks or a playback onset transient for an interruption.
        guard above, evidence.span + 0.000_001 >= 0.3,
              evidence.voicedDuration + 0.000_001 >= evidence.span * 0.8 else { return false }
        triggered = true
        return true
    }
}
