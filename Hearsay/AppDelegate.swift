import AppKit
import os.log

private let logger = Logger(subsystem: "com.swair.hearsay", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate {
    
    // MARK: - Components
    
    private var statusBar: StatusBarController!
    private var hotkeyMonitor: HotkeyMonitor!
    private var audioRecorder: AudioRecorder!
    private var recordingWindow: RecordingWindow!
    private var recordingIndicator: RecordingIndicator!
    private var transcriber: Transcriber?
    private var historyWindowController: HistoryWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var settingsWindowController: SettingsWindowController?
    
    // MARK: - State
    
    private var isRecording = false
    private var currentModelPath: String?
    private var indicatorDismissWorkItem: DispatchWorkItem?
    private var currentDismissID: UUID?
    private var currentTranscriptionID: UUID?
    
    // MARK: - Lifecycle
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Hearsay: Starting up...")
        
        // Apply dock icon preference
        let showDockIcon = UserDefaults.standard.bool(forKey: "showDockIcon")
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        
        // Create necessary directories
        createDirectories()
        
        // Initialize components
        setupStatusBar()
        setupRecordingUI()
        setupAudioRecorder()
        setupHotkeyMonitor()
        
        // Check if we need to show onboarding (permissions or model missing)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.checkAndShowOnboardingIfNeeded()
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor?.stop()
        indicatorDismissWorkItem?.cancel()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // When clicking dock icon, show settings
        showSettings()
        return true
    }
    
    // MARK: - Setup
    
    private func createDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Constants.modelsDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Constants.historyDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Constants.figuresDirectory, withIntermediateDirectories: true)
    }
    
    private func setupStatusBar() {
        statusBar = StatusBarController()
        
        statusBar.onToggleEnabled = { [weak self] enabled in
            if enabled {
                self?.tryStartHotkeyMonitor()
            } else {
                self?.hotkeyMonitor.stop()
            }
        }
        
        statusBar.onShowOnboarding = { [weak self] in
            self?.showOnboarding()
        }
        
        statusBar.onShowHistory = { [weak self] in
            self?.showHistory()
        }
        
        statusBar.onShowSettings = { [weak self] in
            self?.showSettings()
        }
        
        statusBar.onShowPermissions = { [weak self] in
            self?.showPermissions()
        }
        
        statusBar.onCopyHistoryItem = { item in
            TextInserter.copyToClipboard(item.text)
            // Optionally also paste
            // TextInserter.insert(item.text)
        }
        
        statusBar.onQuit = {
            NSApp.terminate(nil)
        }
    }
    
    private func setupRecordingUI() {
        recordingWindow = RecordingWindow()
        recordingIndicator = RecordingIndicator(frame: NSRect(
            x: 0, y: 0,
            width: Constants.indicatorWidth,
            height: Constants.indicatorHeight
        ))
        recordingIndicator.autoresizingMask = [.width, .height]
        recordingWindow.contentView?.addSubview(recordingIndicator)
    }
    
    private func setupAudioRecorder() {
        audioRecorder = AudioRecorder()
        
        audioRecorder.onAudioLevel = { [weak self] level in
            self?.recordingIndicator.audioLevel = level
        }
        
        audioRecorder.onError = { [weak self] message in
            self?.showError(message)
        }
    }
    
    private func setupHotkeyMonitor() {
        hotkeyMonitor = HotkeyMonitor()
        
        hotkeyMonitor.onRecordingStart = { [weak self] in
            self?.startRecording()
        }
        
        hotkeyMonitor.onRecordingStop = { [weak self] in
            self?.stopRecording()
        }
        
        hotkeyMonitor.onScreenshotRequested = { [weak self] in
            self?.captureScreenshot()
        }
        
        // Set up screenshot manager callback
        ScreenshotManager.shared.onScreenshotCaptured = { [weak self] count in
            guard let self = self else { return }
            logger.info("Screenshot captured: count=\(count)")
            self.recordingIndicator.figureCount = count
            // Resize window to fit new indicator width
            self.recordingWindow.positionOnScreen(width: self.recordingIndicator.idealWidth)
        }
    }
    
    // MARK: - Permissions & Onboarding
    
    private var permissionCheckTimer: Timer?
    private var permissionRetryCount = 0
    
    /// Check if we need to show onboarding (missing permissions or model)
    private func checkAndShowOnboardingIfNeeded() {
        let micGranted = PermissionsManager.checkMicrophone() == .granted
        let accessGranted = PermissionsManager.checkAccessibility() == .granted
        let hasModel = !ModelDownloader.shared.installedModels().isEmpty || 
                       FileManager.default.fileExists(atPath: "/Users/swair/work/misc/qwen-asr/qwen3-asr-0.6b")
        
        if !micGranted || !accessGranted || !hasModel {
            // Show onboarding for permissions and/or model download
            showOnboardingForSetup()
        } else {
            // All good, just set up the model and start
            setupModelAndStart()
        }
    }
    
    private func showOnboardingForSetup() {
        if onboardingWindowController == nil {
            onboardingWindowController = OnboardingWindowController()
            onboardingWindowController?.onComplete = { [weak self] in
                self?.setupModelAndStart()
            }
        }
        onboardingWindowController?.show()
    }
    
    private func setupModelAndStart() {
        // Set up model
        let installedModels = ModelDownloader.shared.installedModels()
        
        if let firstModel = installedModels.first {
            let modelPath = Constants.modelsDirectory.appendingPathComponent(firstModel.rawValue).path
            currentModelPath = modelPath
            transcriber = Transcriber(modelPath: modelPath)
            statusBar.updateModelName(firstModel.displayName)
            logger.info("Using model: \(firstModel.rawValue)")
        } else {
            // Check for development model as fallback
            let devModelPath = "/Users/swair/work/misc/qwen-asr/qwen3-asr-0.6b"
            if FileManager.default.fileExists(atPath: devModelPath) {
                currentModelPath = devModelPath
                transcriber = Transcriber(modelPath: devModelPath)
                statusBar.updateModelName("qwen3-asr-0.6b (dev)")
                logger.info("Using development model")
            }
        }
        
        // Start hotkey monitor
        tryStartHotkeyMonitor()
    }
    
    private func tryStartHotkeyMonitor() {
        if hotkeyMonitor.start() {
            logger.info("Hotkey monitor started successfully")
            self.permissionCheckTimer?.invalidate()
            self.permissionCheckTimer = nil
            self.permissionRetryCount = 0
        } else {
            self.permissionRetryCount += 1
            logger.warning("Hotkey monitor failed to start (attempt \(self.permissionRetryCount))")
            
            // Retry periodically
            if self.permissionCheckTimer == nil {
                self.permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    self?.tryStartHotkeyMonitor()
                }
            }
        }
    }
    
    // MARK: - Recording
    
    private func startRecording() {
        guard !isRecording else { 
            logger.warning("Already recording, ignoring")
            return 
        }
        guard transcriber != nil else {
            logger.error("No transcriber available!")
            showError("No model installed")
            return
        }
        
        // Check microphone permission before recording
        let micStatus = PermissionsManager.checkMicrophone()
        guard micStatus == .granted else {
            logger.error("Microphone permission not granted: \(String(describing: micStatus))")
            showError("No mic access")
            showOnboardingForSetup()
            return
        }
        
        isRecording = true
        logger.info("=== START RECORDING ===")
        
        // Cancel any pending dismiss from previous transcription/error
        logger.info("Canceling pending dismiss, currentDismissID was: \(self.currentDismissID?.uuidString ?? "nil")")
        cancelPendingIndicatorDismiss()
        
        // Invalidate UI updates from in-flight transcription tasks.
        logger.info("Invalidating transcription ID, was: \(self.currentTranscriptionID?.uuidString ?? "nil")")
        currentTranscriptionID = nil
        
        // Start screenshot session
        ScreenshotManager.shared.startSession()
        hotkeyMonitor.enableScreenshotHotKey()
        
        // Update UI - always show figure count indicator (works in both hold and toggle mode)
        let isToggleMode = hotkeyMonitor.state == .recordingToggle
        recordingIndicator.figureCount = 0
        recordingIndicator.showFigureCount = true  // Always show, screenshots work in both modes
        
        logger.info("Setting indicator state to .recording and calling fadeIn")
        recordingIndicator.setState(.recording)
        recordingWindow.positionOnScreen(width: recordingIndicator.idealWidth)
        recordingWindow.fadeIn()
        statusBar.showRecordingState(true)
        
        // Start recording
        audioRecorder.start()
        
        logger.info("Recording started (toggle mode: \(isToggleMode))")
    }
    
    private func captureScreenshot() {
        guard isRecording else {
            logger.warning("Not recording, ignoring screenshot request")
            return
        }
        
        logger.info("Capturing screenshot...")
        ScreenshotManager.shared.captureScreenshot()
    }
    
    private func stopRecording() {
        guard isRecording else { 
            logger.warning("Not recording, ignoring stop")
            return 
        }
        
        logger.info("=== STOP RECORDING ===")
        isRecording = false
        statusBar.showRecordingState(false)
        
        // End screenshot session and disable hotkey
        let figures = ScreenshotManager.shared.endSession()
        hotkeyMonitor.disableScreenshotHotKey()
        recordingIndicator.showFigureCount = false
        
        logger.info("Recording stopped with \(figures.count) screenshot(s)")
        
        // Stop recording and get audio file
        guard let audioURL = audioRecorder.stop() else {
            logger.error("audioRecorder.stop() returned nil!")
            recordingWindow.fadeOut()
            showError("Failed to save recording")
            return
        }
        
        logger.info("Audio saved to \(audioURL.path)")
        
        // Check file exists and size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path) {
            let size = attrs[.size] as? Int64 ?? 0
            logger.info("Audio file size: \(size) bytes")
        }
        
        // Show transcribing state
        logger.info("Setting indicator state to .transcribing")
        recordingIndicator.setState(.transcribing)
        let transcriptionID = UUID()
        currentTranscriptionID = transcriptionID
        
        logger.info("Starting transcription with ID: \(transcriptionID.uuidString)")
        
        // Transcribe
        Task {
            await transcribe(audioURL: audioURL, transcriptionID: transcriptionID, figures: figures)
        }
    }
    
    private func transcribe(audioURL: URL, transcriptionID: UUID, figures: [CapturedFigure] = []) async {
        guard let transcriber = transcriber else {
            await MainActor.run {
                logger.info("Transcription \(transcriptionID.uuidString.prefix(8)): no model, checking if stale...")
                guard self.currentTranscriptionID == transcriptionID else {
                    logger.info("Transcription \(transcriptionID.uuidString.prefix(8)): STALE (current: \(self.currentTranscriptionID?.uuidString ?? "nil")), skipping UI update")
                    return
                }
                logger.info("Transcription \(transcriptionID.uuidString.prefix(8)): showing error and scheduling dismiss")
                self.recordingIndicator.setState(.error("No model"))
                self.dismissIndicatorAfterDelay()
            }
            return
        }
        
        // Get audio duration for history
        let audioDuration = getAudioDuration(url: audioURL)
        
        do {
            let text: String
            
            if figures.isEmpty {
                // Simple case: no figures, just transcribe
                text = try await transcriber.transcribe(audioURL: audioURL)
            } else {
                // Interleaved case: split audio at figure timestamps and transcribe each segment
                let timestamps = ScreenshotManager.shared.getSplitTimestamps(figures: figures)
                logger.info("Splitting audio at timestamps: \(timestamps)")
                
                if let segments = AudioSplitter.splitWAV(at: audioURL, timestamps: timestamps) {
                    logger.info("Audio split into \(segments.count) segments")
                    var transcripts: [String] = []
                    
                    for (index, segment) in segments.enumerated() {
                        do {
                            let segmentText = try await transcriber.transcribe(audioURL: segment)
                            transcripts.append(segmentText)
                        } catch Transcriber.TranscriptionError.noOutput {
                            // Short/silent segment is expected sometimes when splitting at screenshot boundaries.
                            // Keep placeholder so figure interleaving alignment remains correct.
                            logger.info("Segment \(index) produced no transcription output; continuing")
                            transcripts.append("")
                        }
                    }
                    
                    // Clean up segment files
                    AudioSplitter.cleanupSegments(segments)
                    
                    // Format with interleaved figure references
                    text = ScreenshotManager.shared.formatInterleavedTranscription(transcripts, figures: figures)
                } else {
                    // Fallback: couldn't split, transcribe whole file
                    logger.warning("Failed to split audio, transcribing whole file")
                    let rawText = try await transcriber.transcribe(audioURL: audioURL)
                    // Simple format with figures at end
                    let figurePaths = figures.enumerated().map { "Figure \($0.offset + 1): \($0.element.url.path)" }.joined(separator: "\n")
                    text = rawText + (figures.isEmpty ? "" : "\n\n\(figurePaths)")
                }
            }
            
            await MainActor.run {
                logger.info("Transcription \(transcriptionID.uuidString.prefix(8)): SUCCESS, checking if stale...")
                
                // Insert text
                TextInserter.insert(text)
                
                // Save to history (save raw text for cleaner history)
                HistoryStore.shared.add(text: text, durationSeconds: audioDuration)
                
                guard self.currentTranscriptionID == transcriptionID else {
                    logger.info("Transcription \(transcriptionID.uuidString.prefix(8)): STALE (current: \(self.currentTranscriptionID?.uuidString ?? "nil")), skipping UI update")
                    return
                }
                
                // Show success
                logger.info("Transcription \(transcriptionID.uuidString.prefix(8)): showing done and scheduling dismiss")
                self.recordingIndicator.setState(.done)
                
                // Dismiss after delay
                self.dismissIndicatorAfterDelay()
            }
            
            logger.info("Transcription complete: \(text.prefix(50))...")
            
        } catch {
            await MainActor.run {
                logger.info("Transcription \(transcriptionID.uuidString.prefix(8)): ERROR, checking if stale...")
                guard self.currentTranscriptionID == transcriptionID else {
                    logger.info("Transcription \(transcriptionID.uuidString.prefix(8)): STALE (current: \(self.currentTranscriptionID?.uuidString ?? "nil")), skipping UI update")
                    return
                }
                logger.info("Transcription \(transcriptionID.uuidString.prefix(8)): showing error and scheduling dismiss")
                self.recordingIndicator.setState(.error("Failed"))
                self.dismissIndicatorAfterDelay()
            }
            logger.error("Transcription error: \(error.localizedDescription)")
        }
        
        // Clean up temp file
        try? FileManager.default.removeItem(at: audioURL)
    }
    
    private func getAudioDuration(url: URL) -> Double {
        // Estimate from file size: 16kHz * 2 bytes/sample = 32000 bytes/sec
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            return 0
        }
        // Subtract WAV header (~44 bytes) and calculate duration
        let audioBytes = max(0, size - 44)
        return Double(audioBytes) / 32000.0
    }
    
    private func cancelPendingIndicatorDismiss() {
        indicatorDismissWorkItem?.cancel()
        indicatorDismissWorkItem = nil
        currentDismissID = nil  // Invalidate any in-flight dismiss
    }
    
    private func scheduleIndicatorDismiss(after delay: TimeInterval) {
        cancelPendingIndicatorDismiss()
        
        // Capture the current work item ID to detect if it was cancelled
        let dismissID = UUID()
        currentDismissID = dismissID
        
        logger.info("Scheduling dismiss \(dismissID.uuidString.prefix(8)) after \(delay)s")
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            logger.info("Dismiss \(dismissID.uuidString.prefix(8)) firing...")
            
            // Check if this dismiss was cancelled (a new recording started)
            guard self.currentDismissID == dismissID else {
                logger.info("Dismiss \(dismissID.uuidString.prefix(8)) cancelled (current: \(self.currentDismissID?.uuidString ?? "nil"))")
                return
            }
            
            // Never hide while actively recording
            if self.isRecording {
                logger.info("Dismiss \(dismissID.uuidString.prefix(8)) skipped - recording is active")
                return
            }
            
            // Final check: only dismiss if we're in a done/error state
            // This prevents dismissing if a new recording started between scheduling and execution
            switch self.recordingIndicator.state {
            case .done, .error:
                logger.info("Dismiss \(dismissID.uuidString.prefix(8)) proceeding - state is final, calling fadeOut")
                break
            case .recording, .transcribing:
                logger.info("Dismiss \(dismissID.uuidString.prefix(8)) skipped - state is not final")
                return
            }
            
            self.recordingWindow.fadeOut()
            self.indicatorDismissWorkItem = nil
            self.currentDismissID = nil
        }
        
        indicatorDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
    
    private func dismissIndicatorAfterDelay() {
        scheduleIndicatorDismiss(after: Constants.doneDisplayDuration)
    }
    
    // MARK: - Error Handling
    
    private func showError(_ message: String) {
        recordingIndicator.setState(.error(message))
        recordingWindow.fadeIn()
        scheduleIndicatorDismiss(after: 2.0)
    }
    
    // MARK: - Windows
    
    private func showOnboarding() {
        showOnboardingForSetup()
    }
    
    private func showHistory() {
        if historyWindowController == nil {
            historyWindowController = HistoryWindowController()
        }
        historyWindowController?.showWindow()
    }
    
    private func ensureSettingsWindowController() -> SettingsWindowController {
        if let existing = settingsWindowController {
            return existing
        }
        
        let controller = SettingsWindowController()
        controller.onHotkeyChanged = { [weak self] in
            // Reload hotkey settings
            self?.hotkeyMonitor.loadSettings()
        }
        controller.onWindowOpened = { [weak self] in
            // Stop hotkey monitor while settings is open to allow shortcut recording
            self?.hotkeyMonitor.stop()
        }
        controller.onWindowClosed = { [weak self] in
            // Restart hotkey monitor when settings closes
            self?.tryStartHotkeyMonitor()
        }
        settingsWindowController = controller
        return controller
    }
    
    private func showSettings() {
        ensureSettingsWindowController().show(tab: .settings)
    }
    
    private func showPermissions() {
        ensureSettingsWindowController().show(tab: .permissions)
    }
}
