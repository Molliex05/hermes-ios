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
        guard decibels.isFinite, VoiceActivity.validInterval(interval) else { return }
        elapsed += interval
        let now = elapsed
        let rms = VoiceActivity.rms(decibels: decibels)
        let factor = VoicePreferences.bounded(multiplier, default: 3, range: 1...10)
        samples.removeAll { now - $0.time > 3 }
        // Bootstrap at utterance end, before playback. Once calibrated, reject
        // probable speech instead of teaching its level to the ambient floor.
        guard !calibrated || rms < max(400, value * factor) else { return }
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
