import AVFoundation
import CoreAudio
import AudioToolbox
import Accelerate

/// Records audio from the microphone to a WAV file.
/// Provides real-time audio levels for visualization.
final class AudioRecorder {
    
    enum State {
        case idle
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
    
    init() {}
    
    deinit {
        _ = stop()
    }
    
    // MARK: - Public
    
    func start() {
        // Allow starting from .idle or .error (so we can recover from previous failures)
        switch state {
        case .recording:
            print("AudioRecorder: Already recording, ignoring start()")
            return
        case .error(let prev):
            print("AudioRecorder: Recovering from previous error: \(prev)")
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
        
        // Retry up to 2 times on Core Audio transient errors
        var lastError: Error?
        for attempt in 1...2 {
            do {
                print("AudioRecorder: Setting up audio session... (attempt \(attempt))")
                try setupAudioSession()
                print("AudioRecorder: Setting up audio engine...")
                try setupAudioEngine()
                print("AudioRecorder: Starting audio engine...")
                try audioEngine?.start()
                print("AudioRecorder: Starting level monitoring...")
                startLevelMonitoring()
                state = .recording
                print("AudioRecorder: Started recording to \(Constants.tempAudioURL.path)")
                return // success
            } catch {
                lastError = error
                print("AudioRecorder: Attempt \(attempt) failed: \(error.localizedDescription)")
                // Clean up before retry
                audioEngine?.stop()
                audioEngine?.inputNode.removeTap(onBus: 0)
                audioEngine = nil
                audioFile = nil
                if attempt < 2 {
                    // Brief pause before retry to let Core Audio settle
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        }
        
        // All attempts failed
        let message = "Failed to start recording: \(lastError?.localizedDescription ?? "unknown error")"
        print("AudioRecorder: \(message)")
        state = .error(message)
        onError?(message)
    }
    
    /// Result of stopping recording
    struct StopResult {
        let url: URL?
        let wasSilent: Bool
        let peakLevel: Float
    }
    
    func stop() -> StopResult {
        if case .error(_) = state {
            // Reset to idle so next start() doesn't need special handling
            print("AudioRecorder: stop() called in error state, resetting to idle")
            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine = nil
            audioFile = nil
            state = .idle
            return StopResult(url: nil, wasSilent: true, peakLevel: 0)
        }
        guard case .recording = state else { 
            return StopResult(url: nil, wasSilent: true, peakLevel: 0) 
        }
        
        levelTimer?.invalidate()
        levelTimer = nil
        
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        
        let url = audioFile?.url
        audioFile = nil
        
        // Check if audio was essentially silent
        // Peak level below -60dB (0.001) is considered silence
        let silenceThreshold: Float = 0.001
        let wasSilent = peakLevel < silenceThreshold
        
        state = .idle
        print("AudioRecorder: Stopped recording -> \(url?.path ?? "nil"), peak=\(peakLevel), silent=\(wasSilent)")
        return StopResult(url: url, wasSilent: wasSilent, peakLevel: peakLevel)
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
    
    private func setupAudioEngine() throws {
        let engine = AVAudioEngine()
        
        // If a specific non-default device is requested, configure it on the input node's AudioUnit.
        // Skip this when the requested device IS the system default — setting it explicitly
        // can cause AVAudioEngine format negotiation failures (error -10868).
        if let uid = deviceUID, let targetID = Self.audioDeviceID(for: uid) {
            let defaultID = Self.defaultInputDeviceID()
            if targetID != defaultID {
                try setInputDevice(targetID, on: engine.inputNode)
                print("AudioRecorder: Set engine input device to \(targetID) (default is \(defaultID ?? 0))")
            } else {
                print("AudioRecorder: Requested device \(targetID) is already system default, skipping explicit setInputDevice")
            }
        }
        
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Validate the format
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw NSError(domain: "AudioRecorder", code: 4,
                         userInfo: [NSLocalizedDescriptionKey:
                            "Invalid input format: \(inputFormat.channelCount)ch @ \(inputFormat.sampleRate)Hz"])
        }
        print("AudioRecorder: Input format: \(inputFormat.channelCount)ch @ \(inputFormat.sampleRate)Hz")
        
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
        self.audioFile = audioFile
        
        // Create the converter once (inputFormat → 16kHz mono)
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        let needsConversion = inputFormat.sampleRate != Constants.sampleRate || inputFormat.channelCount != 1
        
        // Install tap on input — pass nil for format so AVAudioEngine uses the
        // node's native format, avoiding mismatches after device changes.
        let bufferSize: AVAudioFrameCount = 4096
        
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { [weak self] buffer, time in
            guard let self = self else { return }
            
            if needsConversion, let converter = converter {
                let frameCount = AVAudioFrameCount(
                    Double(buffer.frameLength) * Constants.sampleRate / inputFormat.sampleRate
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
                }
            } else {
                // Format already matches
                self.updateLevel(from: buffer)
                try? audioFile.write(from: buffer)
            }
        }
        
        self.audioEngine = engine
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
