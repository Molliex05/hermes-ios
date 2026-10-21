import AVFoundation
import Foundation

/// The iPhone's own French voice, used when the server's voice refuses a request (daily quota, outage), so a call never
/// goes silent. Renders to 16-bit mono PCM, the format the call's audio engine plays, so echo cancellation and barge-in
/// treat it like any other reply.
@MainActor
final class LocalSpeech {
    struct Rendered { let pcm: Data; let sampleRate: Double }

    private let synthesizer = AVSpeechSynthesizer()

    func render(_ text: String) async -> Rendered? {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return nil }
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = Self.bestFrenchVoice()
        let collector = Collector()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            collector.onFinish = { done.resume() }
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { collector.finish() } else { collector.append(pcm) }
            }
            // A synthesizer that never reports its end must not freeze the call.
            Task.detached { try? await Task.sleep(for: .seconds(30)); collector.finish() }
        }
        return collector.result()
    }

    /// Premium, then enhanced, then default quality; Québec French before France French.
    static func bestFrenchVoice() -> AVSpeechSynthesisVoice? {
        let french = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("fr") }
        return french.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: "fr-CA") ?? AVSpeechSynthesisVoice(language: "fr-FR")
    }

    private static func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
        (voice.language == "fr-CA" ? 1 : 0) + voice.quality.rawValue * 2
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var rate = 0.0
        private var finished = false
        var onFinish: (@Sendable () -> Void)?

        func append(_ buffer: AVAudioPCMBuffer) {
            let frames = Int(buffer.frameLength)
            var bytes = Data(capacity: frames * 2)
            if let samples = buffer.int16ChannelData?[0] {
                bytes.append(UnsafeBufferPointer(start: samples, count: frames))
            } else if let samples = buffer.floatChannelData?[0] {
                for index in 0..<frames {
                    let value = Int16(max(-1, min(1, samples[index])) * 32767)
                    bytes.append(UInt8(truncatingIfNeeded: value)); bytes.append(UInt8(truncatingIfNeeded: value >> 8))
                }
            } else { return }
            lock.lock(); defer { lock.unlock() }
            rate = buffer.format.sampleRate
            data.append(bytes)
        }

        func finish() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let callback = onFinish
            lock.unlock()
            callback?()
        }

        func result() -> Rendered? {
            lock.lock(); defer { lock.unlock() }
            return data.isEmpty || rate == 0 ? nil : Rendered(pcm: data, sampleRate: rate)
        }
    }
}
