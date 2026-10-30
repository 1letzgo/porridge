import Accelerate
import AVFoundation
import Observation

struct RecordingResult {
    let fileName: String
    let duration: TimeInterval
    let channelCount: Int
    let inputName: String
    /// True when an external microphone delivers two separate channels (e.g. DJI Mic receiver in stereo mode).
    let isSplitStereo: Bool
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
    private(set) var elapsed: TimeInterval = 0
    private(set) var levels: [Float] = [0]
    private(set) var inputName = ""
    private(set) var channelCount = 1
    private(set) var isExternal = false
    private(set) var isSplitStereo = false

    @ObservationIgnored var onInterrupted: (() -> Void)?
    /// Receives a mono copy of every microphone buffer (for live transcription).
    @ObservationIgnored var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// Created per recording: an engine built earlier keeps the input format of the old route.
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var recordingFormat: AVAudioFormat?
    @ObservationIgnored private var writer: TapWriter?
    @ObservationIgnored private var fileName: String?
    @ObservationIgnored private var startDate: Date?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
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
        let channels = min(Int(hwFormat.channelCount), 2)
        channelCount = channels
        isSplitStereo = isExternal && channels == 2
        levels = Array(repeating: 0, count: channels)

        let name = AudioStore.newFileName()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: hwFormat.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(
            forWriting: AudioStore.url(for: name),
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let writer = TapWriter(file: file, channels: channels)
        self.writer = writer
        self.fileName = name

        input.installTap(
            onBus: 0, bufferSize: 4096, format: hwFormat,
            block: Self.makeTapBlock(writer: writer, onBuffer: onBuffer) { [weak self] levels in
                Task { @MainActor in self?.levels = levels }
            }
        )
        engine.prepare()
        try engine.start()

        isRecording = true
        startDate = Date()
        elapsed = 0
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
        observeInterruptions()
    }

    @discardableResult
    func stop() -> RecordingResult? {
        guard isRecording, let fileName else { return nil }
        ticker?.cancel()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        writer?.close()
        writer = nil
        isRecording = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        let duration = startDate.map { Date().timeIntervalSince($0) } ?? elapsed
        self.fileName = nil
        return RecordingResult(
            fileName: fileName,
            duration: duration,
            channelCount: channelCount,
            inputName: inputName,
            isSplitStereo: isSplitStereo
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
        guard isRecording, let engine, let recordingFormat else { return }
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
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard type == .began else { return }
            MainActor.assumeIsolated { self?.onInterrupted?() }
        })
        #endif
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
        onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?,
        onLevels: @escaping @Sendable ([Float]) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            writer.write(buffer)
            onLevels(levelsOf(buffer, channels: writer.channels))
            if let onBuffer, let mono = monoCopy(of: buffer, channels: writer.channels) {
                onBuffer(mono)
            }
        }
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

    init(file: AVAudioFile, channels: Int) {
        self.file = file
        self.channels = channels
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }
        if Int(buffer.format.channelCount) == channels {
            try? file.write(from: buffer)
            return
        }
        // Interfaces with more than two inputs: keep the first two channels.
        guard let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: buffer.frameLength),
              let src = buffer.floatChannelData, let dst = out.floatChannelData else { return }
        out.frameLength = buffer.frameLength
        for channel in 0..<channels {
            dst[channel].update(from: src[channel], count: Int(buffer.frameLength))
        }
        try? file.write(from: out)
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
