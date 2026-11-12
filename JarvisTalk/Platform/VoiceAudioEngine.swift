import AVFoundation
import os
import JarvisCore
import JarvisModel

enum VoiceAudioError: LocalizedError {
    case noInput
    var errorDescription: String? { "No microphone input is available right now." }
}

/// Microphone in, speech out, robust against interruptions and route changes, and alive with the screen locked.
///
/// Wire format (unchanged, same as the web page):
///   up:   16 kHz, 16-bit little-endian mono PCM, 40 ms frames (1280 bytes)
///   down: 24 kHz, 16-bit little-endian mono PCM chunks arriving faster than real time
///
/// The audio session is `.playAndRecord` + `.voiceChat` (hardware echo cancellation and noise suppression through
/// the voice-processing I/O unit) and the app declares the `audio` background mode, which is what keeps this running
/// on the lock screen. The mic is converted to 16 kHz with `StreamResampler` (tested on Linux), not AVAudioConverter,
/// so a multi-channel voice-processing format can never break the conversion.
final class VoiceAudioEngine: VoiceAudio, @unchecked Sendable {
    var onMicFrame: (@Sendable (Data, Float) -> Void)?
    var onOutputLevel: (@Sendable (Float) -> Void)?
    var onPlaybackActive: (@Sendable (Bool) -> Void)?
    var onEvent: (@Sendable (VoiceAudioEvent) -> Void)?

    private let log = Logger(subsystem: "com.jarvis.talk", category: "audio")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// A silent looping buffer: keeps the output running so iOS treats the call as "playing audio" and sends the lock-screen
    /// and earbud buttons (mute / unmute) to this app even when Jarvis is not speaking.
    private let keeper = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private let queue = DispatchQueue(label: "jarvis.audio.play")
    private let micQueue = DispatchQueue(label: "jarvis.audio.mic", qos: .userInteractive)

    // touched only on `micQueue`
    private var resampler = StreamResampler(inRate: 48_000, outRate: 16_000)
    private var chunker = FrameChunker()
    // touched only on `queue`
    private var aligner = SampleAligner()
    private var outstanding = 0
    private var generation = 0

    private let stateLock = NSLock()
    private var wantRunning = false
    private var observing = false
    private var playerAttached = false
    private var restartScheduled = false
    private var observers: [NSObjectProtocol] = []

    var routeName: String {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outs.first?.portName ?? "iPhone"
    }

    // MARK: start / stop

    func start() throws {
        stateLock.lock(); let already = wantRunning; wantRunning = true; stateLock.unlock()
        if already { return }
        do { try setUp() } catch { setWanted(false); throw error }
        observe()
    }

    func stop() {
        setWanted(false)
        tearDown()
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { log.debug("session deactivate: \(error.localizedDescription, privacy: .public)") }
    }

    func restart() throws {
        guard isWanted else { return }
        tearDown()
        try setUp()
    }

    private var isWanted: Bool { stateLock.lock(); defer { stateLock.unlock() }; return wantRunning }
    private func setWanted(_ v: Bool) { stateLock.lock(); wantRunning = v; stateLock.unlock() }

    private func setUp() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        // Voice processing (echo cancellation, noise suppression) has to be switched on before the graph is built.
        if !engine.inputNode.isVoiceProcessingEnabled { try engine.inputNode.setVoiceProcessingEnabled(true) }

        if !playerAttached { engine.attach(player); engine.attach(keeper); playerAttached = true }
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        engine.connect(keeper, to: engine.mainMixerNode, format: playFormat)

