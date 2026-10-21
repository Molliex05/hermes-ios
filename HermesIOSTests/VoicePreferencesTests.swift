import XCTest
@testable import HermesIOSCore

final class VoicePreferencesTests: XCTestCase {
    func testNativeDefaultsAndExplicitPreferences() {
        let defaults = VoicePreferences([:])
        XCTAssertEqual(defaults.threshold, 200)
        XCTAssertEqual(defaults.silenceDuration, 3)
        XCTAssertEqual(defaults.stopPhrases, ["stop"])
        XCTAssertTrue(defaults.bargeIn)
        XCTAssertEqual(defaults.bargeInGraceSeconds, 0.5)
        XCTAssertEqual(defaults.bargeInThresholdMultiplier, 3)
        let configured = VoicePreferences(["silence_threshold": 350, "silence_duration": .number(1.5),
            "barge_in": false, "barge_in_grace_seconds": 0, "barge_in_threshold_multiplier": 4])
        XCTAssertEqual(configured.threshold, 350)
        XCTAssertEqual(configured.silenceDuration, 1.5)
        XCTAssertFalse(configured.bargeIn)
        XCTAssertEqual(configured.bargeInGraceSeconds, 0)
        XCTAssertEqual(configured.bargeInThresholdMultiplier, 4)
    }

    func testMalformedAndNonFiniteNumbersUseDefaults() {
        let values: [JSONValue] = [.string("broken"), .bool(true), .object([:]), .number(.nan), .number(.infinity), .number(-.infinity)]
        for value in values {
            let preferences = VoicePreferences(["silence_threshold": value, "silence_duration": value,
                "barge_in_grace_seconds": value, "barge_in_threshold_multiplier": value])
            XCTAssertEqual(preferences.threshold, 200)
            XCTAssertEqual(preferences.silenceDuration, 3)
            XCTAssertEqual(preferences.bargeInGraceSeconds, 0.5)
            XCTAssertEqual(preferences.bargeInThresholdMultiplier, 3)
        }
    }

    func testFiniteOutliersStayWithinAudioBounds() {
        let low = VoicePreferences(["silence_threshold": -1, "silence_duration": -1,
            "barge_in_grace_seconds": -1, "barge_in_threshold_multiplier": -1])
        XCTAssertEqual(low.threshold, 1)
        XCTAssertEqual(low.silenceDuration, 0.3)
        XCTAssertEqual(low.bargeInGraceSeconds, 0)
        XCTAssertEqual(low.bargeInThresholdMultiplier, 1)
        let high = VoicePreferences(["silence_threshold": 999999, "silence_duration": 999999,
            "barge_in_grace_seconds": 999999, "barge_in_threshold_multiplier": 999999])
        XCTAssertEqual(high.threshold, 32767)
        XCTAssertEqual(high.silenceDuration, 30)
        XCTAssertEqual(high.bargeInGraceSeconds, 5)
        XCTAssertEqual(high.bargeInThresholdMultiplier, 10)
    }

    func testStopPhraseStringAndExplicitDisabledList() {
        XCTAssertEqual(VoicePreferences(["stop_phrases": "  Au revoir  "]).stopPhrases, ["Au revoir"])
        XCTAssertEqual(VoicePreferences(["stop_phrases": []]).stopPhrases, [])
        XCTAssertEqual(VoicePreferences(["stop_phrases": [" ", "stop", false, 42]]).stopPhrases, ["stop"])
        XCTAssertEqual(VoicePreferences(["stop_phrases": ["bad": true]]).stopPhrases, ["stop"])
    }

    @MainActor
    func testTranscriptionPreservesBytesAndMimeType() async throws {
        let recording = Data([0, 1, 2, 127, 128, 255])
        let api = NativeVoiceAPI { path, body, rpc in
            XCTAssertEqual(path, "/api/audio/transcribe")
            XCTAssertFalse(rpc)
            XCTAssertEqual(body["mime_type"], "audio/wav")
            let encoded = body["data_url"].string
            XCTAssertTrue(encoded.hasPrefix("data:audio/wav;base64,"))
            XCTAssertEqual(Data(base64Encoded: String(encoded.split(separator: ",", maxSplits: 1)[1])), recording)
            return ["transcript": " Bonjour \n"]
        }
        let text = try await api.transcribe(recording, mimeType: "audio/wav")
        XCTAssertEqual(text, "Bonjour")
    }

    @MainActor
    func testCancelledTranscriptionNeverSubmitsAudio() async {
        var submitted = false
        let api = NativeVoiceAPI { _, _, _ in submitted = true; return ["transcript": "Unexpected"] }
        let task = Task { try await api.transcribe(Data([1, 2, 3]), mimeType: "audio/wav") }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must be propagated before the audio request")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(submitted)
    }
}
