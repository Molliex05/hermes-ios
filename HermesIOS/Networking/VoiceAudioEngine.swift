import Foundation
@preconcurrency import AVFoundation
import Accelerate

/// One duplex graph for the whole voice conversation. AVAudioSession, graph mutations,
/// conversion and file decoding stay off MainActor. The render taps only update bounded
/// PCM storage/meters; they never enqueue unbounded tasks or perform disk I/O.
final class VoiceAudioEngine: @unchecked Sendable {
    struct Snapshot: Sendable {
        var monitoring = false
        var capturing = false
        var inputPower = -160.0
        var outputLevel = 0.0
        var queuedSeconds = 0.0
        var outputID: UUID?
        var outputPending = false
        var failure: String?
        var playing: Bool { outputPending || queuedSeconds > 0.001 }
    }

    // AVAudioSession is process-wide: serialize old-view teardown and new-view startup too.
    private static let queue = DispatchQueue(label: "org.hermesios.voice-audio", qos: .userInitiated)
    nonisolated(unsafe) private static weak var sessionOwner: VoiceAudioEngine?
    private let state = VoiceAudioState()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var playbackID: UUID?
    private var pcmCarry: UInt8?
    private var audioFile: AVAudioFile?
    private var audioFileURL: URL?
    private var observers: [NSObjectProtocol] = []
    private var inputTapInstalled = false
    private var outputTapInstalled = false

    var snapshot: Snapshot { state.snapshot() }

    func prepare() async throws {
        let generation = state.generation
        try await onQueue {
            try self.state.validate(generation)
            try self.prepareOnQueue(generation: generation)
            try self.state.validate(generation)
        }
    }

