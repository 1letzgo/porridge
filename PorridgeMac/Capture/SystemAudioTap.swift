import AVFoundation
import AudioToolbox
import CoreAudio

/// Whether meetings record the Mac's sound next to the microphone (the toggle in Record Meeting). On by default.
enum MeetingAudio {
    private static let key = "meetingIncludesSystemAudio"

    static var includesSystemAudio: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum SystemAudioError: LocalizedError {
    case coreAudio(String, OSStatus)
    case format

    var errorDescription: String? {
        switch self {
        case .coreAudio(let step, let status): "The Mac's sound can't be recorded (\(step), error \(status))."
        case .format: "The Mac's sound has a format that can't be recorded."
        }
    }
}

/// The sound every app on the Mac plays (the other side of a Zoom, Meet or Teams call, with headphones too),
/// through a Core Audio process tap: a private global tap without Porridge's own sound, read through a private
/// aggregate device. It needs the "System Audio Recording" permission (NSAudioCaptureUsageDescription), not
/// screen recording. When the output device changes (headphones plugged in) or its rate does (AirPods switch to
/// 24 or 16 kHz when a call takes their microphone), the tap is built again. The tap's format is not trusted for
/// the rate: the aggregate device delivers at its own rate, measured by `DeliveredRate`.
final class SystemAudioTap: SecondChannelSource, @unchecked Sendable {
    private(set) var fifo = SampleFIFO(sampleRate: 48_000)

    private let lock = NSRecursiveLock()
    /// Guards only what the audio callback reads (converter and formats), held for an instant and never around a
    /// Core Audio call: stopping the device waits for the callback, so the callback must never wait for `lock`.
    private let formatLock = NSLock()
    private let ioQueue = DispatchQueue(label: "de.letzgo.porridge.system-audio", qos: .userInitiated)
    /// Device changes are handled here, not on `ioQueue`: stopping the device waits for the callback there.
    private let controlQueue = DispatchQueue(label: "de.letzgo.porridge.system-audio.control")
    private var sampleRate: Double = 48_000
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var tapFormat: AVAudioFormat?
    private var monoFormat: AVAudioFormat?
    private var outputListener: AudioObjectPropertyListenerBlock?
    /// Watches the aggregate device's rate. Called on `rateQueue`, which only hands over to `controlQueue`:
    /// removing the listener (from `controlQueue` too) waits for a running call and must not wait for itself.
    private var rateListener: AudioObjectPropertyListenerBlock?
    private let rateQueue = DispatchQueue(label: "de.letzgo.porridge.system-audio.rate")
    /// Under `formatLock`: the rate the buffers really arrive at.
    private var delivered = DeliveredRate(rate: 48_000)
    private var running = false

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var nominalRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    func start(sampleRate: Double) throws {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
        self.sampleRate = sampleRate
        fifo = SampleFIFO(sampleRate: sampleRate)
        try buildTap()
        running = true
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.outputChanged() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, controlQueue, listener) == noErr {
            outputListener = listener
        }
    }

    func stop() {
        // The listener is taken away outside the lock: removing it waits for a change being handled on
        // `controlQueue`, and that one takes the lock.
        lock.lock()
        running = false
        let listener = outputListener
        outputListener = nil
        lock.unlock()
        removeListener(listener)
        lock.lock()
        defer { lock.unlock() }
        tearDownTap()
    }

    deinit {
        running = false
        removeListener(outputListener)
        outputListener = nil
        tearDownTap()
    }

    /// Within `start` (under the lock, taken once), before a new tap. The lock is let go while the listener is
    /// removed, as in `stop`.
    private func stopLocked() {
        running = false
        let listener = outputListener
        outputListener = nil
        if listener != nil {
            lock.unlock()
            removeListener(listener)
            lock.lock()
        }
        tearDownTap()
    }

