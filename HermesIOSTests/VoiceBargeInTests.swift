import XCTest
@testable import HermesIOSCore

final class VoiceBargeInTests: XCTestCase {
    private func decibels(_ rms: Double) -> Double { 20 * log10(rms / 32767) }

    func testDisabledBargeInNeverInterrupts() {
        var detector = VoiceBargeIn(preferences: VoicePreferences(["barge_in": false]))
        for _ in 0..<100 { XCTAssertFalse(detector.sample(decibels: 0, interval: 0.05)) }
        for _ in 0..<100 { XCTAssertFalse(detector.sample(rms: 9000, duration: 0.05, playing: false)) }
        XCTAssertFalse(detector.triggered)
    }

    func testGraceRejectsPlaybackOnsetAndRequiresFreshSpeech() {
        var detector = VoiceBargeIn(preferences: VoicePreferences([:]))
        for _ in 0..<10 { XCTAssertFalse(detector.sample(decibels: decibels(8000), interval: 0.05)) }
        for _ in 0..<5 { XCTAssertFalse(detector.sample(decibels: decibels(3000), interval: 0.05)) }
        XCTAssertTrue(detector.sample(decibels: decibels(3000), interval: 0.05))
        XCTAssertTrue(detector.triggered)
        XCTAssertFalse(detector.sample(decibels: decibels(3000), interval: 0.05), "One interruption per detector")
    }

    func testGraceSplitsAnIrregularBufferAtItsBoundary() {
        var detector = VoiceBargeIn(preferences: VoicePreferences([:]))
        // 0.45 s of grace, then a 85 ms buffer straddling the 0.5 s boundary.
        for _ in 0..<9 { XCTAssertFalse(detector.sample(rms: 8000, duration: 0.05, playing: true)) }
        for _ in 0..<4 { XCTAssertFalse(detector.sample(rms: 3000, duration: 0.085, playing: true)) }
        XCTAssertTrue(detector.sample(rms: 3000, duration: 0.085, playing: true))
    }

    func testSentenceGapsDoNotReArmGrace() {
        var detector = VoiceBargeIn(preferences: VoicePreferences([:]))
        for _ in 0..<12 { XCTAssertFalse(detector.sample(rms: 100, duration: 0.05, playing: true)) }
        for _ in 0..<6 { XCTAssertFalse(detector.sample(rms: 100, duration: 0.05, playing: false)) }
        // Playback resumes after a 0.3 s gap: the user is heard immediately.
        for _ in 0..<3 { XCTAssertFalse(detector.sample(rms: 3000, duration: 0.06, playing: true)) }
        XCTAssertTrue(detector.sample(rms: 3000, duration: 0.06, playing: true))
    }

    func testGenerationPhaseSpeechInterruptsWithoutGraceAtTheQuietThreshold() {
        var detector = VoiceBargeIn(preferences: VoicePreferences([:]), noiseFloor: 200)
        XCTAssertEqual(detector.quietThreshold, 600)
        XCTAssertEqual(detector.playbackThreshold, 1000)
        for _ in 0..<14 { XCTAssertFalse(detector.sample(rms: 550, duration: 0.0213, playing: false)) }
        for _ in 0..<11 { XCTAssertFalse(detector.sample(rms: 700, duration: 0.0213, playing: false)) }
        XCTAssertTrue(detector.sample(rms: 700, duration: 0.0213, playing: false))
    }

    func testLowPlaybackBleedAndSparseClicksDoNotTrip() {
        var detector = VoiceBargeIn(preferences: VoicePreferences(["barge_in_grace_seconds": 0]))
        for _ in 0..<50 {
            XCTAssertFalse(detector.sample(decibels: decibels(5000), interval: 0.05))
            for _ in 0..<5 { XCTAssertFalse(detector.sample(decibels: decibels(800), interval: 0.05)) }
        }
        XCTAssertFalse(detector.triggered)
    }

    func testMajorityAllowsOneBriefDipInSpokenInterruption() {
        var detector = VoiceBargeIn(preferences: VoicePreferences(["barge_in_grace_seconds": 0]))
        for _ in 0..<3 { XCTAssertFalse(detector.sample(decibels: decibels(3000), interval: 0.05)) }
        XCTAssertFalse(detector.sample(decibels: decibels(300), interval: 0.05))
        XCTAssertFalse(detector.sample(decibels: decibels(3000), interval: 0.05))
        XCTAssertTrue(detector.sample(decibels: decibels(3000), interval: 0.05))
    }

    func testQuietFloorMultiplierScalesBothThresholdsUnderTheCeiling() {
        let preferences = VoicePreferences(["barge_in_threshold_multiplier": 3])
        XCTAssertEqual(VoiceBargeIn(preferences: preferences, noiseFloor: 100).threshold, 1000)
        XCTAssertEqual(VoiceBargeIn(preferences: preferences, noiseFloor: 800).threshold, 2400)
        XCTAssertEqual(VoiceBargeIn(preferences: preferences, noiseFloor: 800).quietThreshold, 2400)
        XCTAssertEqual(VoiceBargeIn(preferences: preferences, noiseFloor: 5000).threshold, 4000)
        XCTAssertEqual(VoiceBargeIn(preferences: preferences, noiseFloor: .nan).threshold, 1000)
        let sensitive = VoiceBargeIn(preferences: VoicePreferences(["barge_in_threshold_multiplier": .number(1.5)]), noiseFloor: 200)
        XCTAssertEqual(sensitive.quietThreshold, 300)
        XCTAssertEqual(sensitive.playbackThreshold, 500)
    }

    func testMalformedSamplesCannotAdvanceGraceOrTrigger() {
        var detector = VoiceBargeIn(preferences: VoicePreferences([:]))
        for interval in [Double.nan, .infinity, -1, 0, 100, 1e-300] {
            XCTAssertFalse(detector.sample(decibels: 0, interval: interval))
        }
        for _ in 0..<30 { XCTAssertFalse(detector.sample(decibels: .nan, interval: 0.05)) }
        for _ in 0..<30 { XCTAssertFalse(detector.sample(rms: .nan, duration: 0.05, playing: false)) }
        XCTAssertFalse(detector.triggered)
    }
}
