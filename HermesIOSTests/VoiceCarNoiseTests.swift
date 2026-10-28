import XCTest
@testable import HermesIOSCore

/// A car's engine and road noise against a talking voice, with synthetic signals: a steady low-frequency rumble with a little
/// flutter, and a voiced, syllable-modulated "speech" with formants. The numbers are fixed so the tests are deterministic.
final class VoiceCarNoiseTests: XCTestCase {
    private let rate = 48_000.0
    private let frame = 1_024

    // MARK: signals

    private struct Noise {
        var state: UInt64 = 0x9E3779B97F4A7C15
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(Int64(bitPattern: state) >> 11) / Double(1 << 52)          // about -1...1
        }
    }

    private func normalized(_ samples: [Double], rms target: Double) -> [Double] {
        let energy = samples.reduce(0) { $0 + $1 * $1 } / Double(max(samples.count, 1))
        let scale = energy > 0 ? (target / 32767) / energy.squareRoot() : 0
        return samples.map { $0 * scale }
    }

    /// Engine rumble: a 55 Hz fundamental and its first harmonics, a little broadband road noise, a slow flutter.
    private func engine(seconds: Double, rms: Double) -> [Double] {
        var noise = Noise()
        let count = Int(seconds * rate)
        let raw = (0..<count).map { n -> Double in
            let t = Double(n) / rate
            let tone = [(55.0, 1.0), (82.0, 0.8), (110.0, 0.6), (165.0, 0.4), (220.0, 0.25)].reduce(0) { $0 + $1.1 * sin(2 * .pi * $1.0 * t) }
            return (tone * (1 + 0.1 * sin(2 * .pi * 1.5 * t)) + 0.5 * noise.next())
        }
        return normalized(raw, rms: rms)
    }

    /// Voiced speech: a 130 Hz voice with formants near 600, 1500 and 2600 Hz, opening and closing about four times a second.
    private func speech(seconds: Double, rms: Double) -> [Double] {
        let count = Int(seconds * rate)
        let raw = (0..<count).map { n -> Double in
            let t = Double(n) / rate
            let f0 = 130.0 * (1 + 0.02 * sin(2 * .pi * 5 * t))
            var value = 0.0
            for harmonic in 1...30 {
                let f = f0 * Double(harmonic)
                let envelope = [(600.0, 250.0, 1.0), (1500.0, 350.0, 0.6), (2600.0, 450.0, 0.35)]
                    .reduce(0) { $0 + $1.2 * exp(-pow((f - $1.0) / $1.1, 2)) }
                value += envelope * sin(2 * .pi * f * t)
            }
            let syllable = 0.15 + 0.85 * pow(max(0, sin(2 * .pi * 4 * t)), 1.5)
            return value * syllable
        }
        return normalized(raw, rms: rms)
    }

    private func mix(_ a: [Double], _ b: [Double]) -> [Double] { zip(a, b).map { $0 + $1 } }

    private func levels(_ signal: [Double], filter: inout VoiceBandFilter, startingAt time: Double = 0) -> [VoiceLevel] {
        stride(from: 0, to: signal.count - frame + 1, by: frame).map { start in
            let chunk = signal[start..<start + frame].map { Float($0) }
            let rms = (chunk.reduce(0) { $0 + Double($1) * Double($1) } / Double(frame)).squareRoot() * 32767
            let band = chunk.withUnsafeBufferPointer { filter.rms(of: $0) } * 32767
            return VoiceLevel(time: time + Double(start) / rate, duration: Double(frame) / rate, rms: rms, band: band)
        }
    }

    private func overallRMS(_ signal: [Double]) -> Double { (signal.reduce(0) { $0 + $1 * $1 } / Double(signal.count)).squareRoot() * 32767 }

    // MARK: the filter

    func testTheFilterDropsEngineRumbleAndKeepsSpeech() {
        var filter = VoiceBandFilter(sampleRate: rate)
        let rumble = engine(seconds: 3, rms: 2500)
        let rumbleBand = levels(rumble, filter: &filter).dropFirst(20).map(\.band).reduce(0, +) / Double(levels(rumble, filter: &filter).dropFirst(20).count)
        XCTAssertLessThan(rumbleBand, 2500 * 0.3, "the engine is at least 10 dB quieter in the speech band")

        filter = VoiceBandFilter(sampleRate: rate)
        let voice = speech(seconds: 3, rms: 3000)
        let frames = levels(voice, filter: &filter).dropFirst(20)
        let kept = frames.map(\.band).reduce(0, +) / frames.map(\.rms).reduce(0, +)
        XCTAssertGreaterThan(kept, 0.55, "most of the voice survives the filter")
    }

    // MARK: the detector

    private func preferences() -> VoicePreferences { VoicePreferences([:]) }

    func testTheOldRuleMistakesEngineNoiseForSpeech() {
        var filter = VoiceBandFilter(sampleRate: rate)
        var detector = VoiceBargeIn(preferences: preferences())
        let rumble = levels(engine(seconds: 6, rms: 2500), filter: &filter)
        // After the grace window the steady rumble is above the ordinary playback threshold for long enough: the agent is cut off.
        XCTAssertTrue(rumble.contains { detector.sample($0, playing: true) }, "this is the reported bug: noise alone interrupts the reply")
    }

    func testNoisyRuleNeverInterruptsOnEngineNoiseAlone() {
        var filter = VoiceBandFilter(sampleRate: rate)
        let rumble = levels(engine(seconds: 120, rms: 2500), filter: &filter)
        let bandFloor = rumble.dropFirst(30).prefix(100).map(\.band).sorted()[90]
        var detector = VoiceBargeIn(preferences: preferences(), noiseFloor: 2500, environment: .init(noisy: true, bandFloor: bandFloor))
        XCTAssertFalse(rumble.contains { detector.sample($0, playing: true) }, "two minutes of steady engine noise: no interruption")
    }

    func testNoisyRuleStillHearsAVoiceOverTheEngine() {
        var filter = VoiceBandFilter(sampleRate: rate)
        let seconds = 4.0, onset = 2.0
        let background = engine(seconds: seconds, rms: 2500)
        let voice = [Double](repeating: 0, count: Int(onset * rate)) + speech(seconds: seconds - onset, rms: 3500)
        let frames = levels(mix(background, voice), filter: &filter)
        let bandFloor = frames.prefix(Int(onset * rate) / frame).dropFirst(20).map(\.band).sorted().last ?? 0
        var detector = VoiceBargeIn(preferences: preferences(), noiseFloor: 2500, environment: .init(noisy: true, bandFloor: bandFloor))
        var triggeredAt: Double?
        for level in frames where triggeredAt == nil && detector.sample(level, playing: true) { triggeredAt = level.time }
        guard let at = triggeredAt else { return XCTFail("a talking voice over the engine must interrupt") }
        XCTAssertGreaterThanOrEqual(at, onset, "never before the voice starts")
        XCTAssertLessThan(at - onset, 1.6, "and within about a second and a half")
    }

    // MARK: the noise floor

    /// The listening loop as the app runs it: learn the floor until the onset detector hears speech, then stop learning.
    private func listen(_ frames: [VoiceLevel], useBand: Bool) -> (floor: Double, onsetAt: Double?) {
        var floor = VoiceNoiseFloor()
        var onset = VoiceActivity(threshold: 200, silenceDuration: 0.55)
        for level in frames {
            let heard = useBand ? VoiceLevel(time: level.time, duration: level.duration, rms: level.band) : level
            floor.sample(rms: heard.rms, duration: heard.duration, multiplier: 2)
            onset.adapt(noiseFloor: floor.value)
            _ = onset.sample(heard)
            if onset.hasSpeech { return (floor.value, level.time) }
        }
        return (floor.value, nil)
    }

    func testTheFloorLearnsASteadyEngineLevel() {
        var filter = VoiceBandFilter(sampleRate: rate)
        var floor = VoiceNoiseFloor()
        for level in levels(engine(seconds: 3, rms: 2500), filter: &filter) { floor.sample(rms: level.rms, duration: level.duration, multiplier: 2) }
        XCTAssertGreaterThan(floor.value, 1800, "a steady 2500 rumble becomes the floor")
        XCTAssertLessThan(floor.value, 3200)
    }

    func testVoiceAloneIsHeardAndNotLearnedAsBackground() {
        var filter = VoiceBandFilter(sampleRate: rate)
        let frames = levels(speech(seconds: 3, rms: 3000), filter: &filter)
        let result = listen(frames, useBand: false)
        XCTAssertNotNil(result.onsetAt, "speech starts an utterance")
        XCTAssertLessThan(result.floor, 700, "and was not taught to the floor on the way")
    }

    func testInACarEngineAloneNeverStartsAnUtterance() {
        var filter = VoiceBandFilter(sampleRate: rate)
        let frames = levels(engine(seconds: 60, rms: 2500), filter: &filter)
        XCTAssertNil(listen(frames, useBand: true).onsetAt, "a minute of engine noise: no phantom speech")
    }

    func testInACarAVoiceOverTheEngineStartsAnUtterance() {
        var filter = VoiceBandFilter(sampleRate: rate)
        let onset = 4.0
        let background = engine(seconds: 7, rms: 2500)
        let voice = [Double](repeating: 0, count: Int(onset * rate)) + speech(seconds: 3, rms: 3500)
        let frames = levels(mix(background, voice), filter: &filter)
        guard let at = listen(frames, useBand: true).onsetAt else { return XCTFail("the voice over the engine must be heard") }
        XCTAssertGreaterThanOrEqual(at, onset, "not before the voice")
        XCTAssertLessThan(at - onset, 1.5)
    }

    func testAQuietRoomStillCalibratesLow() {
        var floor = VoiceNoiseFloor()
        for _ in 0..<60 { floor.sample(rms: 150, duration: 0.02, multiplier: 2) }
        XCTAssertLessThan(floor.value, 400)
    }
}
