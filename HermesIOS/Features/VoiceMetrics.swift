import Foundation

/// Per-turn timing of the voice pipeline, written as one JSON line per turn to `Documents/voice-metrics.jsonl`
/// (readable from a Mac with `devicectl device copy from`). Numbers only: no audio, no words, no replies.
/// A turn runs from the first sound of the person speaking to the end of the spoken reply.
@MainActor
final class VoiceMetrics {
    static let shared = VoiceMetrics()

    enum Stage: String, CaseIterable {
        /// Person: first sound / decision that they stopped.
        case speechStart, endpoint
        /// Live transcription: first partial / final text.
        case sttPartial, sttFinal
        /// `prompt.submit` sent / acknowledged by Hermes.
        case submitSent, submitAck
        /// Agent: first text delta, and first text handed to the speech socket.
        case firstDelta, firstTextToTTS
        /// The local « Je regarde ça » started playing.
        case filler
        /// Speech: first PCM from the server, first buffer scheduled on the speaker.
        case firstPCM, playbackStart
        /// Reply text complete, and the last sample played.
        case replyComplete, playbackEnd
    }

    private struct Turn {
        var marks: [Stage: Double] = [:]
        var meta: [String: Double] = [:]
        var text: [String: String] = [:]
        let wall = Date()
    }

    /// The recorded « Je regarde ça » fillers. Off: they were generic and often out of place in the conversation.
    /// Turned on only by the bench (`--bench-hold`) to measure what they hide.
    var holdingLineEnabled = false
    /// Bench without speech synthesis: the turn ends when the reply text is complete (quiet, and no TTS quota used).
    var silent = false
    /// Free label attached to every turn (the bench sets the scenario here).
    var label = ""
    /// Names the variant under test (model, setting) so one file can hold several runs.
    var tag = ""

    private var turn: Turn?
    /// Turns written so far this run (the bench waits for it to grow).
    private(set) var completedTurns = 0
    private var url: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("voice-metrics.jsonl")
    }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// A new utterance. Speech resumed before submission belongs to the same turn, so an open turn is kept.
    func utteranceStarted(barge: Bool) {
        if turn == nil || turn?.marks[.submitSent] != nil { turn = Turn() }
        turn?.meta["barge"] = barge ? 1 : 0
        if turn?.marks[.speechStart] == nil { turn?.marks[.speechStart] = Self.now() }
    }

    /// `overwrite` for stages that can happen again within one turn (speech resumed: the last endpoint counts).
    func mark(_ stage: Stage, overwrite: Bool = false) {
        guard turn != nil, overwrite || turn?.marks[stage] == nil else { return }
        turn?.marks[stage] = Self.now()
    }

    func note(_ key: String, _ value: Double) { turn?.meta[key] = value }
    func note(_ key: String, text value: String) { turn?.text[key] = value }

    /// Drops the turn without writing it (echo, cancelled, interrupted before any sound).
    func discard() { turn = nil }

    /// Writes the turn if it produced sound, then forgets it.
    func finish(profile: String) {
        guard var finished = turn else { return }
        turn = nil
        guard finished.marks[.firstPCM] != nil else { return }
        func gap(_ from: Stage, _ to: Stage) -> Double? {
            guard let a = finished.marks[from], let b = finished.marks[to] else { return nil }
            return ((b - a) * 1000).rounded()
        }
        var line: [String: Any] = ["ts": ISO8601DateFormatter().string(from: finished.wall), "profile": profile, "label": label,
                                   "tag": tag, "holding": holdingLineEnabled]
        let pairs: [(String, Stage, Stage)] = [
            ("speechMs", .speechStart, .endpoint),
            ("sttPartialAfterStartMs", .speechStart, .sttPartial),
            ("sttFinalAfterEndMs", .endpoint, .sttFinal),
            ("submitMs", .submitSent, .submitAck),
            ("ackToFirstDeltaMs", .submitAck, .firstDelta),
            ("firstDeltaToTTSMs", .firstDelta, .firstTextToTTS),
            ("ttsTextToPCMMs", .firstTextToTTS, .firstPCM),
            ("pcmToPlaybackMs", .firstPCM, .playbackStart),
            ("ackToFillerMs", .submitAck, .filler),
            ("endToFirstWordMs", .endpoint, .firstDelta),
            ("endToReplyCompleteMs", .endpoint, .replyComplete),
            ("endToFirstSoundMs", .endpoint, .playbackStart),
            ("finalToFirstSoundMs", .sttFinal, .playbackStart),
            ("replyMs", .firstDelta, .replyComplete),
            ("speakingMs", .playbackStart, .playbackEnd)
        ]
        for (name, from, to) in pairs { if let value = gap(from, to) { line[name] = value } }
        for (key, value) in finished.meta { line[key] = value }
        for (key, value) in finished.text { line[key] = value }
        write(line)
        completedTurns += 1
        finished.marks = [:]
    }

    /// A scenario that never produced a spoken reply: kept in the file so the report can count it.
    func recordFailure(label: String, reason: String, profile: String, detail: String = "") {
        write(["ts": ISO8601DateFormatter().string(from: Date()), "profile": profile, "label": label, "tag": tag, "failed": reason, "state": detail])
    }

    private func write(_ line: [String: Any]) {
        guard let url, let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        var text = String(decoding: data, as: UTF8.self) + "\n"
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            // Bounded: the last 1500 turns are plenty.
            let lines = existing.split(separator: "\n", omittingEmptySubsequences: true)
            text = (lines.count >= 1500 ? lines.suffix(1499).joined(separator: "\n") : existing.trimmingCharacters(in: .newlines)) + "\n" + text
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
