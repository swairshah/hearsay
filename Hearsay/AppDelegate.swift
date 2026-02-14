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
    
    // MARK: - State
    
    private var isRecording = false
    private var currentModelPath: String?
    
    // MARK: - Lifecycle
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Hearsay: Starting up...")
        
        // Create necessary directories
        createDirectories()
        
        // Initialize components
        setupStatusBar()
        setupRecordingUI()
        setupAudioRecorder()
        setupHotkeyMonitor()
        
        // Check permissions and model (slight delay helps with launch via Finder)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Task {
                await self.checkPermissions()
                await self.setupModel()
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor?.stop()
    }
    
    // MARK: - Setup
    
    private func createDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Constants.modelsDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Constants.historyDirectory, withIntermediateDirectories: true)
    }
    
    private func setupStatusBar() {
        statusBar = StatusBarController()
        
        statusBar.onToggleEnabled = { [weak self] enabled in
            if enabled {
                self?.hotkeyMonitor.start()
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
    }
    
    // MARK: - Permissions
    
    private var permissionCheckTimer: Timer?
    
    private func checkPermissions() async {
        // Check microphone - request if not determined
        let micStatus = PermissionsManager.checkMicrophone()
        if micStatus == .notDetermined {
            _ = await PermissionsManager.requestMicrophone()
        }
        
        // Try to start hotkey monitor
        await MainActor.run {
            tryStartHotkeyMonitor()
        }
    }
    
    private var permissionRetryCount = 0
    
    private func tryStartHotkeyMonitor() {
        // Try to start - if it works, we have permission
        if hotkeyMonitor.start() {
            logger.info("Hotkey monitor started successfully")
            permissionCheckTimer?.invalidate()
            permissionCheckTimer = nil
            permissionRetryCount = 0
            return
        }
        
        // Failed to start - need permission
        permissionRetryCount += 1
        
        // First failure - just request permission silently
        if permissionRetryCount == 1 {
            logger.info("Need accessibility permission, requesting...")
            PermissionsManager.requestAccessibility()
        }
        
        // After 5 seconds of failures, show helpful message
        if permissionRetryCount == 5 {
            DispatchQueue.main.async {
                self.showAccessibilityHelp()
            }
        }
        
        // Poll for permission to be granted
        if permissionCheckTimer == nil {
            permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.permissionRetryCount += 1
                
                // Try to start again
                if self.hotkeyMonitor.start() {
                    logger.info("Hotkey monitor started after permission granted!")
                    self.permissionCheckTimer?.invalidate()
                    self.permissionCheckTimer = nil
                    self.permissionRetryCount = 0
                }
            }
        }
    }
    
    private func showAccessibilityHelp() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Needed"
        alert.informativeText = """
        Hearsay needs accessibility permission to detect the Option key.
        
        Please:
        1. Open System Settings → Privacy & Security → Accessibility
        2. Find "Hearsay" and toggle it OFF then ON
        
        (This is needed after app updates)
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")
        
        if alert.runModal() == .alertFirstButtonReturn {
            PermissionsManager.openAccessibilitySettings()
        }
    }
    
    // MARK: - Model Setup
    
    private func setupModel() async {
        await MainActor.run {
            // Check for installed models using ModelDownloader
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
                } else {
                    // No model - show onboarding
                    statusBar.updateModelName(nil)
                    logger.info("No model found, showing onboarding")
                    showOnboardingForDownload()
                }
            }
        }
    }
    
    private func showOnboardingForDownload() {
        if onboardingWindowController == nil {
            onboardingWindowController = OnboardingWindowController()
            onboardingWindowController?.onComplete = { [weak self] in
                // Model downloaded, set it up
                Task {
                    await self?.setupModel()
                }
            }
        }
        onboardingWindowController?.show()
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
        
        isRecording = true
        logger.info("Starting recording...")
        
        // Update UI
        recordingIndicator.setState(.recording)
        recordingWindow.fadeIn()
        statusBar.showRecordingState(true)
        
        // Start recording
        audioRecorder.start()
        
        logger.info("Recording started")
    }
    
    private func stopRecording() {
        guard isRecording else { 
            logger.warning("Not recording, ignoring stop")
            return 
        }
        
        logger.info("Stopping recording...")
        isRecording = false
        statusBar.showRecordingState(false)
        
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
        recordingIndicator.setState(.transcribing)
        
        logger.info("Starting transcription...")
        
        // Transcribe
        Task {
            await transcribe(audioURL: audioURL)
        }
    }
    
    private func transcribe(audioURL: URL) async {
        guard let transcriber = transcriber else {
            DispatchQueue.main.async { [weak self] in
                self?.recordingIndicator.setState(.error("No model"))
                self?.dismissIndicatorAfterDelay()
            }
            return
        }
        
        // Get audio duration for history
        let audioDuration = getAudioDuration(url: audioURL)
        
        do {
            let text = try await transcriber.transcribe(audioURL: audioURL)
            
            DispatchQueue.main.async { [weak self] in
                // Show success
                self?.recordingIndicator.setState(.done)
                
                // Insert text
                TextInserter.insert(text)
                
                // Save to history
                HistoryStore.shared.add(text: text, durationSeconds: audioDuration)
                
                // Dismiss after delay
                self?.dismissIndicatorAfterDelay()
            }
            
            logger.info("Transcription complete: \(text.prefix(50))...")
            
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.recordingIndicator.setState(.error("Failed"))
                self?.dismissIndicatorAfterDelay()
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
    
    private func dismissIndicatorAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.doneDisplayDuration) { [weak self] in
            self?.recordingWindow.fadeOut()
        }
    }
    
    // MARK: - Error Handling
    
    private func showError(_ message: String) {
        recordingIndicator.setState(.error(message))
        recordingWindow.fadeIn()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.recordingWindow.fadeOut()
        }
    }
    
    // MARK: - Windows
    
    private func showOnboarding() {
        showOnboardingForDownload()
    }
    
    private func showHistory() {
        if historyWindowController == nil {
            historyWindowController = HistoryWindowController()
        }
        historyWindowController?.showWindow()
    }
    
    private func showSettings() {
        // TODO: Implement settings window
        let alert = NSAlert()
        alert.messageText = "Settings"
        alert.informativeText = "Settings coming soon!"
        alert.runModal()
    }
}
