import Accelerate
import AVFoundation
#if os(iOS)
import UIKit
#endif
import Observation

struct RecordingResult {
    let fileName: String
    let duration: TimeInterval
    let channelCount: Int
    let inputName: String
    /// True when an external microphone delivers two separate channels (e.g. DJI Mic receiver in stereo mode).
    let isSplitStereo: Bool
    /// The right channel is the Mac's sound (the other side of a call), the left one the microphone.
    var includesSystemAudio = false
}

enum RecorderError: LocalizedError {
    case noInput

    var errorDescription: String? {
        switch self {
        case .noInput: "No microphone available."
        }
    }
}

/// Records the current audio input to an AAC file, keeping up to two channels.
@MainActor
@Observable
final class AudioRecorder {
    private(set) var isRecording = false
    private(set) var isPaused = false
    /// A call (or Siri, an alarm) has the microphone: paused until it is over.
    private(set) var isPausedForCall = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var levels: [Float] = [0]
    private(set) var inputName = ""
    private(set) var channelCount = 1
    private(set) var isExternal = false
    private(set) var isSplitStereo = false
    /// The Mac's sound is recorded on the right channel (see `secondChannel`).
    private(set) var includesSystemAudio = false
    /// Why the Mac's sound could not be included; the recording then has the microphone alone.
    private(set) var secondChannelError: String?

    @ObservationIgnored var onInterrupted: (() -> Void)?
    /// A meeting pauses for a call and goes on after it. Without this (dictation) a call ends the recording.
    @ObservationIgnored var pausesForCalls = false
    /// The recorder paused or resumed on its own.
    @ObservationIgnored var onPauseChanged: (() -> Void)?
    /// Whether the recording was running when the call came: one paused by hand stays paused.
    @ObservationIgnored private var resumeAfterCall = false
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    /// Receives a mono copy of every microphone buffer (for live transcription).
    @ObservationIgnored var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// With the Mac's sound (`secondChannel`): the microphone (left) and the Mac's sound (right) as two mono buffers,
    /// for a live transcript per side (`LiveTranscriber`). Called next to `onBuffer`, only while both are recorded.
    @ObservationIgnored var onChannelBuffers: (@Sendable (_ microphone: AVAudioPCMBuffer, _ system: AVAudioPCMBuffer) -> Void)?
    /// Recorded on the right channel next to the microphone (mixed to mono on the left). Set before `start`.
    @ObservationIgnored var secondChannel: (any SecondChannelSource)?

