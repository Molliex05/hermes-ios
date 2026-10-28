import Foundation

/// Quiet-room calibration, matching Hermes' pre-playback p90 approach.
/// Call only with fresh microphone samples while no reply audio is playing.
struct VoiceNoiseFloor {
    private(set) var value = 200.0
    private var elapsed = 0.0
    private var calibrated = false
    private var samples: [(rms: Double, time: Double)] = []
    /// Everything heard recently, whatever its level: a steady loud background (a car) can only be told from speech by
    /// being steady, so it needs its own window.
    private var recent: [(rms: Double, time: Double)] = []
    var bufferedSampleCount: Int { samples.count }
    /// A level above which the room is considered noisy rather than quiet.
    static let noisyLevel = 700.0

    mutating func sample(decibels: Double, interval: Double, multiplier: Double) {
        guard decibels.isFinite else { return }
        sample(rms: VoiceActivity.rms(decibels: decibels), duration: interval, multiplier: multiplier)
    }

    mutating func sample(rms: Double, duration interval: Double, multiplier: Double) {
        guard rms.isFinite, VoiceActivity.validInterval(interval) else { return }
        elapsed += interval
        let now = elapsed
        let factor = VoicePreferences.bounded(multiplier, default: 3, range: 1...10)
        samples.removeAll { now - $0.time > 3 }
        recent.append((rms, now)); recent.removeAll { now - $0.time > 1.6 }
        // Steady loud noise (engine, road, wind) never passes the bootstrap cap below. Accept it as the floor when the last
        // second and a half barely varies; speech, which rises and falls, never does.
        if !calibrated || value < Self.noisyLevel, let steady = Self.steadyLevel(recent, now: now) {
            calibrated = true
            value = max(200, steady)
            samples = recent.map { $0 }
            return
        }
        // Once calibrated, reject probable speech instead of teaching its level to the
        // ambient floor. Bootstrap never learns a level that would hide normal speech.
        guard rms < (calibrated ? max(400, value * factor) : 1_500) else { return }
        samples.append((rms, elapsed))
        if samples.count > 60 { samples.removeFirst(samples.count - 60) }
        guard calibrated || elapsed + 0.000_001 >= 0.45 else { return }
        calibrated = true
        let sorted = samples.map(\.rms).sorted()
        let position = Double(sorted.count - 1) * 0.9
        let lower = Int(position)
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        let percentile = sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
        value = max(200, percentile)
    }

    /// The level of a steady background: at least 1.2 s of frames whose loudest is under 1.8 times their quietest, and
    /// louder than a quiet room (a quiet room is handled by the ordinary path).
    private static func steadyLevel(_ frames: [(rms: Double, time: Double)], now: Double) -> Double? {
        guard let first = frames.first, now - first.time >= 1.2, frames.count >= 12 else { return nil }
        let levels = frames.map(\.rms).sorted()
        let low = levels[levels.count / 10], high = levels[levels.count * 9 / 10]
        guard low >= Self.noisyLevel * 0.6, high <= low * 1.8, high < 9_000 else { return nil }
        return high
    }
}
