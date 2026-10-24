import AVFoundation
import CoreAudio
import Foundation
import os.log

private let captureLogger = Logger(subsystem: "com.swair.hearsay", category: "meeting-audio")

/// Captures what the other people on a call say: everything the Mac plays,
/// via a Core Audio process tap (macOS 14.2+). Hearsay's own process is excluded
/// so its chimes don't end up in the transcript.
///
/// Needs the "System Audio Recording" permission (`NSAudioCaptureUsageDescription`).
/// If the user declines, the tap still runs but delivers silence.
@available(macOS 14.2, *)
final class SystemAudioTap {

    /// 16 kHz mono samples, delivered on the tap's private queue.
    var onSamples: (([Float]) -> Void)?

    private let queue = DispatchQueue(label: "com.swair.hearsay.meeting.system-audio", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private let resampler = MeetingAudioIO.Resampler()
    private var formatListener: AudioObjectPropertyListenerBlock?

    func start() throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: Self.ownProcessObjects())
        description.uuid = UUID()
        description.name = "Hearsay Meeting Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "create process tap")
        tapID = tap

        do {
            tapFormat = try readTapFormat()

            let properties: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Hearsay Meeting Audio",
                kAudioAggregateDeviceUIDKey: "com.swair.hearsay.meeting.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                // Start immediately even if nothing is playing yet.
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
                ],
            ]
            var aggregate = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateAggregateDevice(properties as CFDictionary, &aggregate), "create aggregate device")
            aggregateID = aggregate

            installFormatListener()

            var proc: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { [weak self] _, inputData, _, _, _ in
                self?.handleInput(inputData)
            }, "create IO proc")
            procID = proc

            try check(AudioDeviceStart(aggregate, proc), "start aggregate device")
            captureLogger.notice("System audio tap started format=\(self.tapFormat?.description ?? "unknown", privacy: .public)")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            if let formatListener {
                var address = Self.formatAddress
                AudioObjectRemovePropertyListenerBlock(tapID, &address, queue, formatListener)
            }
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        formatListener = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit {
        stop()
    }

    // MARK: - Private

    private static var formatAddress = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private func handleInput(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let format = tapFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil),
              buffer.frameLength > 0 else { return }
        let samples = resampler.convert(buffer)
        if !samples.isEmpty {
            onSamples?(samples)
        }
    }

    /// The output route changed (e.g. AirPods connected) — pick up the new tap format.
    private func installFormatListener() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let format = try? self.readTapFormat() else { return }
            self.tapFormat = format
            captureLogger.notice("System audio tap format changed to \(format.description, privacy: .public)")
        }
        var address = Self.formatAddress
        if AudioObjectAddPropertyListenerBlock(tapID, &address, queue, listener) == noErr {
            formatListener = listener
        }
    }

    private func readTapFormat() throws -> AVAudioFormat {
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = Self.formatAddress
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &description), "read tap format")
        guard let format = AVAudioFormat(streamDescription: &description) else {
            throw SpeechTranscriptionError.failed("Unsupported system audio format")
        }
        return format
    }

    /// Hearsay and its helper processes, if Core Audio knows about them.
    private static func ownProcessObjects() -> [AudioObjectID] {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? [object] : []
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            captureLogger.error("System audio \(operation, privacy: .public) failed: \(status)")
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Couldn't \(operation) (\(status))"
            ])
        }
    }
}

/// Captures the local speaker from the active microphone for meeting recording.
///
/// Independent of `AudioRecorder` so push-to-talk dictation keeps working while
/// a meeting records. Restarts itself when the input route changes.
final class MeetingMicrophoneCapture {

    /// 16 kHz mono samples, delivered on the capture queue.
    var onSamples: (([Float]) -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.swair.hearsay.meeting.mic", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private let resampler = MeetingAudioIO.Resampler()
    private var configurationObserver: NSObjectProtocol?
    private var isRunning = false

    func start() throws {
        isRunning = true
        try startEngine()
    }

    func stop() {
        isRunning = false
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()

        if let uid = MicrophoneManager.shared.activeDevice?.uid,
           let target = AudioRecorder.audioDeviceID(for: uid),
           target != AudioRecorder.defaultInputDeviceID(),
           let unit = engine.inputNode.audioUnit {
            var deviceID = target
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status == noErr {
                engine.reset()
            } else {
                captureLogger.warning("Meeting mic: couldn't select device (\(status)); using system default")
            }
        }

        let input = engine.inputNode
        let hardwareFormat = input.inputFormat(forBus: 0)
        let tapFormat = hardwareFormat.sampleRate > 0 && hardwareFormat.channelCount > 0 ? hardwareFormat : nil

        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Convert inside the tap block: the engine may recycle `buffer` afterwards.
            let samples = self.resampler.convert(buffer)
            guard !samples.isEmpty else { return }
            self.queue.async {
                self.onSamples?(samples)
            }
        }

        try engine.start()
        self.engine = engine

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.restartAfterRouteChange()
        }
        captureLogger.notice("Meeting mic started format=\(hardwareFormat.description, privacy: .public)")
    }

    private func restartAfterRouteChange() {
        guard isRunning else { return }
        captureLogger.notice("Meeting mic route changed; restarting input")
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        // Give Core Audio a moment to settle (Bluetooth profile switches).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isRunning else { return }
            do {
                try self.startEngine()
            } catch {
                captureLogger.error("Meeting mic restart failed: \(error.localizedDescription, privacy: .public)")
                self.onError?("Microphone stopped: \(error.localizedDescription)")
            }
        }
    }
}
