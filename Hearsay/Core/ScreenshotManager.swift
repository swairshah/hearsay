import AppKit
import os.log

private let screenshotLogger = Logger(subsystem: "com.swair.hearsay", category: "screenshot")

/// Represents a captured screenshot with its timestamp relative to recording start
struct CapturedFigure {
    let url: URL
    let timestamp: TimeInterval  // Seconds since recording started
}

/// Manages screenshot capture during recording sessions.
/// Screenshots are stored in ~/Library/Application Support/Hearsay/Figures/
final class ScreenshotManager {
    
    static let shared = ScreenshotManager()
    
    /// Screenshots captured during the current recording session with timestamps
    private(set) var currentSessionFigures: [CapturedFigure] = []
    
    /// When the current recording session started
    private var sessionStartTime: Date?
    
    /// Callback when a screenshot is captured
    var onScreenshotCaptured: ((Int) -> Void)?
    
    private init() {
        createFiguresDirectory()
    }
    
    // MARK: - Directory Management
    
    private func createFiguresDirectory() {
        try? FileManager.default.createDirectory(
            at: Constants.figuresDirectory,
            withIntermediateDirectories: true
        )
    }
    
    // MARK: - Session Management
    
    /// Start a new recording session - clears previous screenshots and records start time
    func startSession() {
        currentSessionFigures.removeAll()
        sessionStartTime = Date()
        screenshotLogger.info("Screenshot session started")
    }
    
    /// End the current session and return captured figures with timestamps
    func endSession() -> [CapturedFigure] {
        let figures = currentSessionFigures
        screenshotLogger.info("Screenshot session ended with \(figures.count) figure(s)")
        sessionStartTime = nil
        return figures
    }
    
    /// Get the count of screenshots in current session
    var screenshotCount: Int {
        currentSessionFigures.count
    }
    
    // MARK: - Screenshot Capture
    
    /// Capture a screenshot interactively (user selects region)
    /// Records the timestamp relative to session start for interleaving with transcript
    func captureScreenshot() {
        let figureNumber = currentSessionFigures.count + 1
        let dateString = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")
        
        let filename = "figure-\(figureNumber)-\(dateString).png"
        let outputURL = Constants.figuresDirectory.appendingPathComponent(filename)
        
        // Calculate timestamp relative to session start
        let captureTimestamp: TimeInterval
        if let startTime = sessionStartTime {
            captureTimestamp = Date().timeIntervalSince(startTime)
        } else {
            captureTimestamp = 0
        }
        
        screenshotLogger.info("Starting interactive screenshot capture -> \(outputURL.path) at \(captureTimestamp)s")
        
        // Use screencapture command with interactive selection
        // -i = interactive mode (select area)
        // -x = no sound
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", outputURL.path]
        
        do {
            try process.run()
            
            // Wait for completion in background
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                process.waitUntilExit()
                
                DispatchQueue.main.async {
                    if process.terminationStatus == 0 && FileManager.default.fileExists(atPath: outputURL.path) {
                        let figure = CapturedFigure(url: outputURL, timestamp: captureTimestamp)
                        self?.currentSessionFigures.append(figure)
                        let count = self?.currentSessionFigures.count ?? 0
                        screenshotLogger.info("Screenshot captured: \(outputURL.lastPathComponent) at \(captureTimestamp)s (total: \(count))")
                        self?.onScreenshotCaptured?(count)
                    } else {
                        screenshotLogger.info("Screenshot cancelled or failed (status: \(process.terminationStatus))")
                    }
                }
            }
        } catch {
            screenshotLogger.error("Failed to launch screencapture: \(error.localizedDescription)")
        }
    }
    
    // Transcript interleaving (figures + clips) lives in `TranscriptInterleaver`.
}
