import Foundation

/// Full-duplex interruption detection for the whole agent turn, while Hermes generates
/// (no audio yet) and while it speaks (`voice.barge_in*`, desktop `voice-barge-in.ts`).
/// noiseFloor is a quiet-room RMS measurement (0...32767), never speaker bleed. Apple's
/// voice processing cancels most echo, so the playback clamp sits below the desktop's
/// 1500; it scales with the profile multiplier and stays reachable under a 4000 ceiling.
struct VoiceBargeIn {
    static let ceiling = 4000.0
    /// In a noisy place (a car) the detector listens to the speech band only, wants a clear rise above the steady background,
    /// and waits longer before cutting the agent off: a steady rumble never qualifies, a voice does within about half a second.
    struct Environment: Equatable {
        var noisy = false
        /// The speech-band level of the quiet moments, measured like the ordinary floor (see `VoiceNoiseFloor`).
        var bandFloor = 0.0
        static let quiet = Environment()
    }
    static let noisyCeiling = 9000.0
    static let noisyRise = 1.8
    static let noisySustain = 0.5
    /// Share of the half second that must show the rise: speech has gaps between syllables, an engine never rises at all.
    static let noisyDuty = 0.55
    let environment: Environment
    let quietThreshold: Double
    let playbackThreshold: Double
    let graceDuration: Double
    private let enabled: Bool
    private(set) var triggered = false
    private var evidence: VoiceEvidenceWindow
    /// Slowly following average of the speech-band level, to tell a rise (speech) from a steady background.
    private var baseline = 0.0
    private let bandThreshold: Double
    private var grace = 0.0
    private var sincePlayback = Double.infinity
    private var wasPlaying = false

    var threshold: Double { playbackThreshold }

    init(preferences: VoicePreferences, noiseFloor: Double = 0, environment: Environment = .quiet) {
        self.environment = environment
        evidence = VoiceEvidenceWindow(duration: environment.noisy ? Self.noisySustain : 0.3)
        enabled = preferences.bargeIn
        graceDuration = preferences.bargeInGraceSeconds
        let floor = VoicePreferences.bounded(noiseFloor, default: 0, range: 0...32767)
        let scale = preferences.bargeInThresholdMultiplier / 3
        quietThreshold = min(Self.ceiling, max(500 * scale, preferences.threshold, floor * preferences.bargeInThresholdMultiplier))
        playbackThreshold = min(Self.ceiling, max(1000 * scale, quietThreshold))
        // Speech-band threshold for a noisy place: above the band's own floor. The clear rise over the steady background (below) is what
        // really tells a voice from the engine, so this one stays modest and natural pauses between syllables are tolerated.
        bandThreshold = min(Self.noisyCeiling, max(400 * scale, environment.bandFloor * 2))
    }

    /// Legacy playback-only feed (one detector per playback).
    mutating func sample(decibels: Double, interval: Double) -> Bool {
        sample(rms: VoiceActivity.rms(decibels: decibels), duration: interval, playing: true)
    }

    mutating func sample(_ level: VoiceLevel, playing: Bool) -> Bool {
        guard environment.noisy else { return sample(rms: level.rms, duration: level.duration, playing: playing) }
        return sampleNoisy(band: level.band, duration: level.duration, playing: playing)
    }

    /// The noisy-place rule: the speech band must be above its threshold AND clearly above the steady background, for about
    /// half a second.
    private mutating func sampleNoisy(band: Double, duration interval: Double, playing: Bool) -> Bool {
        guard enabled, !triggered else { return false }
        guard VoiceActivity.validInterval(interval) else { evidence.clear(); return false }
        if playing && !wasPlaying && sincePlayback >= 1 { grace = graceDuration; evidence.clear() }
        wasPlaying = playing
        sincePlayback = playing ? 0 : sincePlayback + interval
        let level = band.isFinite ? band : 0
        // Follow the background quickly while it is steady, slowly while it is elevated (so speech does not become the baseline).
        if baseline == 0 { baseline = level }
        let rate = level < baseline * 1.5 ? min(1, interval / 2.0) : min(1, interval / 20.0)
        baseline += (level - baseline) * rate
        var observed = interval
        if grace > 0 {
            let consumed = min(grace, interval)
            grace -= consumed; observed -= consumed
            guard observed > 0.000_001 else { evidence.clear(); return false }
        }
        let rises = level >= max(baseline, 50) * Self.noisyRise
        evidence.append(above: level >= bandThreshold && rises, duration: observed)
        guard evidence.span + 0.000_001 >= Self.noisySustain,
              evidence.voicedDuration + 0.000_001 >= evidence.span * Self.noisyDuty else { return false }
        triggered = true
        return true
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
