import XCTest
@testable import HermesIOSCore

final class VoiceStreamTests: XCTestCase {
    // MARK: Endpointing on timestamped audio-thread frames

    func testEndpointUsesEachFrameDurationNotAPollingInterval() {
        var detector = VoiceActivity(threshold: 200, silenceDuration: 0.8)
        // 1024-frame buffers at 48 kHz (21.3 ms) confirm speech after 300 ms of evidence.
        for _ in 0..<15 { XCTAssertFalse(detector.sample(VoiceLevel(time: 0, duration: 1024 / 48000, rms: 2000))) }
        XCTAssertTrue(detector.hasSpeech)
        // Irregular buffers (85 ms, then 4096 frames at 48 kHz): 0.8 s of silence, not N samples.
        for _ in 0..<9 { XCTAssertFalse(detector.sample(rms: 20, duration: 0.085)) }
        XCTAssertTrue(detector.sample(rms: 20, duration: 4096 / 48000))
    }

    func testNoisyRoomStillReachesEndOfSpeechWithAdaptiveFloor() {
        var fixed = VoiceActivity(threshold: 200, silenceDuration: 0.8, confirmedSpeech: true)
        for _ in 0..<40 { XCTAssertFalse(fixed.sample(rms: 450, duration: 0.05), "A 450 RMS room never sounds silent at 200") }
        var adaptive = VoiceActivity(threshold: 200, silenceDuration: 0.8, confirmedSpeech: true, noiseFloor: 400)
        XCTAssertEqual(adaptive.onsetLevel, 800)
        XCTAssertEqual(adaptive.silenceLevel, 600)
        for _ in 0..<15 { XCTAssertFalse(adaptive.sample(rms: 450, duration: 0.05)) }
        XCTAssertTrue(adaptive.sample(rms: 450, duration: 0.05))
        var onset = VoiceActivity(threshold: 200, silenceDuration: 0.8, noiseFloor: 400)
        for _ in 0..<20 { _ = onset.sample(rms: 700, duration: 0.05) }
        XCTAssertFalse(onset.hasSpeech, "Room noise below twice the floor is not an utterance")
        for _ in 0..<7 { _ = onset.sample(rms: 1200, duration: 0.05) }
        XCTAssertTrue(onset.hasSpeech)
    }

    func testEndpointPreferencesFavorASnappyDefaultButKeepExplicitValues() {
        XCTAssertEqual(VoicePreferences([:]).endpointSilence, 0.55)
        XCTAssertEqual(VoicePreferences(["silence_duration": 3]).endpointSilence, 0.55)
        XCTAssertEqual(VoicePreferences(["silence_duration": .number(1.2)]).endpointSilence, 1.2)
        XCTAssertEqual(VoicePreferences(["silence_duration": .number(0.1)]).endpointSilence, 0.3)
        XCTAssertEqual(VoicePreferences(["silence_duration": 5]).endpointSilence, 5)
        XCTAssertEqual(VoicePreferences([:]).maxRecordingSeconds, 120)
        XCTAssertEqual(VoicePreferences(["max_recording_seconds": 45]).maxRecordingSeconds, 45)
        XCTAssertEqual(VoicePreferences(["max_recording_seconds": 9_999]).maxRecordingSeconds, 300)
        XCTAssertFalse(VoicePreferences([:]).liveTranscription)
        XCTAssertTrue(VoicePreferences([:], stt: ["streaming": true]).liveTranscription)
        XCTAssertTrue(VoicePreferences([:], stt: ["streaming": "yes"]).liveTranscription)
        XCTAssertFalse(VoicePreferences([:], stt: ["streaming": "off"]).liveTranscription)
    }

    // MARK: 16 kHz PCM for live STT

    func testIntegerRatioUsesBoxAverageAcrossBufferBoundaries() {
        var resampler = VoicePCMResampler(sourceRate: 48000)
        let first = resampler.process([0.3, 0.3, 0.3, 0.6, 0.6])
        XCTAssertEqual(first, [VoicePCMResampler.int16(0.3)])
        let second = resampler.process([0.6, -1, -1, -1])
        XCTAssertEqual(second, [VoicePCMResampler.int16(0.6), -32767])
        var total = 0
        var stream = VoicePCMResampler(sourceRate: 48000)
        for _ in 0..<100 { total += stream.process([Float](repeating: 0.1, count: 1024)).count }
        XCTAssertEqual(total, 102_400 / 3)
    }

    func testFractionalRatioInterpolatesAndKeepsRate() {
        var resampler = VoicePCMResampler(sourceRate: 44100)
        var produced = 0
        for _ in 0..<44 { produced += resampler.process([Float](repeating: 0.5, count: 1003)).count }
        XCTAssertEqual(Double(produced), 44 * 1003 * 16000 / 44100, accuracy: 2)
        var ramp = VoicePCMResampler(sourceRate: 24000)
        let output = ramp.process((0..<7).map { Float($0) / 10 })
        XCTAssertEqual(output.count, 4)
        XCTAssertEqual(output[1], VoicePCMResampler.int16(0.15))
    }

    func testSameRateAndMalformedSamplesAreSafe() {
        var direct = VoicePCMResampler(sourceRate: 16000)
        XCTAssertEqual(direct.process([0, 1, -1, 2, .nan, .infinity]), [0, 32767, -32767, 32767, 0, 0])
        var broken = VoicePCMResampler(sourceRate: .nan)
        XCTAssertEqual(broken.sourceRate, 16000)
        XCTAssertEqual(broken.process([]), [])
    }