    #if DEBUG
    /// The loopback UI fixture supplies synthetic microphone samples but exercises the
    /// real decoder/player. It never asks the simulator to open a physical microphone.
    func prepareFixture() async throws {
        let generation = state.generation
        try await onQueue {
            try self.state.validate(generation)
            if self.engine != nil { return }
            if let previous = Self.sessionOwner, previous !== self {
                previous.state.fail("Une autre conversation utilise l’audio.")
                previous.shutdownOnQueue(deactivate: false)
            }
            do {
                Self.sessionOwner = self
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
                let engine = AVAudioEngine(), player = AVAudioPlayerNode()
                guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1) else { throw RPCFailure("Format audio indisponible.") }
                engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
                let state = self.state
                engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in state.acceptOutput(buffer, generation: generation) }
                self.outputTapInstalled = true
                self.engine = engine; self.player = player; self.outputFormat = format
                engine.prepare(); try state.validate(generation); try engine.start()
                try state.validate(generation)
                state.setMonitoring(true)
                self.observeChanges(engine)
            } catch { self.shutdownOnQueue(deactivate: true); throw error }
        }
    }
    #endif

    func startCapture(includePreRoll: Bool) async throws {
        let generation = state.generation
        try await onQueue {
            try self.state.validate(generation)
            try self.prepareOnQueue(generation: generation)
            try self.state.validate(generation)
            try self.state.beginCapture(includePreRoll: includePreRoll)
        }
    }

    func finishCapture() async throws -> Data {
        let generation = state.generation
        return try await onQueue {
            try self.state.validate(generation)
            let captured = try self.state.finishCapture()
            // WAV encoding/copy occurs on this worker, never the UI or input render thread.
            return Self.wav(captured.samples, sampleRate: captured.sampleRate)
        }
    }

    func setInputMuted(_ muted: Bool) {
        state.setMuted(muted)
        Self.queue.async { [self] in if inputTapInstalled { engine?.inputNode.isVoiceProcessingInputMuted = state.isMuted } }
    }

    /// Reserve synchronously before awaiting setup, so stop() invalidates pending setup too.
    func reservePlayback(_ id: UUID) throws {
        try state.beginOutput(id)
        Self.queue.async { [self] in
            guard state.isOutput(id) else { return }
            stopOutputOnQueue()
            playbackID = id
        }
    }

    func preparePCM(sampleRate: Double, id: UUID) async throws {
        try await onQueue {
            try self.validateOutput(id)
            guard (8000...96000).contains(sampleRate),
                  let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
                  let output = self.outputFormat,
                  let converter = AVAudioConverter(from: format, to: output) else {
                throw RPCFailure("Format vocal Hermes non pris en charge.")
            }
            self.converter = converter
            self.state.setOutputPending(false, id: id)
        }
    }

    /// Split a bounded websocket frame before decoding: even a large frame cannot queue
    /// minutes of PCM. Backpressure also keeps stop/barge-in responsive between 200ms blocks.
    func enqueuePCM(_ data: Data, sampleRate: Double, id: UUID) async throws -> Bool {
        guard data.count <= 2 * 1024 * 1024 else { throw RPCFailure("Bloc vocal Hermes trop volumineux.") }
        let blockBytes = max(2, Int(sampleRate * 0.2) * 2)
        var offset = 0
        var scheduled = false
        while offset < data.count {
            try Task.checkCancellation()
            while state.queuedSeconds(id: id) > 3 {
                try Task.checkCancellation()
                guard state.isOutput(id) else { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(25))
            }
            let end = min(offset + blockBytes, data.count)
            let chunk = data.subdata(in: offset..<end)
            let produced = try await onQueue {
                try self.validateOutput(id)
                return try self.decodePCMOnQueue(chunk, id: id)
            }
            scheduled = scheduled || produced
            offset = end
        }
        return scheduled
    }

    func finishPCM(id: UUID) async throws {
        try await onQueue {
            try self.validateOutput(id)
            guard self.pcmCarry == nil else { throw RPCFailure("Le flux audio Hermes est incomplet.") }
            _ = try self.convertOnQueue(nil, end: true, id: id)
        }
    }

    func playFile(_ dataURL: String, id: UUID) async throws {
        try await onQueue {
            try self.validateOutput(id)
            // The REST fallback already arrives as a complete data URL. Bound both its
            // encoded size and decoded duration; decode/play only a few seconds at a time.
            guard dataURL.utf8.count <= 32 * 1024 * 1024,
                  let comma = dataURL.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
                  !data.isEmpty else { throw RPCFailure("Hermes n’a pas renvoyé d’audio lisible.") }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-speech-\(UUID().uuidString)")
            do {
                try data.write(to: url, options: .atomic)
                let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
                let format = file.processingFormat
                guard format.sampleRate > 0, file.length > 0,
                      Double(file.length) / format.sampleRate <= 600,
                      let output = self.outputFormat,
                      let converter = AVAudioConverter(from: format, to: output) else {
                    throw RPCFailure("Cet audio ne peut pas être lu en mode vocal.")
                }
                try self.validateOutput(id)
                self.audioFile = file; self.audioFileURL = url; self.converter = converter
                try self.fillFileOnQueue(id: id)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
    }

    func stopPlayback(id: UUID? = nil) {
        guard let stopped = state.cancelOutput(id: id) else { return }
        Self.queue.async { [self] in
            guard playbackID == stopped else { return }
            stopOutputOnQueue()
        }
    }

    func cleanup() {
        state.invalidate()
        Self.queue.async { [self] in shutdownOnQueue(deactivate: true) }
    }

    private func prepareOnQueue(generation: UUID) throws {
        if let engine {
            guard engine.isRunning else { throw RPCFailure("L’audio a été interrompu. Relancez la conversation vocale.") }
            return
        }
        if let previous = Self.sessionOwner, previous !== self {
            previous.state.fail("Une autre conversation utilise l’audio.")
            previous.shutdownOnQueue(deactivate: false)
        }
        let session = AVAudioSession.sharedInstance()
        do {
            Self.sessionOwner = self
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try? session.setPreferredSampleRate(48000)
            try? session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
            try state.validate(generation)
            let engine = AVAudioEngine(), player = AVAudioPlayerNode()
            // Both input and output use Apple's voice-processing I/O: the microphone
            // remains available while the speaker plays, with native echo cancellation.
            try engine.inputNode.setVoiceProcessingEnabled(true)
            engine.inputNode.isVoiceProcessingInputMuted = state.isMuted
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            guard (8000...96000).contains(inputFormat.sampleRate), inputFormat.channelCount > 0,
                  inputFormat.commonFormat == .pcmFormatFloat32,
                  let output = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1) else {
                throw RPCFailure("Aucune entrée audio compatible n’est disponible.")
            }
            state.configure(sampleRate: inputFormat.sampleRate, generation: generation)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: output)
            let renderState = state
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
                renderState.acceptInput(buffer, generation: generation)
            }
            inputTapInstalled = true
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                renderState.acceptOutput(buffer, generation: generation)
            }
            outputTapInstalled = true
            self.engine = engine; self.player = player; outputFormat = output
            engine.prepare()
            try state.validate(generation)
            try engine.start()
            try state.validate(generation)
            state.setMonitoring(true)
            observeChanges(engine)
        } catch {
            shutdownOnQueue(deactivate: true)
            throw error
        }
    }

    private func observeChanges(_ engine: AVAudioEngine) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            Self.queue.async { [weak self] in
                guard let self, let engine = self.engine, !engine.isRunning, self.state.snapshot().monitoring else { return }
                self.failOnQueue("La sortie audio a changé. Relancez la conversation vocale.")
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Self.queue.async { [weak self] in self?.failOnQueue("L’audio a été interrompu. Vous pouvez reprendre la conversation.") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            Self.queue.async { [weak self] in self?.failOnQueue("L’audio de l’iPhone a redémarré. Relancez la conversation vocale.") }
        })
    }

    private func failOnQueue(_ message: String) {
        guard state.snapshot().monitoring else { return }
        state.fail(message)
        shutdownOnQueue(deactivate: true)
    }

    private func shutdownOnQueue(deactivate: Bool) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        stopOutputOnQueue()
        if let engine {
            if inputTapInstalled { engine.inputNode.removeTap(onBus: 0) }
            if outputTapInstalled { engine.mainMixerNode.removeTap(onBus: 0) }
            engine.stop()
        }
        inputTapInstalled = false; outputTapInstalled = false
        engine = nil; player = nil; outputFormat = nil
        state.setMonitoring(false)
        if Self.sessionOwner === self {
            Self.sessionOwner = nil
            if deactivate { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        }
    }

    private func stopOutputOnQueue() {
        player?.stop()
        converter = nil; pcmCarry = nil; playbackID = nil
        audioFile = nil
        if let url = audioFileURL { try? FileManager.default.removeItem(at: url) }
        audioFileURL = nil
    }

    private func validateOutput(_ id: UUID) throws {
        guard state.isOutput(id), playbackID == id else { throw CancellationError() }
        guard engine?.isRunning == true else { throw RPCFailure("La lecture audio a été interrompue.") }
        if let failure = state.snapshot().failure { throw RPCFailure(failure) }
    }

    private func decodePCMOnQueue(_ data: Data, id: UUID) throws -> Bool {
        guard let converter else { throw RPCFailure("Le flux vocal n’est pas prêt.") }
        var bytes = Data()
        if let carry = pcmCarry { bytes.append(carry) }
        bytes.append(data)
        let frames = bytes.count / 2
        pcmCarry = bytes.count.isMultiple(of: 2) ? nil : bytes.last
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(frames)),
              let samples = input.floatChannelData?[0] else { return false }
        input.frameLength = AVAudioFrameCount(frames)
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for index in 0..<frames {
                let value = UInt16(raw[index * 2]) | UInt16(raw[index * 2 + 1]) << 8
                samples[index] = Float(Int16(bitPattern: value)) / 32768
            }
        }
        return try convertOnQueue(input, end: false, id: id)
    }

    @discardableResult private func convertOnQueue(_ input: AVAudioPCMBuffer?, end: Bool, id: UUID) throws -> Bool {
        guard let converter, let outputFormat else { throw RPCFailure("Le flux vocal n’est pas prêt.") }
        var supplied = false, scheduled = false
        // Input blocks are <=200ms. This bound is ample even for 8kHz → 48kHz,
        // and prevents a faulty converter from spinning indefinitely on the audio queue.
        for _ in 0..<16 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { throw RPCFailure("Mémoire audio insuffisante.") }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if !supplied, let input {
                    supplied = true; inputStatus.pointee = .haveData; return input
                }
                inputStatus.pointee = end ? .endOfStream : .noDataNow
                return nil
            }
            if let error { throw error }
            if status == .error { throw RPCFailure("La conversion de l’audio a échoué.") }
            if output.frameLength > 0 {
                try validateOutput(id)
                let duration = Double(output.frameLength) / outputFormat.sampleRate
                state.addQueued(duration, id: id)
                player?.scheduleBuffer(output, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    // Never stop the player from its render callback (Apple documents a deadlock).
                    Self.queue.async { [weak self] in self?.state.removeQueued(duration, id: id) }
                }
                if player?.isPlaying != true { player?.play() }
                scheduled = true
            }
            if status == .inputRanDry || status == .endOfStream { return scheduled }
        }
        throw RPCFailure("La conversion audio n’a pas pu se terminer.")
    }

    private func fillFileOnQueue(id: UUID) throws {
        try validateOutput(id)
        guard let file = audioFile else { return }
        while state.queuedSeconds(id: id) < 3 {
            let remaining = file.length - file.framePosition
            if remaining <= 0 {
                _ = try convertOnQueue(nil, end: true, id: id)
                audioFile = nil
                if let url = audioFileURL { try? FileManager.default.removeItem(at: url) }
                audioFileURL = nil
                state.setOutputPending(false, id: id)
                return
            }
            let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(file.processingFormat.sampleRate * 0.2)))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { throw RPCFailure("Mémoire audio insuffisante.") }
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { throw RPCFailure("Cet audio est incomplet.") }
            _ = try convertOnQueue(buffer, end: false, id: id)
        }
        Self.queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.state.isOutput(id), self.playbackID == id else { return }
            do { try self.fillFileOnQueue(id: id) }
            catch is CancellationError { }
            catch { self.failOnQueue(error.localizedDescription) }
        }
    }

    private func onQueue<T: Sendable>(_ action: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do { continuation.resume(returning: try action()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func wav(_ samples: [Int16], sampleRate: Double) -> Data {
        let bytes = samples.count * MemoryLayout<Int16>.size
        var data = Data(capacity: 44 + bytes)
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); integer(UInt32(36 + bytes))
        data.append(contentsOf: "WAVEfmt ".utf8); integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(sampleRate)); integer(UInt32(sampleRate) * 2); integer(UInt16(2)); integer(UInt16(16))
        data.append(contentsOf: "data".utf8); integer(UInt32(bytes))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

/// Render callbacks, the serial audio worker, and main-thread snapshots share only this
/// lock-protected state. Capture is capped at 120s; the pre-roll is a fixed 750ms ring.
private final class VoiceAudioState: @unchecked Sendable {
    private let lock = NSLock()
    private var token = UUID()
    private var status = VoiceAudioEngine.Snapshot()
    private var muted = false
    private var sampleRate = 48000.0
    private var samples: [Int16] = []
    private var preRoll: [Int16] = []
    private var ringIndex = 0
    private var ringCount = 0
    private var lastInput = 0.0
    private var lastOutput = 0.0

    var generation: UUID { lock.withLock { token } }
    var isMuted: Bool { lock.withLock { muted } }

    func validate(_ expected: UUID) throws {
        try lock.withLock {
            guard token == expected else { throw CancellationError() }
            if let failure = status.failure { throw RPCFailure(failure) }
        }
    }

    func configure(sampleRate: Double, generation: UUID) {
        lock.withLock {
            guard token == generation else { return }
            self.sampleRate = sampleRate
            preRoll = [Int16](repeating: 0, count: Int(sampleRate * 0.75))
            ringIndex = 0; ringCount = 0
        }
    }

    func setMonitoring(_ active: Bool) {
        lock.withLock {
            status.monitoring = active
            if !active { status.capturing = false; status.inputPower = -160; status.outputLevel = 0 }
        }
    }

    func snapshot() -> VoiceAudioEngine.Snapshot {
        lock.withLock {
            var value = status
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastInput > 0.3 || muted { value.inputPower = -160 }
            if now - lastOutput > 0.3 || status.outputID == nil { value.outputLevel = 0 }
            return value
        }
    }

    func beginCapture(includePreRoll: Bool) throws {
        // Reserve outside the render-state lock: starting a two-minute capture must
        // not stall an input callback while the allocator prepares its bounded storage.
        let capacity = lock.withLock { Int(sampleRate * 120) }
        var fresh: [Int16] = []
        fresh.reserveCapacity(capacity)
        try lock.withLock {
            guard status.monitoring, !muted else { throw RPCFailure("Le microphone est en pause.") }
            swap(&samples, &fresh)
            if includePreRoll, ringCount > 0 {
                let first = (ringIndex - ringCount + preRoll.count) % preRoll.count
                for offset in 0..<ringCount { samples.append(preRoll[(first + offset) % preRoll.count]) }
            }
            status.capturing = true
        }
    }

    func finishCapture() throws -> (samples: [Int16], sampleRate: Double) {
        try lock.withLock {
            guard status.capturing else { throw RPCFailure("Aucun enregistrement disponible.") }
            status.capturing = false
            let result = samples
            samples = []
            return (result, sampleRate)
        }
    }

    func setMuted(_ value: Bool) {
        lock.withLock {
            muted = value
            status.inputPower = -160
            if value {
                status.capturing = false; samples = []
                ringIndex = 0; ringCount = 0
            }
        }
    }

    func acceptInput(_ buffer: AVAudioPCMBuffer, generation: UUID) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var energy: Float = 0
        vDSP_svesq(channel, 1, &energy, vDSP_Length(buffer.frameLength))
        let rms = sqrt(Double(energy) / Double(buffer.frameLength))
        lock.withLock {
            guard token == generation, status.monitoring, !muted, !preRoll.isEmpty else { return }
            status.inputPower = rms > 0 ? max(-160, 20 * log10(rms)) : -160
            lastInput = ProcessInfo.processInfo.systemUptime
            let maximum = Int(sampleRate * 120)
            for index in 0..<Int(buffer.frameLength) {
                let raw = channel[index]
                let value = raw.isFinite ? Int16(max(-32768, min(32767, raw * 32767))) : 0
                preRoll[ringIndex] = value; ringIndex = (ringIndex + 1) % preRoll.count
                ringCount = min(preRoll.count, ringCount + 1)
                if status.capturing && samples.count < maximum { samples.append(value) }
            }
        }
    }

    func acceptOutput(_ buffer: AVAudioPCMBuffer, generation: UUID) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var energy: Float = 0
        vDSP_svesq(channel, 1, &energy, vDSP_Length(buffer.frameLength))
        let rms = sqrt(Double(energy) / Double(buffer.frameLength))
        lock.withLock {
            guard token == generation, status.monitoring, status.outputID != nil else { return }
            status.outputLevel = rms.isFinite ? min(1, rms * 5) : 0
            lastOutput = ProcessInfo.processInfo.systemUptime
        }
    }

    func beginOutput(_ id: UUID) throws {
        try lock.withLock {
            guard status.monitoring else { throw RPCFailure("Démarrez le microphone avant la conversation vocale.") }
            if let failure = status.failure { throw RPCFailure(failure) }
            status.outputID = id; status.queuedSeconds = 0; status.outputLevel = 0; status.outputPending = true
        }
    }
    func isOutput(_ id: UUID) -> Bool { lock.withLock { status.outputID == id && status.monitoring } }
    func queuedSeconds(id: UUID) -> Double { lock.withLock { status.outputID == id ? status.queuedSeconds : 0 } }
    func addQueued(_ duration: Double, id: UUID) { lock.withLock { if status.outputID == id { status.queuedSeconds += duration } } }
    func removeQueued(_ duration: Double, id: UUID) { lock.withLock { if status.outputID == id { status.queuedSeconds = max(0, status.queuedSeconds - duration) } } }
    func setOutputPending(_ pending: Bool, id: UUID) { lock.withLock { if status.outputID == id { status.outputPending = pending } } }
    func cancelOutput(id: UUID?) -> UUID? {
        lock.withLock {
            guard let existing = status.outputID, id == nil || id == existing else { return nil }
            status.outputID = nil; status.outputPending = false; status.queuedSeconds = 0; status.outputLevel = 0
            return existing
        }
    }
    func invalidate() {
        lock.withLock {
            token = UUID(); status = VoiceAudioEngine.Snapshot()
            samples = []; preRoll = []; ringCount = 0; ringIndex = 0; muted = false
        }
    }
    func fail(_ message: String) {
        lock.withLock {
            token = UUID(); status = VoiceAudioEngine.Snapshot(); status.failure = message
            samples = []; preRoll = []; ringCount = 0; ringIndex = 0
        }
    }
}
