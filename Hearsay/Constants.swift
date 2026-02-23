import AppKit

enum Constants {
    // MARK: - Indicator Dimensions
    static let indicatorHeight: CGFloat = 36
    static let indicatorWidth: CGFloat = 70
    static let indicatorCornerRadius: CGFloat = 18
    static let indicatorBottomMargin: CGFloat = 100
    
    // MARK: - Animation
    static let indicatorFadeIn: TimeInterval = 0.15
    static let indicatorFadeOut: TimeInterval = 0.2
    static let doneDisplayDuration: TimeInterval = 0.8
    
    // MARK: - Audio
    static let sampleRate: Double = 16000
    static let audioLevelUpdateInterval: TimeInterval = 0.05
    static let waveformBarCount: Int = 8
    
    // MARK: - Colors
    static let indicatorBackground = NSColor(white: 0.1, alpha: 0.95)
    static let indicatorText = NSColor.white
    static let indicatorTextDim = NSColor(white: 0.5, alpha: 1)
    static let recordingDot = NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1)
    static let successColor = NSColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1)
    
    // MARK: - Paths
    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Hearsay/Models", isDirectory: true)
    }
    
    static var historyDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Hearsay/History", isDirectory: true)
    }
    
    static var figuresDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Hearsay/Figures", isDirectory: true)
    }
    
    static var tempAudioURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hearsay_recording.wav")
    }
    
    // MARK: - Model
    static let defaultModelId = "qwen3-asr-0.6b"
}
