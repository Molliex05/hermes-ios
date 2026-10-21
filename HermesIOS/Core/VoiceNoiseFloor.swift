import Foundation

/// Quiet-room calibration, matching Hermes' pre-playback p90 approach.
/// Call only with fresh microphone samples while no reply audio is playing.
struct VoiceNoiseFloor {
    private(set) var value = 200.0
    private var elapsed = 0.0
    private var calibrated = false
    private var samples: [(rms: Double, time: Double)] = []
    var bufferedSampleCount: Int { samples.count }

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
}
