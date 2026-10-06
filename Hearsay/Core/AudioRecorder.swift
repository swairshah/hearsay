import AVFoundation
import CoreAudio
import AudioToolbox
import Accelerate

/// Records audio from the microphone to a WAV file.
/// Provides real-time audio levels for visualization.
final class AudioRecorder {

    enum State {
        case idle
        case starting
        case recording
        case error(String)
    }

    var onAudioLevel: ((Float) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var state: State = .idle

    /// The device UID to use for recording. If nil, uses the system default.
    var deviceUID: String?

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var levelTimer: Timer?
    private var currentLevel: Float = 0
    private var peakLevel: Float = 0
    private var totalSamples: Int = 0
    private var nonZeroSamples: Int = 0

    /// Serial queue for audio engine setup/teardown to avoid blocking the main thread.
    /// AVAudioEngine's internal AVAudioIOUnit queue can stall during device changes
    /// (e.g. Bluetooth/USB mic connect), which deadlocks if called from main.
    private let audioQueue = DispatchQueue(label: "com.swair.hearsay.audiorecorder", qos: .userInitiated)

    /// Incremented on each start/stop cycle to cancel stale in-flight setups.
    private var generation: UInt64 = 0

    /// Small debounce before touching AVAudioEngine/CoreAudio. This lets very short
    /// press/release cycles cancel before we enter synchronous CoreAudio format
    /// negotiation, which can wedge during Bluetooth route churn.
    private let startSetupDebounce: TimeInterval = 0.15
    private let startupTimeout: TimeInterval = 5.0

    private struct AudioStartSnapshot {
        let elapsedSeconds: Double?
        let lastPhase: String?
        let timedOut: Bool
    }

    private let startDiagnosticsLock = NSLock()
    private var startDiagnosticsGeneration: UInt64?
    private var startDiagnosticsRequestedAt: Date?
    private var startDiagnosticsLastPhase: String?
    private var startDiagnosticsTimedOutGeneration: UInt64?

    /// Engines cancelled while AVFAudio is still initializing must not be
    /// deallocated synchronously. On current macOS builds, doing so can block inside
    /// AVAudioIOUnit during Bluetooth route churn. They also cannot be retained
    /// forever: an installed tap keeps the audio file and CoreAudio property listeners
    /// alive, and a stale listener can spin continuously while the app is idle.
    ///
    /// Give AVFAudio a moment to settle, then tear each engine down on a concurrent
    /// utility queue. Concurrent cleanup prevents one wedged engine from blocking
    /// cleanup of all later cancellations.
    private static let quarantinedEngineCleanupDelay: TimeInterval = 2.0
    private static let quarantinedEngineCleanupQueue = DispatchQueue(
        label: "com.swair.hearsay.audioengine-cleanup",
        qos: .utility,
        attributes: .concurrent
    )

    init() {}

    deinit {
        _ = stop()
    }

    // MARK: - Public

    func start() {
        // Allow starting from .idle or .error (so we can recover from previous failures)
        switch state {
        case .starting, .recording:
            print("AudioRecorder: Already starting/recording, ignoring start()")
            DiagnosticLog.shared.event("audio.start.ignored", level: .warning, fields: [
                "state": state.diagnosticName
            ])
            return
        case .error(let prev):
            print("AudioRecorder: Recovering from previous error: \(prev)")
            DiagnosticLog.shared.event("audio.start.recovering_from_error", level: .warning, fields: [
                "message_length": "\(prev.count)"
            ])
            // Clean up any leftover engine state
            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine = nil
            audioFile = nil
            state = .idle
        case .idle:
            break
        }

        // Reset audio tracking
        peakLevel = 0
        totalSamples = 0
        nonZeroSamples = 0

        // Set state immediately so UI can show recording indicator.
        // Engine setup happens on a background queue to avoid deadlocking
        // the main thread when CoreAudio's internal queues are busy
        // (e.g. during USB/Bluetooth device connect/disconnect).
        state = .starting
        generation += 1
        let currentGen = generation
        beginStartDiagnostics(generation: currentGen)

        audioQueue.async { [self] in
            // Give quick press/release cycles a chance to cancel before entering
            // AVAudioEngine/CoreAudio calls that cannot be cancelled once in flight.
            noteStartPhase(
                "setup_begin",
                generation: currentGen,
                fields: ["debounce_seconds": String(format: "%.2f", startSetupDebounce)]
            )
            Thread.sleep(forTimeInterval: startSetupDebounce)
            guard currentGen == generation else {
                print("AudioRecorder: Setup cancelled during startup debounce")
                noteStartPhase("cancelled", generation: currentGen, level: .warning, fields: [
                    "reason": "setup_debounce_cancelled"
                ])
                return
            }

            var lastError: Error?
            var forceDefaultInputOnNextAttempt = false

            for attempt in 1...3 {
                // Check if this start was cancelled by a stop()
                guard currentGen == generation else {
                    print("AudioRecorder: Setup cancelled (generation mismatch)")
                    return
                }

                var engineForCleanup: AVAudioEngine?

                do {
                    print("AudioRecorder: Setting up audio engine... (attempt \(attempt), forceDefaultInput=\(forceDefaultInputOnNextAttempt))")
                    noteStartPhase("build_engine_begin", generation: currentGen, fields: [
                        "attempt": "\(attempt)",
                        "force_default_input": "\(forceDefaultInputOnNextAttempt)"
                    ])
                    let (engine, file) = try buildAudioEngine(
                        forceDefaultInput: forceDefaultInputOnNextAttempt,
                        generation: currentGen,
                        attempt: attempt
                    )
                    engineForCleanup = engine

                    guard currentGen == generation else {
                        print("AudioRecorder: Setup cancelled after build (generation mismatch)")
                        noteStartPhase("cancelled", generation: currentGen, level: .warning, fields: [
                            "reason": "cancelled_after_build"
                        ])
                        quarantineEngine(engine, reason: "cancelled after build")
                        return
                    }

                    print("AudioRecorder: Starting audio engine...")
                    noteStartPhase("engine_start_begin", generation: currentGen, fields: [
                        "attempt": "\(attempt)"
                    ])
                    try engine.start()
                    noteStartPhase("engine_start_end", generation: currentGen, fields: [
                        "attempt": "\(attempt)"
                    ])
                    engineForCleanup = nil

                    DispatchQueue.main.async { [self] in
                        guard currentGen == self.generation else {
                            print("AudioRecorder: Setup cancelled after start (generation mismatch)")
                            self.noteStartPhase("cancelled", generation: currentGen, level: .warning, fields: [
                                "reason": "cancelled_after_engine_start"
                            ])
                            engine.stop()
                            self.quarantineEngine(engine, reason: "cancelled after start")
                            return
                        }
                        self.audioEngine = engine
                        self.audioFile = file
                        self.state = .recording
                        self.startLevelMonitoring()
                        print("AudioRecorder: Started recording to \(Constants.tempAudioURL.path)")
                        self.noteStartPhase("ready", generation: currentGen)
                    }
                    return // success

                } catch {
                    if let engineForCleanup {
                        quarantineEngine(engineForCleanup, reason: "setup/start failed")
                    }
                    lastError = error
                    print("AudioRecorder: Attempt \(attempt) failed: \(error.localizedDescription)")
                    var fields = DiagnosticLog.shared.errorFields(for: error)
                    fields["attempt"] = "\(attempt)"
                    fields["format_mismatch"] = "\(isFormatMismatchError(error))"
                    noteStartPhase("attempt_failed", generation: currentGen, level: .warning, fields: fields)

                    if isFormatMismatchError(error), !forceDefaultInputOnNextAttempt {
                        // Fallback path for aggregate/default route churn where explicit
                        // setInputDevice can trigger 96kHz↔48kHz graph mismatch (-10868).
                        print("AudioRecorder: Detected format mismatch; retrying with system default input path")
                        noteStartPhase("retry_default_input", generation: currentGen, level: .warning, fields: [
                            "reason": "format_mismatch"
                        ])
                        forceDefaultInputOnNextAttempt = true
                    }

                    if attempt < 3 {
                        // Brief pause before retry to let Core Audio settle
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                }
            }

            // All attempts failed
            let message = "Failed to start recording: \(lastError?.localizedDescription ?? "unknown error")"
            print("AudioRecorder: \(message)")
            var fields = lastError.map { DiagnosticLog.shared.errorFields(for: $0) } ?? ["error_type": "unknown"]
            fields["message_length"] = "\(message.count)"
            noteStartPhase("failed", generation: currentGen, level: .error, fields: fields)
            DispatchQueue.main.async { [self] in
                guard currentGen == self.generation else { return }
                self.state = .error(message)
                self.onError?(message)
            }
        }
    }

    /// Result of stopping recording
    struct StopResult {
        enum Reason {
            case completed
            case cancelledBeforeReady
            case notRecording
            case errorState
        }

        let url: URL?
        let wasSilent: Bool
        let peakLevel: Float
        let reason: Reason
        let startupElapsedSeconds: Double?
        let startupLastPhase: String?
        let startupTimedOut: Bool

        init(
            url: URL?,
            wasSilent: Bool,
            peakLevel: Float,
            reason: Reason,
            startupElapsedSeconds: Double? = nil,
            startupLastPhase: String? = nil,
            startupTimedOut: Bool = false
        ) {
            self.url = url
            self.wasSilent = wasSilent
            self.peakLevel = peakLevel
            self.reason = reason
            self.startupElapsedSeconds = startupElapsedSeconds
            self.startupLastPhase = startupLastPhase
            self.startupTimedOut = startupTimedOut
        }
    }

    func stop() -> StopResult {
        // Bump generation to cancel any in-flight background setup
        let stoppedGeneration = generation
        generation += 1

        if case .error(_) = state {
            // Reset to idle so next start() doesn't need special handling
            print("AudioRecorder: stop() called in error state, resetting to idle")
            let snapshot = startSnapshot(for: stoppedGeneration)
            DiagnosticLog.shared.event("audio.stop.error_state", level: .error, fields: [
                "startup_elapsed_seconds": snapshot.elapsedSeconds.map { String(format: "%.2f", $0) } ?? "unknown",
                "startup_last_phase": snapshot.lastPhase ?? "unknown",
                "startup_timed_out": "\(snapshot.timedOut)"
            ])
            teardownEngine(audioEngine)
            audioEngine = nil
            audioFile = nil
            state = .idle
            return StopResult(
                url: nil,
                wasSilent: true,
                peakLevel: 0,
                reason: .errorState,
                startupElapsedSeconds: snapshot.elapsedSeconds,
                startupLastPhase: snapshot.lastPhase,
                startupTimedOut: snapshot.timedOut
            )
        }

        guard case .starting = state else {
            if case .recording = state {
                // Continue below.
            } else {
                return StopResult(url: nil, wasSilent: true, peakLevel: 0, reason: .notRecording)
            }
            return stopReadyRecording()
        }

        // A stop before the async engine setup has published an AVAudioFile is a
        // normal cancellation/too-short recording, not a recorder failure. The
        // generation bump above tells the background setup to tear itself down if
        // it completes after this point.
        levelTimer?.invalidate()
        levelTimer = nil
        teardownEngine(audioEngine)
        audioEngine = nil
        audioFile = nil
        state = .idle
        print("AudioRecorder: Cancelled before engine was ready")
        let snapshot = startSnapshot(for: stoppedGeneration)
        DiagnosticLog.shared.event("audio.stop.before_ready", level: snapshot.timedOut ? .error : .warning, fields: [
            "startup_elapsed_seconds": snapshot.elapsedSeconds.map { String(format: "%.2f", $0) } ?? "unknown",
            "startup_last_phase": snapshot.lastPhase ?? "unknown",
            "startup_timed_out": "\(snapshot.timedOut)",
            "likely_reason": snapshot.timedOut ? "coreaudio_startup_stalled" : "released_before_audio_ready"
        ])
        return StopResult(
            url: nil,
            wasSilent: true,
            peakLevel: 0,
            reason: .cancelledBeforeReady,
            startupElapsedSeconds: snapshot.elapsedSeconds,
            startupLastPhase: snapshot.lastPhase,
            startupTimedOut: snapshot.timedOut
        )
    }

    private func stopReadyRecording() -> StopResult {

        levelTimer?.invalidate()
        levelTimer = nil

        // Engine might not be set up yet if background setup is still in progress.
        // In that case audioEngine is nil — the generation bump above cancels the setup.
        teardownEngine(audioEngine)
        audioEngine = nil

        let url = audioFile?.url
        audioFile = nil

        // Check if audio was essentially silent
        // Peak level below -60dB (0.001) is considered silence
        let silenceThreshold: Float = 0.001
        let wasSilent = peakLevel < silenceThreshold

        state = .idle
        print("AudioRecorder: Stopped recording -> \(url?.path ?? "nil"), peak=\(peakLevel), silent=\(wasSilent)")
        return StopResult(url: url, wasSilent: wasSilent, peakLevel: peakLevel, reason: .completed)
    }

    private func teardownEngine(_ engine: AVAudioEngine?) {
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.reset()
    }

    private func quarantineEngine(_ engine: AVAudioEngine, reason: String) {
        print("AudioRecorder: Scheduling delayed AVAudioEngine cleanup (\(reason))")
        DiagnosticLog.shared.event("audio.engine_cleanup_scheduled", level: .warning, fields: [
            "delay_seconds": String(format: "%.2f", Self.quarantinedEngineCleanupDelay),
            "reason": reason
        ])

        Self.quarantinedEngineCleanupQueue.asyncAfter(
            deadline: .now() + Self.quarantinedEngineCleanupDelay
        ) {
            DiagnosticLog.shared.event("audio.engine_cleanup_begin", fields: ["reason": reason])

            // Stop first so the tap cannot receive more buffers, then detach the tap
            // to release its AVAudioFile closure and CoreAudio format listeners.
            // This may block for a broken device route, which is why each cleanup runs
            // independently on the concurrent utility queue rather than main/audioQueue.
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            engine.reset()

            DiagnosticLog.shared.event("audio.engine_cleanup_end", fields: ["reason": reason])
            print("AudioRecorder: Finished delayed AVAudioEngine cleanup (\(reason))")
        }
    }

    private func beginStartDiagnostics(generation: UInt64) {
        startDiagnosticsLock.lock()
        startDiagnosticsGeneration = generation
        startDiagnosticsRequestedAt = Date()
        startDiagnosticsLastPhase = "requested"
        startDiagnosticsTimedOutGeneration = nil
        startDiagnosticsLock.unlock()

        DiagnosticLog.shared.event("audio.start.requested", fields: [
            "generation": "\(generation)",
            "has_selected_device": "\(deviceUID != nil)",
            "timeout_seconds": String(format: "%.2f", startupTimeout)
        ])

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + startupTimeout) { [weak self] in
            self?.logStartTimeoutIfNeeded(generation: generation)
        }
    }

    private func noteStartPhase(
        _ phase: String,
        generation: UInt64,
        level: DiagnosticLog.Level = .info,
        fields: [String: String] = [:]
    ) {
        var elapsed: Double?
        startDiagnosticsLock.lock()
        if startDiagnosticsGeneration == generation {
            startDiagnosticsLastPhase = phase
            if let requestedAt = startDiagnosticsRequestedAt {
                elapsed = Date().timeIntervalSince(requestedAt)
            }
        }
        startDiagnosticsLock.unlock()

        var eventFields = fields
        eventFields["generation"] = "\(generation)"
        if let elapsed {
            eventFields["elapsed_seconds"] = String(format: "%.2f", elapsed)
        }

        DiagnosticLog.shared.event("audio.start.\(phase)", level: level, fields: eventFields)
    }

    private func logStartTimeoutIfNeeded(generation: UInt64) {
        var fields: [String: String]?

        startDiagnosticsLock.lock()
        if startDiagnosticsGeneration == generation,
           startDiagnosticsTimedOutGeneration != generation,
           startDiagnosticsLastPhase != "ready",
           case .starting = state {
            startDiagnosticsTimedOutGeneration = generation
            var timeoutFields: [String: String] = [
                "generation": "\(generation)",
                "timeout_seconds": String(format: "%.2f", startupTimeout),
                "last_phase": startDiagnosticsLastPhase ?? "unknown",
                "likely_reason": "coreaudio_startup_stalled"
            ]
            if let requestedAt = startDiagnosticsRequestedAt {
                timeoutFields["elapsed_seconds"] = String(format: "%.2f", Date().timeIntervalSince(requestedAt))
            }
            fields = timeoutFields
        }
        startDiagnosticsLock.unlock()

        if let fields {
            DiagnosticLog.shared.event("audio.start.timeout", level: .error, fields: fields)
        }
    }

    private func startSnapshot(for generation: UInt64) -> AudioStartSnapshot {
        startDiagnosticsLock.lock()
        defer { startDiagnosticsLock.unlock() }

        guard startDiagnosticsGeneration == generation else {
            return AudioStartSnapshot(elapsedSeconds: nil, lastPhase: nil, timedOut: false)
        }

        let elapsed = startDiagnosticsRequestedAt.map { Date().timeIntervalSince($0) }
        return AudioStartSnapshot(
            elapsedSeconds: elapsed,
            lastPhase: startDiagnosticsLastPhase,
            timedOut: startDiagnosticsTimedOutGeneration == generation
        )
    }

    // MARK: - Setup

    private func setupAudioSession() throws {
        // On macOS, we don't need explicit audio session setup like iOS
        // But we do need to check microphone permission
    }

    /// Returns the system default input device ID
    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    /// Builds and configures an AVAudioEngine with a tap for recording.
    /// Called on audioQueue (background) to avoid deadlocking the main thread
    /// when CoreAudio's internal queues are busy during device changes.
    /// Returns the engine and audio file — caller is responsible for assigning to self.
    private func buildAudioEngine(forceDefaultInput: Bool = false, generation: UInt64, attempt: Int) throws -> (AVAudioEngine, AVAudioFile) {
        let engine = AVAudioEngine()
        noteStartPhase("build_engine_created", generation: generation, fields: [
            "attempt": "\(attempt)"
        ])

        // If a specific device is requested AND it differs from the system default,
        // configure it on the input node's AudioUnit.
        // IMPORTANT: Skip setInputDevice when target IS the default — calling it explicitly
        // on the default device causes AVAudioEngine format negotiation failures (-10868)
        // because the built-in mic runs at 96kHz but the explicit call triggers a 48kHz
        // format to be cached, creating a mismatch.
        var didSetNonDefaultDevice = false
        if forceDefaultInput {
            print("AudioRecorder: Using fallback mode (system default input, no explicit setInputDevice)")
            noteStartPhase("using_default_input_fallback", generation: generation, fields: [
                "attempt": "\(attempt)"
            ])
        } else if let uid = deviceUID {
            noteStartPhase("resolve_input_device_begin", generation: generation, fields: [
                "attempt": "\(attempt)"
            ])
            guard let targetID = Self.audioDeviceID(for: uid) else {
                noteStartPhase("resolve_input_device_failed", generation: generation, level: .warning, fields: [
                    "attempt": "\(attempt)"
                ])
                return try buildAudioEngine(forceDefaultInput: true, generation: generation, attempt: attempt)
            }
            noteStartPhase("resolve_input_device_end", generation: generation, fields: [
                "attempt": "\(attempt)"
            ])
            noteStartPhase("default_input_query_begin", generation: generation, fields: [
                "attempt": "\(attempt)"
            ])
            let defaultID = Self.defaultInputDeviceID()
            noteStartPhase("default_input_query_end", generation: generation, fields: [
                "attempt": "\(attempt)",
                "default_device_found": "\(defaultID != nil)",
                "target_is_default": "\(targetID == defaultID)"
            ])
            if targetID != defaultID {
                do {
                    noteStartPhase("set_input_device_begin", generation: generation, fields: [
                        "attempt": "\(attempt)"
                    ])
                    try setInputDevice(targetID, on: engine.inputNode)
                    print("AudioRecorder: Set engine input device to \(targetID) (default is \(defaultID ?? 0))")
                    noteStartPhase("set_input_device_end", generation: generation, fields: [
                        "attempt": "\(attempt)"
                    ])
                    didSetNonDefaultDevice = true
                } catch {
                    // Some CoreAudio failures are transient during device/routing churn.
                    // Fallback to default input instead of failing the entire recording session.
                    let nsError = error as NSError
                    noteStartPhase("set_input_device_failed", generation: generation, level: .warning, fields: [
                        "attempt": "\(attempt)",
                        "error_domain": nsError.domain,
                        "error_code": "\(nsError.code)"
                    ])
                    if nsError.domain == NSOSStatusErrorDomain,
                       nsError.code == -10868 || nsError.code == Int(kAudioHardwareIllegalOperationError) {
                        print("AudioRecorder: setInputDevice failed with \(nsError.code), falling back to default input device")
                    } else {
                        throw error
                    }
                }
            } else {
                print("AudioRecorder: Requested device \(targetID) is already system default, skipping explicit setInputDevice")
                noteStartPhase("set_input_device_skipped", generation: generation, fields: [
                    "attempt": "\(attempt)",
                    "reason": "target_is_default"
                ])
            }
        } else {
            noteStartPhase("resolve_input_device_skipped", generation: generation, fields: [
                "attempt": "\(attempt)",
                "has_selected_device": "\(deviceUID != nil)"
            ])
        }

        // Reset the engine ONLY if we set a non-default device.
        // This forces AVAudioEngine to re-query the hardware format after device change.
        if didSetNonDefaultDevice {
            noteStartPhase("engine_reset_begin", generation: generation, fields: [
                "attempt": "\(attempt)"
            ])
            engine.reset()
            print("AudioRecorder: Reset engine after setting non-default device")
            noteStartPhase("engine_reset_end", generation: generation, fields: [
                "attempt": "\(attempt)"
            ])
        }

        let inputNode = engine.inputNode

        // Do not synchronously query inputNode.inputFormat(forBus:) here. During
        // Bluetooth route churn AVAudioIOUnit can block inside GetHWFormat; the
        // first tap buffer already tells us the actual hardware format once the
        // engine is running.

        // Target format: 16kHz mono for qwen_asr
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Constants.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioRecorder", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create target audio format"])
        }

        // Create output file
        let outputURL = Constants.tempAudioURL

        // Remove existing file
        try? FileManager.default.removeItem(at: outputURL)

        noteStartPhase("create_audio_file_begin", generation: generation, fields: [
            "attempt": "\(attempt)"
        ])
        let audioFile = try AVAudioFile(
            forWriting: outputURL,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Constants.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
        )
        noteStartPhase("create_audio_file_end", generation: generation, fields: [
            "attempt": "\(attempt)"
        ])

        // Query hardware input format to configure the tap.
        // Passing nil for format causes AVAudioEngine to use inputNode.outputFormat(forBus: 0),
        // which defaults to 48kHz. If the hardware input device runs at a different rate
        // (e.g. 16kHz for webcam microphones like the Logitech C920, 32kHz, or 96kHz),
        // the rate mismatch between inputNode's input and output bus causes engine.start()
        // to fail with Core Audio error -10868 (kAudioUnitErr_FormatNotSupported).
        // Passing the hardware input format configures the node's output format to match.
        let hwFormat = inputNode.inputFormat(forBus: 0)
        let tapFormat: AVAudioFormat? = (hwFormat.sampleRate > 0 && hwFormat.channelCount > 0) ? hwFormat : nil

        let bufferSize: AVAudioFrameCount = 4096
        var cachedConverter: AVAudioConverter?
        var cachedSampleRate: Double = 0
        var cachedChannelCount: AVAudioChannelCount = 0
        var formatLoggedOnce = false

        var tapFields: [String: String] = [
            "attempt": "\(attempt)",
            "buffer_size": "\(bufferSize)"
        ]
        if let tapFormat {
            tapFields["hw_sample_rate"] = "\(Int(tapFormat.sampleRate))"
            tapFields["hw_channels"] = "\(tapFormat.channelCount)"
        }

        noteStartPhase("install_tap_begin", generation: generation, fields: tapFields)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) { [weak self] buffer, time in
            guard let self = self else { return }

            let bufferFormat = buffer.format
            let bufferSampleRate = bufferFormat.sampleRate
            let bufferChannelCount = bufferFormat.channelCount

            if !formatLoggedOnce {
                print("AudioRecorder: First tap buffer format: \(bufferChannelCount)ch @ \(bufferSampleRate)Hz")
                DiagnosticLog.shared.event("audio.first_buffer", fields: [
                    "sample_rate": "\(Int(bufferSampleRate))",
                    "channels": "\(bufferChannelCount)"
                ])
                formatLoggedOnce = true
            }

            let needsConversion = bufferSampleRate != Constants.sampleRate || bufferChannelCount != 1

            if needsConversion {
                // Recreate converter if the buffer format changed
                if cachedSampleRate != bufferSampleRate || cachedChannelCount != bufferChannelCount {
                    cachedConverter = AVAudioConverter(from: bufferFormat, to: targetFormat)
                    cachedSampleRate = bufferSampleRate
                    cachedChannelCount = bufferChannelCount
                    if cachedConverter == nil {
                        print("AudioRecorder: WARNING - Failed to create converter from \(bufferChannelCount)ch @ \(bufferSampleRate)Hz")
                        DiagnosticLog.shared.event("audio.converter_create_failed", level: .warning, fields: [
                            "source_sample_rate": "\(Int(bufferSampleRate))",
                            "source_channels": "\(bufferChannelCount)",
                            "target_sample_rate": "\(Int(Constants.sampleRate))"
                        ])
                    }
                }

                guard let converter = cachedConverter else { return }

                let frameCount = AVAudioFrameCount(
                    Double(buffer.frameLength) * Constants.sampleRate / bufferSampleRate
                )
                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: frameCount
                ) else { return }

                var error: NSError?
                let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }

                if status == .haveData {
                    self.updateLevel(from: convertedBuffer)
                    try? audioFile.write(from: convertedBuffer)
                } else if let error = error {
                    print("AudioRecorder: Conversion error: \(error.localizedDescription)")
                    DiagnosticLog.shared.event("audio.conversion_failed", level: .warning, fields: DiagnosticLog.shared.errorFields(for: error))
                }
            } else {
                // Format already matches target
                self.updateLevel(from: buffer)
                try? audioFile.write(from: buffer)
            }
        }
        noteStartPhase("install_tap_end", generation: generation, fields: [
            "attempt": "\(attempt)"
        ])

        return (engine, audioFile)
    }

    private func isFormatMismatchError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.code == -10868 { return true }

        if nsError.domain == NSOSStatusErrorDomain,
           nsError.code == -10868 {
            return true
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.code == -10868 {
            return true
        }

        let msg = nsError.localizedDescription.lowercased()
        return msg.contains("10868") || msg.contains("formats don't match")
    }

    // MARK: - Device Configuration

    /// Sets the input device for the audio engine's input node without modifying system defaults
    private func setInputDevice(_ deviceID: AudioDeviceID, on inputNode: AVAudioInputNode) throws {
        var deviceID = deviceID
        let audioUnit = inputNode.audioUnit

        guard let audioUnit = audioUnit else {
            throw NSError(domain: "AudioRecorder", code: 5,
                         userInfo: [NSLocalizedDescriptionKey: "Input node has no audio unit"])
        }

        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                         userInfo: [NSLocalizedDescriptionKey:
                            "Failed to set audio input device (status: \(status))"])
        }
    }

    /// Gets the AudioDeviceID for a given device UID
    private static func audioDeviceID(for uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize
        )

        guard status == noErr else { return nil }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceIDs
        )

        guard status == noErr else { return nil }

        // Find the device with matching UID
        for deviceID in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var deviceUID: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)

            status = AudioObjectGetPropertyData(
                deviceID,
                &uidAddress,
                0,
                nil,
                &uidSize,
                &deviceUID
            )

            if status == noErr, deviceUID as String == uid {
                return deviceID
            }
        }

        return nil
    }

    private func updateLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)

        // Calculate RMS
        var rms: Float = 0
        vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameLength))

        // Track peak level and non-zero samples for silence detection
        peakLevel = max(peakLevel, rms)
        totalSamples += frameLength

        // Count samples above noise floor (very low threshold)
        let noiseFloor: Float = 0.0001
        for i in 0..<frameLength {
            if abs(channelData[i]) > noiseFloor {
                nonZeroSamples += 1
            }
        }

        // Convert to dB and normalize to 0-1 range
        // [-45, -5] balances speech sensitivity with background noise rejection
        let minDb: Float = -45
        let maxDb: Float = -5
        let db = 20 * log10(max(rms, 0.000001))
        let normalized = (db - minDb) / (maxDb - minDb)
        let clamped = max(0, min(1, normalized))

        // Gentle noise gate: suppress very quiet background noise
        currentLevel = clamped < 0.03 ? 0 : clamped
    }

    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: Constants.audioLevelUpdateInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.onAudioLevel?(self.currentLevel)
            }
        }
    }

    // MARK: - Permissions

    static func checkMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    static func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

private extension AudioRecorder.State {
    var diagnosticName: String {
        switch self {
        case .idle:
            return "idle"
        case .starting:
            return "starting"
        case .recording:
            return "recording"
        case .error:
            return "error"
        }
    }
}