    /// Created per recording: an engine built earlier keeps the input format of the old route.
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var recordingFormat: AVAudioFormat?
    @ObservationIgnored private var writer: TapWriter?
    /// The file being written, unreadable until the recording stops.
    @ObservationIgnored private(set) var fileName: String?
    /// When the clock last started; nil while paused.
    @ObservationIgnored private var startDate: Date?
    /// Recorded time before the last pause.
    @ObservationIgnored private var recordedBeforePause: TimeInterval = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        // A second start would leave the first engine running with nobody to stop it.
        guard !isRecording else { return }
        do {
            try begin()
        } catch {
            // Nothing half started stays behind: no tap, no open file, no active session.
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            engine = nil
            secondChannel?.stop()
            writer?.close()
            writer = nil
            AudioStore.delete(fileName)
            fileName = nil
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            throw error
        }
    }

    private func begin() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)
        // Prefer an external microphone (DJI receiver over USB-C/Lightning, headset, Bluetooth)
        // over the built-in one; iOS does not always switch to it on its own.
        if let external = session.availableInputs?.first(where: { Self.isExternalPort($0) }) {
            try? session.setPreferredInput(external)
        } else {
            try? session.setPreferredInput(nil)
        }
        let port = session.currentRoute.inputs.first
        isExternal = port.map { Self.isExternalPort($0) } ?? false
        if isExternal, session.maximumInputNumberOfChannels >= 2 {
            try? session.setPreferredInputNumberOfChannels(2)
        }
        inputName = port?.portName ?? "Microphone"
        #else
        inputName = "Microphone"
        #endif

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else { throw RecorderError.noInput }

        recordingFormat = hwFormat
        var fifo: SampleFIFO?
        secondChannelError = nil
        if let source = secondChannel {
            do {
                try source.start(sampleRate: hwFormat.sampleRate)
                fifo = source.fifo
            } catch {
                secondChannelError = error.localizedDescription
            }
        }
        includesSystemAudio = fifo != nil
        if includesSystemAudio { inputName = SystemAudioMix.inputName }
        let channels = includesSystemAudio ? 2 : min(Int(hwFormat.channelCount), 2)
        channelCount = channels
        isSplitStereo = includesSystemAudio || (isExternal && channels == 2)
        levels = Array(repeating: 0, count: channels)

        let name = AudioStore.newFileName()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: hwFormat.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(
            forWriting: AudioStore.localURL(for: name),
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let writer = TapWriter(file: file, channels: channels) { [weak self] in
            Task { @MainActor in if self?.isRecording == true { self?.onInterrupted?() } }
        }
        self.writer = writer
        self.fileName = name

        input.installTap(
            onBus: 0, bufferSize: 4096, format: hwFormat,
            block: Self.makeTapBlock(writer: writer, second: fifo, onBuffer: onBuffer, onChannels: fifo == nil ? nil : onChannelBuffers) { [weak self] levels in
                Task { @MainActor in if self?.isPaused == false { self?.levels = levels } }
            }
        )
        engine.prepare()
        try engine.start()

        isRecording = true
        isPaused = false
        recordedBeforePause = 0
        startDate = Date()
        elapsed = 0
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.elapsed = self.recordedTime
            }
        }
        observeInterruptions()
    }

    #if DEBUG
    /// The Mac's `replay-live`: a recording of the Mac's sound with the microphone, but nothing is opened; the
    /// returned function takes the replayed stereo buffers (left the microphone, right the Mac's sound, at
    /// `sampleRate`) in place of the tap's, and handles them as the tap does (file, levels, `onBuffer`,
    /// `onChannelBuffers`). The file is then marked as such a recording, so it is processed like one after Stop.
    func startReplay(sampleRate: Double) throws -> @Sendable (AVAudioPCMBuffer) -> Void {
        guard !isRecording else { throw RecorderError.noInput }
        inputName = SystemAudioMix.inputName
        isExternal = false
        includesSystemAudio = true
        secondChannelError = nil
        channelCount = 2
        isSplitStereo = true
        levels = [0, 0]
        let name = AudioStore.newFileName()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(forWriting: AudioStore.localURL(for: name), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let writer = TapWriter(file: file, channels: 2) { [weak self] in
            Task { @MainActor in if self?.isRecording == true { self?.onInterrupted?() } }
        }
        self.writer = writer
        fileName = name
        let tap = Self.makeTapBlock(writer: writer, second: nil, onBuffer: onBuffer, onChannels: onChannelBuffers) { [weak self] levels in
            Task { @MainActor in if self?.isPaused == false { self?.levels = levels } }
        }
        isRecording = true
        isPaused = false
        isReplaying = true
        recordedBeforePause = 0
        startDate = Date()
        elapsed = 0
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.elapsed = self.recordedTime
            }
        }
        return { buffer in tap(buffer, AVAudioTime(hostTime: mach_absolute_time())) }
    }

    /// Recording a replay (`startReplay`): no engine to restart on resume.
    @ObservationIgnored private var isReplaying = false
    #endif

    /// The microphone keeps running and its sound is dropped: iOS may suspend an app in the background that
    /// stops recording, and would not let it start again from there. So the file has no gap and no silence.
    func pause() {
        guard isRecording, !isPaused else { return }
        writer?.isPaused = true
        recordedBeforePause = recordedTime
        startDate = nil
        elapsed = recordedBeforePause
        isPaused = true
        levels = Array(repeating: 0, count: channelCount)
    }

    func resume() {
        guard isRecording, isPaused, !isPausedForCall else { return }
        // After a call that could not restart the microphone on its own.
        #if DEBUG
        let restarted = isReplaying || restartEngine()
        #else
        let restarted = restartEngine()
        #endif
        guard restarted else { return }
        resumeAfterCall = false
        startDate = Date()
        isPaused = false
        writer?.isPaused = false
    }

    private var recordedTime: TimeInterval {
        recordedBeforePause + (startDate.map { Date().timeIntervalSince($0) } ?? 0)
    }

    @discardableResult
    func stop() -> RecordingResult? {
        guard isRecording, let fileName else { return nil }
        ticker?.cancel()
        restartTask?.cancel()
        isPausedForCall = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        secondChannel?.stop()
        writer?.close()
        writer = nil
        isRecording = false
        #if DEBUG
        isReplaying = false
        #endif
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        let duration = recordedTime
        isPaused = false
        self.fileName = nil
        return RecordingResult(
            fileName: fileName,
            duration: duration,
            channelCount: channelCount,
            inputName: inputName,
            isSplitStereo: isSplitStereo,
            includesSystemAudio: includesSystemAudio
        )
    }

    func cancel() {
        if let result = stop() {
            AudioStore.delete(result.fileName)
        }
    }

    /// The engine stops on route or configuration changes. Keep recording when the input still has the
    /// same format (the tap stays installed); only end the recording when the microphone really changed.
    private func handleConfigurationChange() {
        // A call changes the route and the format; what counts is the state after it.
        guard isRecording, !isPausedForCall, let engine, let recordingFormat else { return }
        let current = engine.inputNode.outputFormat(forBus: 0)
        guard current.sampleRate == recordingFormat.sampleRate,
              current.channelCount == recordingFormat.channelCount else {
            onInterrupted?()
            return
        }
        if engine.isRunning { return }
        engine.prepare()
        do { try engine.start() } catch { onInterrupted?() }
    }

    private func observeInterruptions() {
        let center = NotificationCenter.default
        // The engine stops when the route changes (e.g. the DJI receiver is unplugged).
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        })
        #if os(iOS)
        // The audio system was restarted: the engine is dead and records nothing while the clock would run on.
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.isRecording == true { self?.onInterrupted?() }
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated {
                if type == .began {
                    self?.interruptionBegan()
                } else if type == .ended {
                    self?.restartAfterCall()
                }
            }
        })
        // The end of a call is not always reported, and iOS may refuse the microphone to an app in the background.
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restartAfterCall()
            }
        })
        #endif
    }

    #if os(iOS)
    private func interruptionBegan() {
        guard isRecording else { return }
        guard pausesForCalls else {
            onInterrupted?()
            return
        }
        restartTask?.cancel()
        // A second report of the same call must not take the first one's decision back.
        if !isPausedForCall { resumeAfterCall = !isPaused }
        pause()
        isPausedForCall = true
        onPauseChanged?()
    }

    /// The microphone can take a moment to come back. If it stays away the recording stays paused and "Resume"
    /// or the return to the app tries again; nothing recorded so far is at risk.
    private func restartAfterCall() {
        guard isRecording, isPausedForCall || resumeAfterCall else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            for _ in 0..<8 {
                guard let self, !Task.isCancelled, self.isRecording else { return }
                if self.restartEngine() {
                    guard self.isRecording else { return }
                    self.isPausedForCall = false
                    if self.resumeAfterCall { self.resume() }
                    self.onPauseChanged?()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled, self.isRecording else { return }
            self.isPausedForCall = false
            self.onPauseChanged?()
        }
    }
    #endif

    /// True when the microphone runs. A different format after a call cannot go into the same file: the recording
    /// ends there with everything it has, and can be continued from the meeting.
    private func restartEngine() -> Bool {
        guard let engine, let recordingFormat else { return false }
        if engine.isRunning { return true }
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let current = engine.inputNode.outputFormat(forBus: 0)
            guard current.sampleRate == recordingFormat.sampleRate, current.channelCount == recordingFormat.channelCount else {
                onInterrupted?()
                return false
            }
            engine.prepare()
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    #if os(iOS)
    private static func isExternalPort(_ port: AVAudioSessionPortDescription) -> Bool {
        switch port.portType {
        case .builtInMic: false
        default: true
        }
    }
    #endif

    private nonisolated static func makeTapBlock(
        writer: TapWriter,
        second: SampleFIFO?,
        onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?,
        onChannels: (@Sendable (AVAudioPCMBuffer, AVAudioPCMBuffer) -> Void)?,
        onLevels: @escaping @Sendable ([Float]) -> Void
    ) -> AVAudioNodeTapBlock {
        { microphone, _ in
            guard !writer.isPaused else { return }
            // With the Mac's sound: the microphone on the left, the sound on the right.
            guard let buffer = second.map({ SystemAudioMix.stereo(microphone: microphone, fifo: $0) }) ?? microphone else { return }
            writer.write(buffer)
            onLevels(levelsOf(buffer, channels: writer.channels))
            if let onBuffer, let mono = monoCopy(of: buffer, channels: writer.channels) {
                onBuffer(mono)
            }
            if let onChannels, let left = channelCopy(of: buffer, channel: 0), let right = channelCopy(of: buffer, channel: 1) {
                onChannels(left, right)
            }
        }
    }

    /// One channel of `buffer` as a mono buffer of its own (nil when it has no such channel).
    nonisolated static func channelCopy(of buffer: AVAudioPCMBuffer, channel: Int) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, channel < Int(buffer.format.channelCount), let src = buffer.floatChannelData,
              let format = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = buffer.frameLength
        dst.update(from: src[channel], count: frames)
        return out
    }

    private nonisolated static func monoCopy(of buffer: AVAudioPCMBuffer, channels: Int) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let src = buffer.floatChannelData,
              let format = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = buffer.frameLength
        dst.update(from: src[0], count: frames)
        if channels > 1 {
            vDSP_vadd(dst, 1, src[1], 1, dst, 1, vDSP_Length(frames))
            var half: Float = 0.5
            vDSP_vsmul(dst, 1, &half, dst, 1, vDSP_Length(frames))
        }
        return out
    }

    private nonisolated static func levelsOf(_ buffer: AVAudioPCMBuffer, channels: Int) -> [Float] {
        guard let data = buffer.floatChannelData else { return Array(repeating: 0, count: channels) }
        let frames = Int(buffer.frameLength)
        return (0..<channels).map { channel in
            guard frames > 0 else { return 0 }
            var sum: Float = 0
            let samples = data[min(channel, Int(buffer.format.channelCount) - 1)]
            for i in 0..<frames { sum += samples[i] * samples[i] }
            let rms = sqrt(sum / Float(frames))
            let db = 20 * log10(max(rms, 1e-6))
            return max(0, min(1, (db + 55) / 50))
        }
    }
}

