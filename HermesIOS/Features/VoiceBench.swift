import AVFoundation
import Observation
import UIKit

/// An automatic series of voice turns for measuring the pipeline: recorded sentences are played into the real
/// voice conversation (end-of-speech detection, live transcription, agent, speech) and every turn's timings go to
/// `Documents/voice-metrics.jsonl` through `VoiceMetrics`. Started from a launch argument (`--voice-bench`), never
/// from the UI. The replies are spoken aloud: run it with the volume low.
@MainActor @Observable
final class VoiceBench {
    struct Scenario { let id: String; let onlyFor: String? }

    /// Spoken sentences, grouped by what they ask of the agent. `onlyFor` limits Noriven questions to its agent.
    static let scenarios: [Scenario] = [
        // Control: no tool.
        .init(id: "blague", onlyFor: nil),
        // One quick tool.
        .init(id: "meteo", onlyFor: nil), .init(id: "pluie", onlyFor: nil), .init(id: "serveur", onlyFor: nil),
        // One heavier tool.
        .init(id: "memoire", onlyFor: nil), .init(id: "fichiers", onlyFor: nil), .init(id: "web", onlyFor: nil),
        // A tool, then reasoning over it.
        .init(id: "manteau", onlyFor: nil),
        // Noriven's data (MCP).
        .init(id: "noriven_mois", onlyFor: "noriven"), .init(id: "noriven_depenses", onlyFor: "noriven"),
        .init(id: "noriven_compare", onlyFor: "noriven"),
        // Two tools in one question.
        .init(id: "noriven_chaine", onlyFor: "noriven")
    ]

    private static let chunk = 0.02
    private(set) var status = "Prêt"

    /// `--voice-bench [--bench-profile name] [--bench-repeats n] [--bench-hold] [--bench-only id,id]`
    static func autorun(_ app: AppModel) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--voice-bench") else { return }
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } }
        let bench = VoiceBench()
        VoiceMetrics.shared.silent = arguments.contains("--bench-silent")
        VoiceMetrics.shared.tag = value("--bench-tag") ?? ""
        VoiceMetrics.shared.label = ""
        await bench.run(app: app, profile: value("--bench-profile"), repeats: Int(value("--bench-repeats") ?? "") ?? 3,
                        holding: arguments.contains("--bench-hold"), only: value("--bench-only")?.split(separator: ",").map(String.init))
    }

    func run(app: AppModel, profile: String?, repeats: Int, holding: Bool, only: [String]?) async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let metrics = VoiceMetrics.shared
        metrics.holdingLineEnabled = holding
        let deadline = Date().addingTimeInterval(60)
        while app.state != .connected, Date() < deadline { try? await Task.sleep(for: .milliseconds(250)) }
        guard app.state == .connected else { await finish("Échec : pas de connexion à Hermes."); return }
        if let profile, profile != app.profile { await app.changeProfile(profile) }
        let name = app.profile
        let conversation = VoiceConversation(app)
        conversation.start(standardMode: true)
        guard await wait(timeout: 40, { conversation.phase == .listening }) else { await finish("Échec : la conversation vocale ne démarre pas."); conversation.pause(); return }
        conversation.audio.engine.setBenchInput(true)
        let rate = conversation.audio.engine.inputSampleRate
        let list = Self.scenarios.filter { ($0.onlyFor == nil || $0.onlyFor == name) && (only == nil || only!.contains($0.id)) }
        var done = 0
        let total = list.count * repeats
        for round in 1...max(1, repeats) {
            for scenario in list {
                done += 1
                status = "\(done)/\(total) · \(scenario.id)"
                metrics.label = "\(scenario.id)"
                app.newChat()
                try? await Task.sleep(for: .milliseconds(600))
                guard let speech = Self.chunks(for: scenario.id, rate: rate) else { metrics.recordFailure(label: scenario.id, reason: "missing-audio", profile: name); continue }
                let before = metrics.completedTurns
                let ok = await play(speech, into: conversation, until: { metrics.completedTurns > before }, timeout: 120)
                if !ok { metrics.recordFailure(label: scenario.id, reason: "timeout-round-\(round)", profile: name, detail: conversation.benchState()) }
                // Quiet time so the next turn starts from listening, with the previous reply fully played.
                _ = await play([], into: conversation, until: { conversation.phase == .listening }, timeout: 15)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        conversation.audio.engine.setBenchInput(false)
        conversation.pause()
        metrics.holdingLineEnabled = false; metrics.label = ""; metrics.silent = false; metrics.tag = ""
        await finish("Terminé : \(done) tours.")
    }

    private func finish(_ message: String) async {
        status = message
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("voice-bench-status.txt")
        try? "\(ISO8601DateFormatter().string(from: Date())) \(message)\n".write(to: url ?? URL(fileURLWithPath: "/dev/null"), atomically: true, encoding: .utf8)
    }

    private func wait(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if condition() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
        return condition()
    }

    /// Feeds 20 ms buffers in real time: the speech, a lead-in of silence before, then silence until `until` holds.
    private func play(_ speech: [AVAudioPCMBuffer], into conversation: VoiceConversation, until: () -> Bool, timeout: Double) async -> Bool {
        guard let rate = speech.first?.format.sampleRate ?? Optional(conversation.audio.engine.inputSampleRate) else { return false }
        let silence = Self.silence(rate: rate)
        let start = ContinuousClock.now
        var index = 0
        let limit = Int(timeout / Self.chunk)
        while index < limit + speech.count {
            let buffer = index < speech.count ? speech[index] : silence
            conversation.audio.engine.injectBench(buffer)
            index += 1
            try? await Task.sleep(until: start + .milliseconds(20 * index), clock: .continuous)
            if index >= speech.count, until() { return true }
        }
        return until()
    }

    private static func silence(rate: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * chunk))!
        buffer.frameLength = buffer.frameCapacity
        return buffer
    }

    /// 0.5 s of silence, the recorded sentence, then nothing (the caller keeps feeding silence).
    private static func chunks(for id: String, rate: Double) -> [AVAudioPCMBuffer]? {
        guard let url = Bundle.main.url(forResource: id, withExtension: "wav"), let file = try? AVAudioFile(forReading: url),
              let target = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: source)) != nil else { return nil }
        let capacity = AVAudioFrameCount(Double(source.frameLength) * rate / file.processingFormat.sampleRate) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var failure: NSError?
        converter.convert(to: converted, error: &failure) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true; status.pointee = .haveData; return source
        }
        guard failure == nil, let samples = converted.floatChannelData?[0] else { return nil }
        let per = Int(rate * chunk)
        var out = Array(repeating: silence(rate: rate), count: Int(0.5 / chunk))
        var offset = 0
        while offset < Int(converted.frameLength) {
            let count = min(per, Int(converted.frameLength) - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(per)) else { return nil }
            buffer.frameLength = AVAudioFrameCount(per)
            let destination = buffer.floatChannelData![0]
            for i in 0..<per { destination[i] = i < count ? samples[offset + i] : 0 }
            out.append(buffer)
            offset += count
        }
        return out
    }
}
