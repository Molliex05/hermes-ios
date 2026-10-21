import Foundation
import AVFoundation
import OSLog
@preconcurrency import WebRTC

/// The gateway exchanges SDP; audio and events use one native WebRTC connection.
/// Session creation and provider authorization stay on the gateway.
@MainActor
final class VoiceLiveTransport: NSObject {
    var onEvent: ((JSONValue) -> Void)?
    private(set) var started = false
    private(set) var failure: String?
    private let factory = RTCPeerConnectionFactory()
    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var microphone: RTCAudioTrack?
    private var closed = false
    private var receipts = VoiceLiveReceipts()
    private let logger = Logger(subsystem: "org.hermesios.HermesIOS", category: "VoiceLive")
    private let clockStart = ProcessInfo.processInfo.systemUptime

    func mark(_ stage: String) {
        // Stage names and relative times only: never record transcripts, tool inputs or keys.
        logger.info("stage=\(stage, privacy: .public) elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - self.clockStart) * 1000))")
    }

    func append(_ kind: String, delegation: String?, content: String) async throws {
        let event = VoiceLiveProtocol.append(kind, delegation: delegation, content: content)
        try send(event)
        let id = event["event_id"].string
        while receipts.contains(id) {
            try check()
            try await Task.sleep(for: .milliseconds(50))
        }
        try check()
    }

    func drain() async throws {
        while !receipts.isEmpty {
            try check()
            try await Task.sleep(for: .milliseconds(50))
        }
        try check()
    }

    #if DEBUG
    /// Simulator protocol tests exercise the real peer without opening host hardware.
    /// The caller must restrict this to the disposable loopback test server.
    static func useSilentFixtureAudio() {
        let audio = RTCAudioSession.sharedInstance()
        audio.useManualAudio = true
        audio.isAudioEnabled = false
    }
    #endif

    func start(history: JSONValue, exchange: @MainActor (JSONValue) async throws -> JSONValue) async throws {
        let permission = await AVAudioApplication.requestRecordPermission()
        try check()
        guard permission else { throw RPCFailure("Autorisez le microphone dans les réglages de l’iPhone.") }
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration()
        let settings = RTCAudioSessionConfiguration.webRTC()
        settings.categoryOptions = [.defaultToSpeaker, .bluetoothCall]
        do { try audio.setConfiguration(settings) }
        catch { audio.unlockForConfiguration(); throw error }
        audio.unlockForConfiguration()
        // WebRTC owns audio-session activation/deactivation with its audio tracks.
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        guard let peer = factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else {
            throw RPCFailure("Impossible de préparer l’audio en direct.")
        }
        self.peer = peer
        let track = factory.audioTrack(withTrackId: "hermes-microphone")
        track.isEnabled = false // Open only after session.started and the latest mute choice.
        microphone = track
        peer.add(track, streamIds: ["hermes-voice"])
        let channel = peer.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration())
        guard let channel else { throw RPCFailure("Impossible de préparer GPT-Live.") }
        self.channel = channel; channel.delegate = self
        let offer: String = try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil)) { description, error in
                if let description { continuation.resume(returning: description.sdp) }
                else { continuation.resume(throwing: RPCFailure(error?.localizedDescription ?? "Offre audio indisponible.")) }
            }
        }
        try check()
        try await setDescription(offer, local: true)
        let deadline = Date().addingTimeInterval(10)
        while peer.iceGatheringState != .complete && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50)); try check()
        }
        guard let sdp = peer.localDescription?.sdp else { throw RPCFailure("Offre audio indisponible.") }
        let result = try await exchange(["sdp": .string(sdp), "history": history])
        try check()
        guard result["ok"].bool, !result["transport"]["sdp"].string.isEmpty else { throw RPCFailure("Hermes n’a pas pu ouvrir GPT-Live.") }
        try await setDescription(result["transport"]["sdp"].string, local: false)
        let readyDeadline = Date().addingTimeInterval(30)
        while !started {
            try check()
            guard Date() < readyDeadline else { throw RPCFailure("GPT-Live n’a pas démarré. Vérifiez la connexion et l’accès au modèle sur le serveur.") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func setDescription(_ sdp: String, local: Bool) async throws {
        try check()
        guard let peer else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let complete: @Sendable (Error?) -> Void = { error in
                if let error { continuation.resume(throwing: RPCFailure(error.localizedDescription)) }
                else { continuation.resume() }
            }
            if local { peer.setLocalDescription(RTCSessionDescription(type: .offer, sdp: sdp), completionHandler: complete) }
            else { peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp), completionHandler: complete) }
        }
        try check()
    }

    func send(_ event: JSONValue) throws {
        try check()
        guard started, let channel, channel.readyState == .open,
              channel.bufferedAmount < 256_000, channel.sendData(RTCDataBuffer(data: try event.data(), isBinary: false)) else {
            throw RPCFailure("La liaison vocale a été interrompue. La réponse d’Hermes reste dans le chat.")
        }
        receipts.sent(event, now: ProcessInfo.processInfo.systemUptime)
        if event["type"].string == "session.commentary.append" { mark("commentary_sent") }
    }
    func setMuted(_ muted: Bool) throws {
        microphone?.isEnabled = !muted
        if started { try send(["type": .string(muted ? "session.input_audio.mute" : "session.input_audio.unmute"), "event_id": .string(UUID().uuidString)]) }
    }
    func check() throws {
        try Task.checkCancellation()
        try receipts.check(now: ProcessInfo.processInfo.systemUptime)
        if let failure { throw RPCFailure(failure) }
        if closed { throw CancellationError() }
    }
    func close() {
        guard !closed else { return }
        // Stop capture/playback immediately, including when backgrounded before SDP returns.
        if started { try? send(["type": "session.close"]) }
        closed = true; started = false; microphone?.isEnabled = false
        channel?.delegate = nil; channel?.close(); channel = nil
        peer?.delegate = nil; peer?.close(); peer = nil; microphone = nil
        onEvent = nil
    }
    private func receive(_ data: Data) {
        guard !closed, data.count <= 256_000, let event = try? JSONValue.decode(data) else { return }
        receipts.receive(event)
        switch event["type"].string {
        case "session.started": started = true
        case "session.closed": failure = "La conversation GPT-Live est terminée. Réactivez le micro pour reprendre."
        case "session.commentary.appended": mark("commentary_received")
        case "session.output_transcript.delta": mark("spoken_transcript")
        case "session.delegation.created": mark("delegation_received")
        case "error":
            mark("provider_error")
            failure = receipts.failure
        default: break
        }
        onEvent?(event)
    }
}

extension VoiceLiveTransport: RTCDataChannelDelegate, RTCPeerConnectionDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let ended = dataChannel.readyState == .closed
        Task { @MainActor [weak self] in
            guard let self, !self.closed, ended else { return }
            self.failure = "La liaison GPT-Live a été fermée."
        }
    }
    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        Task { @MainActor [weak self] in self?.receive(data) }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCIceConnectionState) {
        let failed = state == .failed || state == .disconnected
        Task { @MainActor [weak self] in
            guard let self, !self.closed, failed else { return }
            self.failure = "La connexion audio GPT-Live a été interrompue."
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
