import Foundation

/// Full-duplex interruption detection for the whole agent turn, while Hermes generates
/// (no audio yet) and while it speaks (`voice.barge_in*`, desktop `voice-barge-in.ts`).
/// noiseFloor is a quiet-room RMS measurement (0...32767), never speaker bleed. Apple's
/// voice processing cancels most echo, so the playback clamp sits below the desktop's
/// 1500; it scales with the profile multiplier and stays reachable under a 4000 ceiling.
struct VoiceBargeIn {
    static let ceiling = 4000.0
    let quietThreshold: Double
    let playbackThreshold: Double
    let graceDuration: Double
    private let enabled: Bool
    private(set) var triggered = false
    private var evidence = VoiceEvidenceWindow(duration: 0.3)
    private var grace = 0.0
    private var sincePlayback = Double.infinity
    private var wasPlaying = false

    var threshold: Double { playbackThreshold }

    init(preferences: VoicePreferences, noiseFloor: Double = 0) {
        enabled = preferences.bargeIn
        graceDuration = preferences.bargeInGraceSeconds
        let floor = VoicePreferences.bounded(noiseFloor, default: 0, range: 0...32767)
        let scale = preferences.bargeInThresholdMultiplier / 3
        quietThreshold = min(Self.ceiling, max(500 * scale, preferences.threshold, floor * preferences.bargeInThresholdMultiplier))
        playbackThreshold = min(Self.ceiling, max(1000 * scale, quietThreshold))
    }

    /// Legacy playback-only feed (one detector per playback).
    mutating func sample(decibels: Double, interval: Double) -> Bool {
        sample(rms: VoiceActivity.rms(decibels: decibels), duration: interval, playing: true)
    }

    mutating func sample(_ level: VoiceLevel, playing: Bool) -> Bool {
        sample(rms: level.rms, duration: level.duration, playing: playing)
    }

    /// Returns true once per detector. Grace re-arms only when playback starts after a
    /// real gap (>= 1 s), so sentence gaps cannot chain grace windows.
    mutating func sample(rms: Double, duration interval: Double, playing: Bool) -> Bool {
        guard enabled, !triggered else { return false }
        guard VoiceActivity.validInterval(interval) else { evidence.clear(); return false }
        if playing && !wasPlaying && sincePlayback >= 1 { grace = graceDuration; evidence.clear() }
        wasPlaying = playing
        sincePlayback = playing ? 0 : sincePlayback + interval
        var observed = interval
        if grace > 0 {
            let consumed = min(grace, interval)
            grace -= consumed; observed -= consumed
            guard observed > 0.000_001 else { evidence.clear(); return false }
        }
        let above = (rms.isFinite ? rms : 0) >= (playing ? playbackThreshold : quietThreshold)
        evidence.append(above: above, duration: observed)
        // Time-weighted majority tolerates a brief dip without mistaking sparse
        // clicks or a playback onset transient for an interruption.
        guard above, evidence.span + 0.000_001 >= 0.3,
              evidence.voicedDuration + 0.000_001 >= evidence.span * 0.8 else { return false }
        triggered = true
        return true
    }
}