/// Writes tap buffers to disk from the audio thread.
private final class TapWriter: @unchecked Sendable {
    let channels: Int
    private var file: AVAudioFile?
    private let lock = NSLock()
    private let onFailure: @Sendable () -> Void
    private var failed = false
    private var paused = false

    var isPaused: Bool {
        get { lock.withLock { paused } }
        set { lock.withLock { paused = newValue } }
    }

    init(file: AVAudioFile, channels: Int, onFailure: @escaping @Sendable () -> Void) {
        self.file = file
        self.channels = channels
        self.onFailure = onFailure
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, !failed else { return }
        if Int(buffer.format.channelCount) == channels {
            append(buffer, to: file)
            return
        }
        // Interfaces with more than two inputs: keep the first two channels.
        guard let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: buffer.frameLength),
              let src = buffer.floatChannelData, let dst = out.floatChannelData else { return }
        out.frameLength = buffer.frameLength
        for channel in 0..<channels {
            dst[channel].update(from: src[channel], count: Int(buffer.frameLength))
        }
        append(out, to: file)
    }

    /// A full disk, for one: the recording ends with what was written instead of running on without sound.
    private func append(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile) {
        do {
            try file.write(from: buffer)
        } catch {
            failed = true
            onFailure()
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if #available(iOS 18.0, macOS 15.0, *) {
            file?.close()
        }
        file = nil
    }
}
