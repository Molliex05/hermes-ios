import XCTest
@testable import HermesIOSCore

final class VoiceNoiseFloorTests: XCTestCase {
    private func decibels(_ rms: Double) -> Double { 20 * log10(rms / 32767) }

    func testBootstrapLearnsNoisyRoomAndAffectsInterruptionThreshold() {
        var floor = VoiceNoiseFloor()
        for _ in 0..<8 { floor.sample(decibels: decibels(800), interval: 0.05, multiplier: 3) }
        XCTAssertEqual(floor.value, 200)
        floor.sample(decibels: decibels(800), interval: 0.05, multiplier: 3)
        XCTAssertEqual(floor.value, 800, accuracy: 0.001)
        let detector = VoiceBargeIn(preferences: VoicePreferences([:]), noiseFloor: floor.value)
        XCTAssertEqual(detector.threshold, 2400, accuracy: 0.001)
    }

    func testSpeechOutliersCannotInflateCalibratedFloor() {
        var floor = VoiceNoiseFloor()
        for _ in 0..<9 { floor.sample(decibels: decibels(800), interval: 0.05, multiplier: 3) }
        for _ in 0..<80 { floor.sample(decibels: decibels(5000), interval: 0.05, multiplier: 3) }
        XCTAssertEqual(floor.value, 800, accuracy: 0.001)
        floor.sample(decibels: decibels(800), interval: 0.05, multiplier: 3)
        XCTAssertEqual(floor.value, 800, accuracy: 0.001)
    }

    func testOldAmbientSamplesExpireAndStorageRemainsBounded() {
        var floor = VoiceNoiseFloor()
        for _ in 0..<9 { floor.sample(decibels: decibels(800), interval: 0.05, multiplier: 3) }
        for _ in 0..<80 { floor.sample(decibels: decibels(250), interval: 0.05, multiplier: 3) }
        XCTAssertEqual(floor.value, 250, accuracy: 0.001)
        for _ in 0..<10_000 { floor.sample(decibels: decibels(250), interval: 0.001, multiplier: 3) }
        XCTAssertLessThanOrEqual(floor.bufferedSampleCount, 60)
        XCTAssertEqual(floor.value, 250, accuracy: 0.001)
    }

    func testMalformedSamplesCannotPoisonOrCompleteCalibration() {
        var floor = VoiceNoiseFloor()
        for level in [Double.nan, .infinity, -.infinity] {
            floor.sample(decibels: level, interval: 0.05, multiplier: 3)
        }
        for interval in [Double.nan, .infinity, -1, 0, 100] {
            floor.sample(decibels: decibels(800), interval: interval, multiplier: 3)
        }
        XCTAssertEqual(floor.value, 200)
        XCTAssertEqual(floor.bufferedSampleCount, 0)
        for _ in 0..<9 { floor.sample(decibels: decibels(800), interval: 0.05, multiplier: .nan) }
        XCTAssertEqual(floor.value, 800, accuracy: 0.001)
        floor.sample(decibels: decibels(5000), interval: 0.05, multiplier: .infinity)
        XCTAssertEqual(floor.value, 800, accuracy: 0.001)
    }

    func testQuietRoomHasNativeMinimumAndNewInstanceResetsCalibration() {
        var floor = VoiceNoiseFloor()
        for _ in 0..<9 { floor.sample(decibels: decibels(50), interval: 0.05, multiplier: 3) }
        XCTAssertEqual(floor.value, 200)
        floor = VoiceNoiseFloor()
        XCTAssertEqual(floor.value, 200)
        XCTAssertEqual(floor.bufferedSampleCount, 0)
    }
}
