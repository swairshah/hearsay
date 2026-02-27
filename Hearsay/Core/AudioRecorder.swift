import AVFoundation
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
        guard case .idle = state else { 
            print("AudioRecorder: Not idle, state = \(state)")
            return 
        }
        
        // Reset audio tracking
        peakLevel = 0
        totalSamples = 0
        nonZeroSamples = 0
        
        do {
            print("AudioRecorder: Setting up audio session...")
            try setupAudioSession()
            print("AudioRecorder: Setting up audio engine...")
            try setupAudioEngine()
            print("AudioRecorder: Starting audio engine...")
            try audioEngine?.start()
            print("AudioRecorder: Starting level monitoring...")
            startLevelMonitoring()
            state = .recording
            print("AudioRecorder: Started recording to \(Constants.tempAudioURL.path)")
        } catch {
            let message = "Failed to start recording: \(error.localizedDescription)"
            print("AudioRecorder: \(message)")
            state = .error(message)
            onError?(message)
        }
    }
    
    /// Result of stopping recording
    struct StopResult {
        let url: URL?
        let wasSilent: Bool
        let peakLevel: Float
    }
    
    func stop() -> StopResult {
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
    
    private func setupAudioEngine() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
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
        
        // Create converter if needed
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        
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
        
        // Install tap on input
        let bufferSize: AVAudioFrameCount = 4096
        
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return }
            
            // Convert to target format
            if let converter = converter {
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
        // Narrower range [-50, -5] focuses on speech levels instead of full dynamic range
        let minDb: Float = -50
        let maxDb: Float = -5
        let db = 20 * log10(max(rms, 0.000001))
        let normalized = (db - minDb) / (maxDb - minDb)
        let clamped = max(0, min(1, normalized))

        // sqrt curve for perceptual mapping — quiet sounds more visible, loud sounds don't saturate
        currentLevel = sqrt(clamped)
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
