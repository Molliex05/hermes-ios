import XCTest
@testable import HermesIOSCore

final class VoiceActivityTests: XCTestCase {
    func testSeparateClicksDoNotAccumulateIntoSpeech() {
        var detector = VoiceActivity(threshold: 200, silenceDuration: 1)
        for _ in 0..<40 {
            XCTAssertFalse(detector.sample(decibels: -10, interval: 0.05))
            for _ in 0..<4 { XCTAssertFalse(detector.sample(decibels: -90, interval: 0.05)) }
        }
        XCTAssertFalse(detector.hasSpeech)
    }

    func testBriefSyllableDipStillConfirmsSpeech() {
        var detector = VoiceActivity(threshold: 200, silenceDuration: 1)
        for _ in 0..<3 { XCTAssertFalse(detector.sample(decibels: -20, interval: 0.05)) }
        XCTAssertFalse(detector.sample(decibels: -90, interval: 0.05))
        for _ in 0..<3 { XCTAssertFalse(detector.sample(decibels: -20, interval: 0.05)) }
        XCTAssertTrue(detector.hasSpeech)
        for _ in 0..<19 { XCTAssertFalse(detector.sample(decibels: -90, interval: 0.05)) }
        XCTAssertTrue(detector.sample(decibels: -90, interval: 0.05))
    }

    func testNoiseClickDoesNotPostponeEndOfRealUtterance() {
        var detector = VoiceActivity(threshold: 200, silenceDuration: 1)
        for _ in 0..<8 { _ = detector.sample(decibels: -20, interval: 0.05) }
        for _ in 0..<14 { XCTAssertFalse(detector.sample(decibels: -90, interval: 0.05)) }
        XCTAssertFalse(detector.sample(decibels: -10, interval: 0.05))
        for _ in 0..<4 { XCTAssertFalse(detector.sample(decibels: -90, interval: 0.05)) }
        XCTAssertTrue(detector.sample(decibels: -90, interval: 0.05))
    }

    func testLongInitialSilenceDoesNotEndListening() {
        var detector = VoiceActivity(threshold: 200, silenceDuration: 1)
        for _ in 0..<1_200 { XCTAssertFalse(detector.sample(decibels: -90, interval: 0.05)) }
        XCTAssertFalse(detector.hasSpeech)
        XCTAssertEqual(detector.elapsed, 60, accuracy: 0.001)
    }

    func testConfirmedBargeInHandoffDoesNotNeedSpeechAgain() {
        var detector = VoiceActivity(threshold: 200, silenceDuration: 1, confirmedSpeech: true)
        XCTAssertTrue(detector.hasSpeech)
        XCTAssertEqual(detector.voicedDuration, 0)
        XCTAssertEqual(detector.elapsed, 0)
        for _ in 0..<19 { XCTAssertFalse(detector.sample(decibels: -90, interval: 0.05)) }
        XCTAssertTrue(detector.sample(decibels: -90, interval: 0.05))
    }

    func testMalformedMeterValuesCannotPoisonDetection() {
        var detector = VoiceActivity(threshold: .nan, silenceDuration: .infinity)
        XCTAssertEqual(detector.threshold, 200)
        XCTAssertEqual(detector.silenceDuration, 3)
        for interval in [Double.nan, .infinity, -.infinity, -1, 0, 10, 1e-300] {
            XCTAssertFalse(detector.sample(decibels: 0, interval: interval))
        }
        XCTAssertEqual(detector.elapsed, 0)
        for value in [Double.nan, .infinity, -.infinity] {
            for _ in 0..<8 { XCTAssertFalse(detector.sample(decibels: value, interval: 0.05)) }
        }
        XCTAssertFalse(detector.hasSpeech)
        for _ in 0..<8 { _ = detector.sample(decibels: -20, interval: 0.05) }
        XCTAssertTrue(detector.hasSpeech)
    }

    func testLevelConversionUsesNativeRMSScale() {
        XCTAssertEqual(VoiceActivity.normalizedLevel(decibels: -20), 0.1, accuracy: 0.00001)
        XCTAssertEqual(VoiceActivity.rms(decibels: -20), 3276.7, accuracy: 0.001)
        XCTAssertEqual(VoiceActivity.normalizedLevel(decibels: 20), 1)
        for value in [-160.0, -1_000, .nan, .infinity, -.infinity] {
            XCTAssertEqual(VoiceActivity.normalizedLevel(decibels: value), 0)
        }
    }

    func testStopPhraseRemainsTheWholeNativeUtterance() {
        XCTAssertTrue(VoiceActivity.isStop("  STOP !\n", phrases: ["stop"]))
        XCTAssertFalse(VoiceActivity.isStop("stop le serveur", phrases: ["stop"]))
        XCTAssertFalse(VoiceActivity.isStop("stop, merci", phrases: ["stop merci"]))
        XCTAssertFalse(VoiceActivity.isStop("stop  merci", phrases: ["stop merci"]))
        XCTAssertFalse(VoiceActivity.isStop("!!!", phrases: [""]))
    }
}