    func testCompactWAVHeader() {
        let wav = VoiceWAV.encode([1, -1, 300])
        XCTAssertEqual(wav.count, 44 + 6)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian, 16000)
        XCTAssertEqual(wav[34], 16)
        XCTAssertEqual(VoiceWAV.pcm([1, -1]), Data([1, 0, 0xFF, 0xFF]))
    }

    // MARK: Wire contracts

    func testTranscribeStreamMessages() {
        XCTAssertEqual(TranscribeStreamEvent(#"{"type":"partial","text":"Bonjour"}"#), .partial("Bonjour"))
        XCTAssertEqual(TranscribeStreamEvent(#"{"type":"final","transcript":" Bonjour Hermes \n","provider":"openai"}"#), .final("Bonjour Hermes"))
        XCTAssertEqual(TranscribeStreamEvent(#"{"type":"error","message":"no live STT for the configured provider"}"#), .error(TranscribeStreamEvent.unavailableMessage))
        XCTAssertEqual(TranscribeStreamEvent(#"{"type":"error"}"#), .error("live transcription failed"))
        XCTAssertEqual(TranscribeStreamEvent("not json"), .ignored)
        XCTAssertEqual(try JSONValue.decode(Data(TranscribeStreamEvent.hello.utf8))["sample_rate"].int, 16000)
        XCTAssertEqual(try JSONValue.decode(Data(TranscribeStreamEvent.endOfSpeech.utf8))["eos"], true)
    }

    func testSpeakStreamStartArrivesWithFirstPCMNotBeforeText() throws {
        var reader = SpeakStreamReader()
        XCTAssertThrowsError(try reader.binary(), "PCM before start is a protocol error")
        XCTAssertEqual(try reader.text(#"{"type":"start","sample_rate":24000,"channels":1}"#), .prepare(sampleRate: 24000))
        XCTAssertEqual(try reader.binary(), 24000)
        XCTAssertNil(try reader.text(#"{"type":"start","sample_rate":24000,"channels":1}"#))
        XCTAssertNil(try reader.text(#"{"type":"progress"}"#))
        XCTAssertEqual(try reader.text(#"{"type":"end"}"#), .finish)
        XCTAssertThrowsError(try reader.binary())
        XCTAssertNil(try reader.text(#"{"type":"end"}"#))
    }

    func testSpeakStreamFallbackErrorsAndFormats() {
        var fallback = SpeakStreamReader()
        XCTAssertEqual(try fallback.text(#"{"type":"fallback"}"#), .fallback)
        var empty = SpeakStreamReader()
        XCTAssertEqual(try empty.text(#"{"type":"end"}"#), .finish, "An empty reply may end without PCM")
        for frame in [#"{"type":"start","sample_rate":4000,"channels":1}"#, #"{"type":"start","sample_rate":24000,"channels":2}"#,
                      #"{"type":"error","message":"provider down"}"#, #"{"error":"boom"}"#, "garbage"] {
            var reader = SpeakStreamReader()
            XCTAssertThrowsError(try reader.text(frame), frame)
        }
        var changed = SpeakStreamReader()
        _ = try? changed.text(#"{"type":"start","sample_rate":24000,"channels":1}"#)
        XCTAssertThrowsError(try changed.text(#"{"type":"start","sample_rate":16000,"channels":1}"#))
    }

    // MARK: Streamed reply text

    func testDeltasAreSpokenOnceAndNormalizedFinalNeverStopsSpeech() {
        var reply = VoiceReplyText()
        XCTAssertEqual(reply.append("Bonjour, "), "Bonjour, ")
        XCTAssertEqual(reply.append("**Maxime**."), "**Maxime**.")
        XCTAssertEqual(reply.finish("Bonjour, **Maxime**. Bonne journée."), " Bonne journée.")
        XCTAssertEqual(reply.append("late"), "")
        XCTAssertEqual(reply.finish("again"), "")
        var normalized = VoiceReplyText()
        _ = normalized.append("Bonjour  ")
        XCTAssertEqual(normalized.finish("Bonjour"), "")
        XCTAssertEqual(normalized.display, "Bonjour")
        var silent = VoiceReplyText()
        XCTAssertEqual(silent.finish("Réponse entière."), "Réponse entière.", "A reply without deltas is spoken from its final text")
        var resumed = VoiceReplyText(speaksDeltas: false, seed: "Début")
        XCTAssertEqual(resumed.append(" suite"), "")
        XCTAssertEqual(resumed.finish(""), "Début suite")
    }

    func testEchoGuardMatchesSpeakerBleedButNotRealInterjections() {
        let spoken = "Voici les rendez-vous de demain : réunion d’équipe à neuf heures, puis déjeuner avec Claire à midi."
        XCTAssertTrue(VoiceEcho.isEcho("réunion d'équipe à neuf heures", spoken: spoken))
        XCTAssertTrue(VoiceEcho.isEcho(spoken, spoken: spoken))
        XCTAssertFalse(VoiceEcho.isEcho("Attends, annule le déjeuner", spoken: spoken))
        XCTAssertFalse(VoiceEcho.isEcho("oui", spoken: "non merci"))
        XCTAssertFalse(VoiceEcho.isEcho("", spoken: spoken))
        XCTAssertEqual(VoiceEcho.ratio(Array("abcd")[...], Array("bcda")[...]), 0.75, accuracy: 0.0001)
    }
}