    private func removeListener(_ listener: AudioObjectPropertyListenerBlock?) {
        guard let listener else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, controlQueue, listener)
    }

    /// The aggregate device follows the output device; a new one (headphones, AirPods) or a new rate of the same one
    /// needs a new tap: a tap kept through a change of rate may deliver silence.
    private func outputChanged() {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        tearDownTap()
        fifo.reset()
        // Without a tap the right channel stays silent; the microphone goes on either way.
        try? buildTap()
    }

    // MARK: Building

    private func buildTap() throws {
        do {
            try buildTapSteps()
        } catch {
            tearDownTap()
            throw error
        }
    }

    private func buildTapSteps() throws {
        // Porridge's own sound (playing a recording) is not part of the meeting.
        let own = Self.processObject(for: getpid()).map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: own)
        description.uuid = UUID()
        description.name = "Porridge Meeting Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "tap")
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        try check(Self.read(tap, kAudioTapPropertyFormat, into: &asbd), "tap format")

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Porridge Meeting Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "aggregate device")
        aggregateID = device

        // The aggregate device runs at the output device's rate, which the tap's format does not always say (48 kHz
        // in it with the output at 44.1 kHz). Its rate is the first guess; the measured one wins (see `receive`).
        var deviceRate: Float64 = 0
        if Self.read(device, kAudioDevicePropertyNominalSampleRate, into: &deviceRate) == noErr, deviceRate > 0 {
            asbd.mSampleRate = deviceRate
        }
        guard let tapFormat = AVAudioFormat(streamDescription: &asbd),
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = Self.converter(from: tapFormat, to: monoFormat)
        else { throw SystemAudioError.format }
        formatLock.lock()
        self.tapFormat = tapFormat
        self.monoFormat = monoFormat
        self.converter = converter
        delivered = DeliveredRate(rate: tapFormat.sampleRate)
        formatLock.unlock()

        // Only a real change counts: the device may report its rate again once it settled.
        let builtRate = deviceRate, deviceID = device
        let rateListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            var rate: Float64 = 0
            guard Self.read(deviceID, kAudioDevicePropertyNominalSampleRate, into: &rate) == noErr, rate != builtRate else { return }
            self?.controlQueue.async { self?.outputChanged() }
        }
        if AudioObjectAddPropertyListenerBlock(device, &Self.nominalRateAddress, rateQueue, rateListener) == noErr {
            self.rateListener = rateListener
        }

        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, ioQueue) { [weak self] now, input, inputTime, _, _ in
            let stamp = inputTime.pointee.mFlags.contains(.hostTimeValid) ? inputTime.pointee.mHostTime : now.pointee.mHostTime
            self?.receive(input, hostTime: stamp)
        }, "audio callback")
        procID = proc
        // The first start asks for the permission; until it is given the tap delivers silence.
        try check(AudioDeviceStart(device, proc), "start")
    }

    private func tearDownTap() {
        if aggregateID != kAudioObjectUnknown {
            if let rateListener {
                AudioObjectRemovePropertyListenerBlock(aggregateID, &Self.nominalRateAddress, rateQueue, rateListener)
            }
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        rateListener = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
        formatLock.lock()
        converter = nil
        formatLock.unlock()
    }

    // MARK: Sound

    private static func converter(from tapFormat: AVAudioFormat, to monoFormat: AVAudioFormat) -> AVAudioConverter? {
        let converter = AVAudioConverter(from: tapFormat, to: monoFormat)
        converter?.downmix = true
        return converter
    }

    /// On `ioQueue`: the tap's stereo mixed to mono at the microphone's rate, into the queue the recorder reads.
    private func receive(_ input: UnsafePointer<AudioBufferList>, hostTime: UInt64) {
        formatLock.lock()
        let converter = self.converter, tapFormat = self.tapFormat, monoFormat = self.monoFormat
        formatLock.unlock()
        guard var current = converter, var format = tapFormat, let monoFormat else { return }
        // The aggregate device lists the input streams of its sub-device first (a headset such as AirPods has a
        // microphone) and the tap's last: only the tap's buffers are read, so the other side never gets the mic.
        let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let needed = format.isInterleaved ? 1 : Int(format.channelCount)
        guard needed > 0, all.count >= needed else { return }
        let tapBuffers = AudioBufferList.allocate(maximumBuffers: needed)
        defer { free(tapBuffers.unsafeMutablePointer) }
        for index in 0..<needed { tapBuffers[index] = all[all.count - needed + index] }
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let frames = bytesPerFrame > 0 ? Int(tapBuffers[0].mDataByteSize) / bytesPerFrame : 0
        guard frames > 0 else { return }
        // The rate the frames really arrive at; a new one gets a new converter and starts the queue over.
        let seconds = Double(AudioConvertHostTimeToNanos(hostTime)) / 1_000_000_000
        formatLock.lock()
        let measured = self.converter === current ? delivered.add(frames: frames, at: seconds) : nil
        if let measured {
            var asbd = format.streamDescription.pointee
            asbd.mSampleRate = measured
            if let newFormat = AVAudioFormat(streamDescription: &asbd), let newConverter = Self.converter(from: newFormat, to: monoFormat) {
                self.tapFormat = newFormat
                self.converter = newConverter
                format = newFormat
                current = newConverter
            }
        }
        formatLock.unlock()
        if measured != nil { fifo.reset() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: tapBuffers.unsafePointer, deallocator: nil),
              buffer.frameLength > 0 else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * monoFormat.sampleRate / format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: capacity) else { return }
        var provided = false
        var error: NSError?
        let status = current.convert(to: out, error: &error) { _, inputStatus in
            if provided {
                inputStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let samples = out.floatChannelData?[0] else { return }
        fifo.push(samples, count: Int(out.frameLength))
    }

    // MARK: Core Audio

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw SystemAudioError.coreAudio(step, status) }
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    }

    /// Porridge's own audio process; none until it has played or recorded sound.
    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        let status = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, into: &device)
        guard status == noErr, device != kAudioObjectUnknown else { throw SystemAudioError.coreAudio("output device", status) }
        var uid: Unmanaged<CFString>?
        let uidStatus = read(device, kAudioDevicePropertyDeviceUID, into: &uid)
        guard uidStatus == noErr, let uid else { throw SystemAudioError.coreAudio("output device", uidStatus) }
        return uid.takeRetainedValue() as String
    }
}
