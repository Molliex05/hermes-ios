import XCTest
@testable import HermesIOSCore

final class VoiceBargeInTests: XCTestCase {
    private func decibels(_ rms: Double) -> Double { 20 * log10(rms / 32767) }

    func testDisabledBargeInNeverInterrupts() {
        var detector = VoiceBargeIn(preferences: VoicePreferences(["barge_in": false]))
        for _ in 0..<100 { XCTAssertFalse(detector.sample(decibels: 0, interval: 0.05)) }
        XCTAssertFalse(detector.triggered)
    }

    func testGraceRejectsPlaybackOnsetAndRequiresFreshSpeech() {
        var detector = VoiceBargeIn(preferences: VoicePreferences([:]))
        for _ in 0..<10 { XCTAssertFalse(detector.sample(decibels: decibels(8000), interval: 0.05)) }
        for _ in 0..<5 { XCTAssertFalse(detector.sample(decibels: decibels(3000), interval: 0.05)) }
        XCTAssertTrue(detector.sample(decibels: decibels(3000), interval: 0.05))
        XCTAssertTrue(detector.triggered)
        XCTAssertFalse(detector.sample(decibels: decibels(3000), interval: 0.05), "One interruption per playback detector")
    }

    func testLowPlaybackBleedAndSparseClicksDoNotTrip() {
        var detector = VoiceBargeIn(preferences: VoicePreferences(["barge_in_grace_seconds": 0]))
        for _ in 0..<50 {
            XCTAssertFalse(detector.sample(decibels: decibels(5000), interval: 0.05))
            for _ in 0..<5 { XCTAssertFalse(detector.sample(decibels: decibels(1000), interval: 0.05)) }
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

    func testQuietFloorMultiplierKeepsNativePlaybackBounds() {
        let preferences = VoicePreferences(["barge_in_threshold_multiplier": 3])
        XCTAssertEqual(VoiceBargeIn(preferences: preferences, noiseFloor: 100).threshold, 1500)
        XCTAssertEqual(VoiceBargeIn(preferences: preferences, noiseFloor: 800).threshold, 2400)
        XCTAssertEqual(VoiceBargeIn(preferences: preferences, noiseFloor: 5000).threshold, 4000)
        XCTAssertEqual(VoiceBargeIn(preferences: preferences, noiseFloor: .nan).threshold, 1500)
    }

    func testMalformedSamplesCannotAdvanceGraceOrTrigger() {
        var detector = VoiceBargeIn(preferences: VoicePreferences([:]))
        for interval in [Double.nan, .infinity, -1, 0, 100, 1e-300] {
            XCTAssertFalse(detector.sample(decibels: 0, interval: interval))
        }
        XCTAssertEqual(detector.elapsed, 0)
        for _ in 0..<30 { XCTAssertFalse(detector.sample(decibels: .nan, interval: 0.05)) }
        XCTAssertFalse(detector.triggered)
    }
}