        let inFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw VoiceAudioError.noInput }
        let rate = inFormat.sampleRate
        micQueue.sync { resampler = StreamResampler(inRate: rate, outRate: 16_000); chunker.reset() }
        queue.sync { aligner.reset(); outstanding = 0; generation += 1 }

        engine.inputNode.removeTap(onBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.handleMic(buffer)
        }
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            self?.handleOutput(buffer)
        }
        engine.prepare()
        try engine.start()
        player.play()
        if let silence = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: 24_000) {
            silence.frameLength = 24_000
            if let d = silence.floatChannelData?[0] { memset(d, 0, 24_000 * MemoryLayout<Float>.size) }   // one second of zeros
            keeper.stop()
            keeper.scheduleBuffer(silence, at: nil, options: .loops, completionHandler: nil)
            keeper.play()
        }
        log.info("audio started: input \(Int(rate)) Hz, route \(self.routeName, privacy: .public)")
    }

    private func tearDown() {
        engine.inputNode.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        player.stop()
        keeper.stop()
        engine.stop()
        queue.sync { generation += 1; outstanding = 0; aligner.reset() }
        onPlaybackActive?(false)
    }

    // MARK: microphone

    private func handleMic(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channel, count: n))
        micQueue.async { [weak self] in
            guard let self = self, self.isWanted else { return }
            let out = self.resampler.process(samples)
            guard !out.isEmpty else { return }
            let int16 = PCM.int16(fromFloats: out)
            for frame in self.chunker.push(PCM.data(from: int16)) {
                self.onMicFrame?(frame, PCM.rms(frame))
            }
        }
    }

    private func handleOutput(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n { sum += channel[i] * channel[i] }
        onOutputLevel?((sum / Float(n)).squareRoot())
    }

    // MARK: speech out

    func play(_ pcm: Data) {
        queue.async { [weak self] in
            guard let self = self, self.isWanted else { return }
            let samples = self.aligner.push(pcm)
            guard !samples.isEmpty,
                  let buffer = AVAudioPCMBuffer(pcmFormat: self.playFormat, frameCapacity: AVAudioFrameCount(samples.count)),
                  let dst = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            for i in 0..<samples.count { dst[i] = Float(samples[i]) / 32768 }
            if self.outstanding == 0 { self.onPlaybackActive?(true) }
            self.outstanding += 1
            let g = self.generation
            if !self.player.isPlaying, self.engine.isRunning { self.player.play() }
            self.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async {
                    guard let self = self, g == self.generation else { return }
                    self.outstanding = max(0, self.outstanding - 1)
                    if self.outstanding == 0 { self.onPlaybackActive?(false) }
                }
            }
        }
    }

    /// Drop everything queued, right now (the server heard the owner speak: `voice_stop`).
    func cutPlayback() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.generation += 1
            self.outstanding = 0
            self.aligner.reset()
            self.player.volume = 1
            self.player.stop()
            if self.engine.isRunning { self.player.play() }
            self.onPlaybackActive?(false)
        }
    }

    func setDucked(_ on: Bool) { player.volume = on ? DuckDetector.gain : 1.0 }

    // MARK: interruptions, route changes, resets

    /// Block-based observers (this class is not an NSObject, so selector based ones would not work).
    private func observe() {
        guard !observing else { return }
        observing = true
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] n in self?.interruption(n) })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] _ in self?.routeChange() })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in self?.mediaReset() })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in self?.engineConfigChanged() })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    private func interruption(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            log.info("audio interruption began")
            onEvent?(.interruptionBegan)
        case .ended:
            let optRaw = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let should = AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume)
            log.info("audio interruption ended, shouldResume=\(should)")
            onEvent?(.interruptionEnded(shouldResume: should))
        @unknown default: break
        }
    }

    private func routeChange() {
        // headphones unplugged / Bluetooth gone: the engine keeps running on the new route; a configuration
        // change notification follows when the hardware format changed
        onEvent?(.routeChanged(routeName))
    }

    private func mediaReset() {
        log.error("media services were reset")
        onEvent?(.mediaServicesReset)      // every audio object is invalid: the call model rebuilds everything
    }

    private func engineConfigChanged() {
        guard isWanted else { return }
        stateLock.lock(); let scheduled = restartScheduled; restartScheduled = true; stateLock.unlock()
        if scheduled { return }
        // coalesce the burst of notifications a route change produces, then let the call model restart us
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock(); self.restartScheduled = false; self.stateLock.unlock()
            self.onEvent?(.engineStopped)
        }
    }
}
