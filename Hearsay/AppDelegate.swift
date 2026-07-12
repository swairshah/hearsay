import AppKit
import os.log

private let logger = Logger(subsystem: "com.swair.hearsay", category: "app")
private let diagnosticLog = DiagnosticLog.shared

private extension DictationMode {
    var diagnosticName: String {
        switch self {
        case .pasteAtCursor:
            return "paste_at_cursor"
        case .returnToCaller:
            return "return_to_caller"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    
    // MARK: - Components
    
    private var statusBar: StatusBarController!
    private var hotkeyMonitor: HotkeyMonitor!
    private var audioRecorder: AudioRecorder!
    private var recordingWindow: RecordingWindow!
    private var recordingIndicator: RecordingIndicator!
    private var transcriber: (any SpeechTranscribing)?
    private let cleanupManager = TextCleanupManager()
    private var localAPIServer: HearsayLocalAPIServer?
    private var onboardingWindowController: OnboardingWindowController?
    private var settingsWindowController: SettingsWindowController?
    
    // MARK: - Dev Mode
    
    /// Dev mode is active when running from a build directory (i.e. not /Applications).
    static var isDevMode: Bool {
        let bundlePath = Bundle.main.bundlePath
        return bundlePath.contains("/Build/Products/") || bundlePath.contains("/DerivedData/")
    }
    
    // MARK: - State
    
    private var isRecording = false
    private var isTranscribing = false
    private var currentModelIdentifier: String?
    private var indicatorDismissWorkItem: DispatchWorkItem?
    private var currentDismissID: UUID?
    private var currentTranscriptionID: UUID?
    private var activeDictationMode: DictationMode = .pasteAtCursor
    private var activeCallerRequest: DictationRequest?
    private var recentRecorderStopFailures = 0
    private var lastRecorderStopFailureAt: Date?
    private var didAutoRelaunchForRecorderFailure = false
    
    // MARK: - Lifecycle
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Hearsay: Starting up...")
        diagnosticLog.event("app.launch", fields: [
            "dev_mode": "\(Self.isDevMode)",
            "process_id": "\(ProcessInfo.processInfo.processIdentifier)"
        ])
        
        // Apply dock icon preference
        let showDockIcon = UserDefaults.standard.bool(forKey: "showDockIcon")
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        
        // Create necessary directories
        createDirectories()
        configureLocalCaches()
        
        // Initialize components
        setupStatusBar()
        setupRecordingUI()
        setupAudioRecorder()
        setupMicrophoneManager()
        setupHotkeyMonitor()
        setupLocalAPI()
        
        // Check if we need to show onboarding (permissions or model missing)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.checkAndShowOnboardingIfNeeded()
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        diagnosticLog.event("app.terminate")
        hotkeyMonitor?.stop()
        localAPIServer?.stop()
        indicatorDismissWorkItem?.cancel()
        cleanupManager.shutdown()
    }
    
    func applicationDidBecomeActive(_ notification: Notification) {
        // When user returns from System Settings after granting permissions,
        // immediately retry hotkey monitor startup so shortcuts begin working
        // without requiring an app relaunch.
        if PermissionsManager.checkAccessibility() == .granted {
            tryStartHotkeyMonitor()
        }
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
        try? fm.createDirectory(at: Constants.fluidAudioCacheDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Constants.appSupportDirectory, withIntermediateDirectories: true)
    }

    /// Keep FluidAudio/Parakeet caches under Hearsay's Application Support folder.
    private func configureLocalCaches() {
        setenv("XDG_CACHE_HOME", Constants.fluidAudioCacheDirectory.path, 1)
        logger.info("XDG_CACHE_HOME set to \(Constants.fluidAudioCacheDirectory.path)")
    }
    
    private func setupStatusBar() {
        statusBar = StatusBarController()
        
        statusBar.onToggleEnabled = { [weak self] enabled in
            if enabled {
                self?.tryStartHotkeyMonitor()
            } else {
                // Prevent stuck recording indicator if monitoring is disabled mid-recording.
                if self?.isRecording == true {
                    self?.stopRecording()
                }
                self?.hotkeyMonitor.stop()
            }
        }
        
        statusBar.onShowOnboarding = { [weak self] in
            self?.showModels()
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
        
        statusBar.onCheckForUpdates = { [weak self] in
            self?.checkForUpdates()
        }

        statusBar.onOpenDiagnosticLog = { [weak self] in
            self?.openDiagnosticLog()
        }

        statusBar.onCopyDiagnosticLogs = { [weak self] in
            self?.copyDiagnosticLogs()
        }

        statusBar.onEmailDiagnosticLogs = { [weak self] in
            self?.emailDiagnosticLogs()
        }

        statusBar.onRevealDiagnosticLog = {
            DiagnosticLog.shared.event("diagnostics.reveal_requested")
            NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.shared.logURL])
        }

        statusBar.onClearDiagnosticLogs = { [weak self] in
            self?.clearDiagnosticLogs()
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
    
    /// Recreate indicator window to avoid rare NSPanel/layer corruption after long runtimes.
    private func refreshRecordingUIWindow() {
        recordingWindow?.orderOut(nil)
        
        let newWindow = RecordingWindow()
        let newIndicator = RecordingIndicator(frame: NSRect(
            x: 0, y: 0,
            width: Constants.indicatorWidth,
            height: Constants.indicatorHeight
        ))
        newIndicator.autoresizingMask = [.width, .height]
        newWindow.contentView?.addSubview(newIndicator)
        
        recordingWindow = newWindow
        recordingIndicator = newIndicator
        logger.info("Recreated recording window/indicator to reset window state")
    }
    
    private func setupAudioRecorder() {
        audioRecorder = AudioRecorder()
        
        audioRecorder.onAudioLevel = { [weak self] level in
            self?.recordingIndicator.audioLevel = level
        }
        
        audioRecorder.onError = { [weak self] message in
            self?.showError(message)
        }
        
        // Set initial microphone device from priority settings
        updateRecorderDevice()
    }
    
    private func setupMicrophoneManager() {
        MicrophoneManager.shared.onActiveDeviceChanged = { [weak self] device in
            guard let self = self else { return }
            if let device = device {
                logger.info("Active microphone changed to: \(device.name)")
            } else {
                logger.warning("No microphone available")
            }
            diagnosticLog.event("microphone.active_device_changed", fields: [
                "has_active_device": "\(device != nil)"
            ])
            self.updateRecorderDevice()
        }
    }
    
    private func updateRecorderDevice() {
        let device = MicrophoneManager.shared.activeDevice
        audioRecorder.deviceUID = device?.uid
        logger.info("Recorder device set to: \(device?.name ?? "system default")")
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

        hotkeyMonitor.onFullScreenshotRequested = { [weak self] in
            self?.captureFullScreen()
        }

        // Set up screenshot manager callback — fires when screenshot is actually saved (after drag+release)
        ScreenshotManager.shared.onScreenshotCaptured = { [weak self] count in
            guard let self = self else { return }
            logger.info("Screenshot captured: count=\(count)")
            diagnosticLog.event("recording.screenshot_captured", fields: ["count": "\(count)"])
            SoundPlayer.shared.play(.screenshot)
            self.recordingIndicator.figureCount = count
            // Resize window to fit new indicator width
            self.recordingWindow.positionOnScreen(width: self.recordingIndicator.idealWidth)
        }

        // Set up clipboard manager callback — fires when text is copied during recording
        ClipboardManager.shared.onClipCaptured = { [weak self] count in
            guard let self = self else { return }
            logger.info("Clipboard copy captured: count=\(count)")
            diagnosticLog.event("recording.clip_captured", fields: ["count": "\(count)"])
            self.recordingIndicator.clipCount = count
            // Resize window to fit the new badge
            self.recordingWindow.positionOnScreen(width: self.recordingIndicator.idealWidth)
        }
    }

    private func setupLocalAPI() {
        let server = HearsayLocalAPIServer(delegate: self)
        do {
            try server.start()
            localAPIServer = server
            diagnosticLog.event("local_api.start")
        } catch {
            logger.error("Failed to start local API server: \(error.localizedDescription)")
            diagnosticLog.event("local_api.start_failed", level: .error, fields: diagnosticLog.errorFields(for: error))
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
            
            // Keep hotkey monitor startup/retry loop armed even while onboarding is shown.
            // This ensures accessibility permission changes are picked up immediately
            // (without needing app restart).
            tryStartHotkeyMonitor()
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
        onboardingWindowController?.showSetup()
    }
    
    @discardableResult
    private func configureTranscriberIfAvailable() -> Bool {
        let installedModels = ModelDownloader.shared.installedModels()

        // Prefer the user's selected model if installed, otherwise fall back to first installed.
        let preferredModel = ModelDownloader.shared.selectedModelPreference()
        let targetModel = preferredModel.flatMap { installedModels.contains($0) ? $0 : nil } ?? installedModels.first

        if let model = targetModel {
            switch model.backend {
            case .qwenASR:
                let modelPath = Constants.modelsDirectory.appendingPathComponent(model.rawValue).path
                let identifier = "qwen:\(modelPath)"

                // Reconfigure if first time or if user switched model.
                if currentModelIdentifier != identifier {
                    currentModelIdentifier = identifier
                    transcriber = Transcriber(modelPath: modelPath)
                    statusBar.updateModelName(model.displayName)
                    logger.info("Using qwen_asr model: \(model.rawValue)")
                    diagnosticLog.event("transcriber.configured", fields: [
                        "backend": "qwen_asr",
                        "model": model.rawValue
                    ])
                }
                return true

            case .whisperKit:
                let identifier = "whisper:\(model.rawValue)"
                if currentModelIdentifier != identifier {
                    currentModelIdentifier = identifier
                    transcriber = WhisperTranscriber(modelName: model.rawValue)
                    statusBar.updateModelName(model.displayName)
                    logger.info("Using Whisper model: \(model.rawValue)")
                    diagnosticLog.event("transcriber.configured", fields: [
                        "backend": "whisper",
                        "model": model.rawValue
                    ])
                }
                return true

            case .parakeet:
                guard let parakeetModel = model.parakeetModel else {
                    return false
                }

                let identifier = "parakeet:\(model.rawValue)"
                if currentModelIdentifier != identifier {
                    currentModelIdentifier = identifier
                    transcriber = ParakeetTranscriber(model: parakeetModel)
                    statusBar.updateModelName(model.displayName)
                    logger.info("Using Parakeet model: \(model.rawValue)")
                    diagnosticLog.event("transcriber.configured", fields: [
                        "backend": "parakeet",
                        "model": model.rawValue
                    ])
                }
                return true
            }
        }

        // Check for development qwen model as fallback
        let devModelPath = "/Users/swair/work/misc/qwen-asr/qwen3-asr-0.6b"
        if FileManager.default.fileExists(atPath: devModelPath) {
            let identifier = "qwen:\(devModelPath)"
            if currentModelIdentifier != identifier {
                currentModelIdentifier = identifier
                transcriber = Transcriber(modelPath: devModelPath)
                statusBar.updateModelName("qwen3-asr-0.6b (dev)")
                logger.info("Using development qwen_asr model")
                diagnosticLog.event("transcriber.configured", fields: [
                    "backend": "qwen_asr",
                    "model": "qwen3-asr-0.6b",
                    "dev_model": "true"
                ])
            }
            return true
        }

        if currentModelIdentifier != nil {
            diagnosticLog.event("transcriber.unavailable", level: .warning)
        }
        statusBar.updateModelName(nil)
        transcriber = nil
        currentModelIdentifier = nil
        return false
    }
    
    private func setupModelAndStart() {
        let hasTranscriber = configureTranscriberIfAvailable()

        if hasTranscriber {
            prewarmActiveTranscriber()
        }
        
        // Load cleanup model if enabled and downloaded
        if CleanupModelDownloader.shared.isEnabled && CleanupModelDownloader.shared.isModelInstalled() {
            Task {
                await cleanupManager.loadModel()
            }
        }
        
        // Start hotkey monitor
        tryStartHotkeyMonitor()
    }

    private func prewarmActiveTranscriber() {
        guard let transcriber = transcriber else { return }

        Task {
            logger.info("Prewarming speech model for faster first transcription...")
            do {
                try await transcriber.prewarm()
                logger.info("Speech model prewarm complete")
                diagnosticLog.event("transcriber.prewarm.success")
            } catch {
                logger.error("Speech model prewarm failed: \(error.localizedDescription)")
                diagnosticLog.event("transcriber.prewarm.failed", level: .warning, fields: diagnosticLog.errorFields(for: error))
            }
        }
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
        do {
            try beginRecording(mode: .pasteAtCursor)
        } catch CallerDictationError.busy(let state) {
            logger.warning("Hearsay is \(state.rawValue), ignoring hotkey start")
            diagnosticLog.event("recording.start.ignored", level: .warning, fields: ["state": state.rawValue])
        } catch CallerDictationError.transcriberUnavailable {
            logger.error("No transcriber available!")
            diagnosticLog.event("recording.start.failed", level: .error, fields: ["reason": "transcriber_unavailable"])
            showError("No model installed")
            showOnboardingForSetup()
        } catch CallerDictationError.microphonePermissionMissing {
            logger.error("Microphone permission not granted")
            diagnosticLog.event("recording.start.failed", level: .error, fields: ["reason": "microphone_permission_missing"])
            showError("No mic access")
            showOnboardingForSetup()
        } catch {
            logger.error("Failed to start recording: \(error.localizedDescription)")
            diagnosticLog.event("recording.start.failed", level: .error, fields: diagnosticLog.errorFields(for: error))
            showError("Start failed")
        }
    }

    private func beginRecording(mode: DictationMode) throws {
        guard !isRecording && !isTranscribing else {
            throw CallerDictationError.busy(state: currentDictationState)
        }

        if case .pasteAtCursor = mode, activeCallerRequest != nil {
            throw CallerDictationError.busy(state: currentDictationState)
        }

        if transcriber == nil && !configureTranscriberIfAvailable() {
            throw CallerDictationError.transcriberUnavailable
        }
        
        // Check microphone permission before recording
        let micStatus = PermissionsManager.checkMicrophone()
        guard micStatus == .granted else {
            logger.error("Microphone permission not granted: \(String(describing: micStatus))")
            diagnosticLog.event("recording.start.failed", level: .error, fields: ["reason": "microphone_permission_missing"])
            throw CallerDictationError.microphonePermissionMissing
        }
        
        isRecording = true
        activeDictationMode = mode
        logger.info("=== START RECORDING ===")
        diagnosticLog.event("recording.start", fields: [
            "mode": mode.diagnosticName,
            "clipboard_capture_enabled": "\(ClipboardManager.isFeatureEnabled)"
        ])
        
        // Play start sound
        SoundPlayer.shared.play(.recordingStart)
        
        // Cancel any pending dismiss from previous transcription/error
        logger.info("Canceling pending dismiss, currentDismissID was: \(self.currentDismissID?.uuidString ?? "nil")")
        cancelPendingIndicatorDismiss()
        
        // Invalidate UI updates from in-flight transcription tasks.
        logger.info("Invalidating transcription ID, was: \(self.currentTranscriptionID?.uuidString ?? "nil")")
        currentTranscriptionID = nil
        
        // Start screenshot + clipboard sessions (both interleave into the transcript).
        // Clipboard capture is opt-in (off by default) to avoid capturing secrets.
        ScreenshotManager.shared.startSession()
        let captureClipboard = ClipboardManager.isFeatureEnabled
        if captureClipboard {
            ClipboardManager.shared.startSession()
        }
        hotkeyMonitor.enableScreenshotHotKey()
        
        // Recreate the panel each recording start to prevent occasional "invisible but visible=true" window state.
        refreshRecordingUIWindow()
        
        // Update UI - always show figure count indicator (works in both hold and toggle mode)
        let isToggleMode = hotkeyMonitor.state == .recordingToggle
        recordingIndicator.figureCount = 0
        recordingIndicator.showFigureCount = true  // Always show, screenshots work in both modes
        recordingIndicator.clipCount = 0
        recordingIndicator.showClipCount = captureClipboard  // Badge appears once a copy is captured

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

    private func captureFullScreen() {
        guard isRecording else {
            logger.warning("Not recording, ignoring full-screen screenshot request")
            return
        }

        logger.info("Capturing full screen...")
        ScreenshotManager.shared.captureFullScreen()
    }
    
    private func stopRecording() {
        guard isRecording else { 
            logger.warning("Not recording, ignoring stop")
            return 
        }
        
        logger.info("=== STOP RECORDING ===")
        diagnosticLog.event("recording.stop_requested")
        isRecording = false
        
        // Play stop sound
        SoundPlayer.shared.play(.recordingStop)
        statusBar.showRecordingState(false)
        
        // End screenshot + clipboard sessions and disable hotkey
        let figures = ScreenshotManager.shared.endSession()
        let clips = ClipboardManager.shared.endSession()
        hotkeyMonitor.disableScreenshotHotKey()
        recordingIndicator.showFigureCount = false
        recordingIndicator.showClipCount = false

        logger.info("Recording stopped with \(figures.count) screenshot(s), \(clips.count) clip(s)")
        diagnosticLog.event("recording.assets_captured", fields: [
            "figure_count": "\(figures.count)",
            "clip_count": "\(clips.count)"
        ])
        
        // Stop recording and get audio file
        let stopResult = audioRecorder.stop()
        guard let audioURL = stopResult.url else {
            switch stopResult.reason {
            case .cancelledBeforeReady:
                var fields: [String: String] = [
                    "stop_reason": "cancelled_before_ready",
                    "startup_last_phase": stopResult.startupLastPhase ?? "unknown",
                    "startup_timed_out": "\(stopResult.startupTimedOut)"
                ]
                if let elapsed = stopResult.startupElapsedSeconds {
                    fields["startup_elapsed_seconds"] = String(format: "%.2f", elapsed)
                }
                if stopResult.startupTimedOut {
                    logger.error("Recording stopped before audio engine was ready after startup timeout")
                    fields["likely_reason"] = "coreaudio_startup_stalled"
                    diagnosticLog.event("recording.startup_stalled", level: .error, fields: fields)
                    recordingIndicator.setState(.error("Mic stalled"))
                    failActiveCallerDictation("Microphone startup stalled")
                } else {
                    logger.info("Recording stopped before audio engine was ready; treating as too short, not recorder failure")
                    fields["likely_reason"] = "released_before_audio_ready"
                    diagnosticLog.event("recording.too_short", level: .warning, fields: fields)
                    recordingIndicator.setState(.error("Too short"))
                    failActiveCallerDictation("Recording was too short")
                }
                dismissIndicatorAfterDelay()
            case .notRecording:
                logger.warning("audioRecorder.stop() called while recorder was not recording")
                diagnosticLog.event("recording.stop_ignored", level: .warning, fields: ["stop_reason": "not_recording"])
                recordingWindow.fadeOut()
                failActiveCallerDictation("Recording was not active")
            case .errorState:
                logger.error("audioRecorder.stop() returned nil from recorder error state")
                diagnosticLog.event("recording.stop_failed", level: .error, fields: ["stop_reason": "error_state"])
                handleRecorderStopFailure()
                failActiveCallerDictation("Recording failed")
            case .completed:
                logger.error("audioRecorder.stop() completed without an audio URL")
                diagnosticLog.event("recording.stop_failed", level: .error, fields: ["stop_reason": "missing_audio_url"])
                handleRecorderStopFailure()
                failActiveCallerDictation("Recording failed")
            }
            return
        }
        
        // Check if microphone captured silence (possible Core Audio issue)
        if stopResult.wasSilent {
            logger.error("Audio was silent! Peak level: \(stopResult.peakLevel)")
            diagnosticLog.event("recording.silent_audio", level: .error, fields: [
                "peak_level": "\(stopResult.peakLevel)"
            ])
            recordingIndicator.setState(.error("No audio"))
            dismissIndicatorAfterDelay(extended: true)
            failActiveCallerDictation("No audio captured")
            return
        }
        
        logger.info("Audio saved to \(audioURL.path), peak level: \(stopResult.peakLevel)")
        
        // Check file exists and size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path) {
            let size = attrs[.size] as? Int64 ?? 0
            logger.info("Audio file size: \(size) bytes")
            diagnosticLog.event("recording.audio_ready", fields: [
                "size_bytes": "\(size)",
                "peak_level": "\(stopResult.peakLevel)"
            ])
        }
        
        // Show transcribing state
        logger.info("Setting indicator state to .transcribing")
        recordingIndicator.setState(.transcribing)
        let transcriptionID = UUID()
        currentTranscriptionID = transcriptionID
        isTranscribing = true
        if let requestId = activeCallerRequest?.id {
            localAPIServer?.publishState(requestId: requestId, state: .transcribing)
        }
        
        logger.info("Starting transcription with ID: \(transcriptionID.uuidString)")
        diagnosticLog.event("transcription.start", fields: [
            "id": String(transcriptionID.uuidString.prefix(8)),
            "figure_count": "\(figures.count)",
            "clip_count": "\(clips.count)"
        ])
        
        // Transcribe
        Task {
            await transcribe(audioURL: audioURL, transcriptionID: transcriptionID, figures: figures, clips: clips)
        }
    }
    
    private func transcribe(audioURL: URL, transcriptionID: UUID, figures: [CapturedFigure] = [], clips: [CapturedClip] = []) async {
        guard let transcriber = transcriber else {
            await MainActor.run {
                logger.info("Transcription \(transcriptionID.uuidString.prefix(8)): no model, checking if stale...")
                guard self.currentTranscriptionID == transcriptionID else {
                    logger.info("Transcription \(transcriptionID.uuidString.prefix(8)): STALE (current: \(self.currentTranscriptionID?.uuidString ?? "nil")), skipping UI update")
                    diagnosticLog.event("transcription.stale", level: .warning, fields: [
                        "id": String(transcriptionID.uuidString.prefix(8)),
                        "phase": "no_model"
                    ])
                    return
                }
                logger.info("Transcription \(transcriptionID.uuidString.prefix(8)): showing error and scheduling dismiss")
                diagnosticLog.event("transcription.failed", level: .error, fields: [
                    "id": String(transcriptionID.uuidString.prefix(8)),
                    "reason": "no_model"
                ])
                self.recordingIndicator.setState(.error("No model"))
                self.dismissIndicatorAfterDelay()
                self.failActiveCallerDictation("No transcription model is available")
            }
            return
        }
        
        // Get audio duration for history
        let audioDuration = getAudioDuration(url: audioURL)

        // Attempt transcription, auto-retrying once on a hard failure (transient model
        // errors happen). Empty-output is already retried inside computeTranscript.
        var output: TranscriptionOutput? = nil
        var lastError: Error? = nil
        for attempt in 1...2 {
            do {
                output = try await computeTranscript(audioURL: audioURL, figures: figures, clips: clips, audioDuration: audioDuration, transcriptionID: transcriptionID, transcriber: transcriber)
                break
            } catch {
                lastError = error
                logger.warning("Transcription \(transcriptionID.uuidString.prefix(8)): attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt == 1 {
                    diagnosticLog.event("transcription.auto_retry", level: .warning, fields: [
                        "id": String(transcriptionID.uuidString.prefix(8)),
                        "reason": "hard_failure"
                    ])
                }
            }
        }

        if let output = output {
            await MainActor.run {
                logger.info("Transcription \(transcriptionID.uuidString.prefix(8)): SUCCESS, checking if stale...")
                guard self.currentTranscriptionID == transcriptionID else {
                    logger.info("Transcription \(transcriptionID.uuidString.prefix(8)): STALE (current: \(self.currentTranscriptionID?.uuidString ?? "nil")), skipping delivery")
                    diagnosticLog.event("transcription.stale", level: .warning, fields: [
                        "id": String(transcriptionID.uuidString.prefix(8)),
                        "phase": "delivery"
                    ])
                    return
                }

                switch self.activeDictationMode {
                case .pasteAtCursor:
                    self.deliverTranscriptToFocusedApp(output.finalText)
                case .returnToCaller(let requestId):
                    self.localAPIServer?.publishResult(
                        .completed(requestId: requestId, text: output.finalText, durationSeconds: audioDuration)
                    )
                    SoundPlayer.shared.play(.paste)
                }

                // In dev mode, preserve the audio recording
                var savedAudioPath: String? = nil
                if Self.isDevMode {
                    savedAudioPath = self.preserveRecording(audioURL: audioURL)
                }

                // Save to history
                HistoryStore.shared.add(text: output.finalText, durationSeconds: audioDuration, audioFilePath: savedAudioPath)
                diagnosticLog.event("transcription.success", fields: [
                    "id": String(transcriptionID.uuidString.prefix(8)),
                    "duration_seconds": String(format: "%.2f", audioDuration),
                    "raw_length": "\(output.raw.count)",
                    "processed_length": "\(output.postProcessed.count)",
                    "final_length": "\(output.finalText.count)",
                    "delivery": self.activeDictationMode.diagnosticName
                ])

                self.clearActiveDictationSession()

                // Show success
                logger.info("Transcription \(transcriptionID.uuidString.prefix(8)): showing done and scheduling dismiss")
                self.recordingIndicator.setState(.done)
                self.dismissIndicatorAfterDelay()
            }
            logger.info("Transcription complete; output length: \(output.raw.count)")
        } else {
            await MainActor.run {
                self.handleTranscriptionFailure(audioURL: audioURL, audioDuration: audioDuration, transcriptionID: transcriptionID, error: lastError)
            }
            logger.error("Transcription error: \(lastError?.localizedDescription ?? "unknown")")
        }

        // Clean up temp file (a copy has already been preserved on failure)
        try? FileManager.default.removeItem(at: audioURL)
    }

    private struct TranscriptionOutput {
        let raw: String
        let postProcessed: String
        let finalText: String
    }

    /// Run the full transcription pipeline (split/interleave + post-processing) and
    /// return the produced text. Reused by the initial attempt, the auto-retry, and the
    /// manual retry of a saved failed recording. Throws on failure.
    private func computeTranscript(audioURL: URL, figures: [CapturedFigure], clips: [CapturedClip], audioDuration: Double, transcriptionID: UUID, transcriber: any SpeechTranscribing) async throws -> TranscriptionOutput {
        let text: String

        if figures.isEmpty && clips.isEmpty {
            // Simple case: nothing captured mid-recording, just transcribe
            do {
                text = try await transcriber.transcribe(audioURL: audioURL)
            } catch SpeechTranscriptionError.noOutput {
                    // qwen_asr can intermittently return empty output.
                    // Retry once before fallback.
                    logger.warning("No transcription output on first attempt, retrying once")
                    diagnosticLog.event("transcription.retry", level: .warning, fields: [
                        "id": String(transcriptionID.uuidString.prefix(8)),
                        "reason": "no_output"
                    ])
                    do {
                        text = try await transcriber.transcribe(audioURL: audioURL)
                    } catch SpeechTranscriptionError.noOutput {
                        // Fallback: chunk audio and transcribe piece-by-piece.
                        logger.warning("Retry also returned no output, attempting chunked fallback")
                        diagnosticLog.event("transcription.chunked_fallback", level: .warning, fields: [
                            "id": String(transcriptionID.uuidString.prefix(8)),
                            "audio_duration_seconds": String(format: "%.2f", audioDuration)
                        ])
                        let chunkSeconds: Double = 2.0
                        let splitTimes = stride(from: chunkSeconds, to: audioDuration, by: chunkSeconds).map { $0 }
                        
                        guard let chunks = AudioSplitter.splitWAV(at: audioURL, timestamps: splitTimes) else {
                            throw SpeechTranscriptionError.noOutput
                        }
                        
                        var parts: [String] = []
                        for (index, chunk) in chunks.enumerated() {
                            do {
                                let part = try await transcriber.transcribe(audioURL: chunk).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !part.isEmpty {
                                    parts.append(part)
                                }
                            } catch SpeechTranscriptionError.noOutput {
                                logger.info("Chunk \(index) produced no output during fallback")
                                diagnosticLog.event("transcription.chunk_no_output", level: .warning, fields: [
                                    "id": String(transcriptionID.uuidString.prefix(8)),
                                    "chunk_index": "\(index)"
                                ])
                            }
                        }
                        AudioSplitter.cleanupSegments(chunks)
                        
                        guard !parts.isEmpty else {
                            throw SpeechTranscriptionError.noOutput
                        }
                        text = parts.joined(separator: " ")
                    }
                }
            } else {
                // Interleaved case: weave screenshots and copied text into the transcript
                // at the points they occurred. Split audio at the combined timeline.
                let timeline = TranscriptInterleaver.buildTimeline(figures: figures, clips: clips)
                let timestamps = TranscriptInterleaver.splitTimestamps(for: timeline)
                logger.info("Splitting audio at timestamps: \(timestamps)")
                diagnosticLog.event("transcription.split_audio", fields: [
                    "id": String(transcriptionID.uuidString.prefix(8)),
                    "split_count": "\(timestamps.count)"
                ])

                if let segments = AudioSplitter.splitWAV(at: audioURL, timestamps: timestamps) {
                    logger.info("Audio split into \(segments.count) segments")
                    diagnosticLog.event("transcription.audio_split", fields: [
                        "id": String(transcriptionID.uuidString.prefix(8)),
                        "segment_count": "\(segments.count)"
                    ])
                    var transcripts: [String] = []

                    for (index, segment) in segments.enumerated() {
                        do {
                            let segmentText = try await transcriber.transcribe(audioURL: segment)
                            transcripts.append(segmentText)
                        } catch SpeechTranscriptionError.noOutput {
                            // Short/silent segment is expected sometimes when splitting at
                            // insertion boundaries. Keep placeholder so alignment stays correct.
                            logger.info("Segment \(index) produced no transcription output; continuing")
                            diagnosticLog.event("transcription.segment_no_output", level: .warning, fields: [
                                "id": String(transcriptionID.uuidString.prefix(8)),
                                "segment_index": "\(index)"
                            ])
                            transcripts.append("")
                        }
                    }

                    // Clean up segment files
                    AudioSplitter.cleanupSegments(segments)

                    // Interleave figure references and clip placeholders.
                    text = TranscriptInterleaver.interleave(segments: transcripts, timeline: timeline)
                } else {
                    // Fallback: couldn't split. Transcribe whole file, then append clip
                    // placeholders and a figure footer (positions are lost without a split).
                    logger.warning("Failed to split audio, transcribing whole file")
                    diagnosticLog.event("transcription.split_failed", level: .warning, fields: [
                        "id": String(transcriptionID.uuidString.prefix(8))
                    ])
                    let rawText = try await transcriber.transcribe(audioURL: audioURL)
                    var body = rawText
                    for index in clips.indices {
                        body += " " + TranscriptInterleaver.clipPlaceholder(index)
                    }
                    let footer = TranscriptInterleaver.figureFooter(for: timeline)
                    text = footer.isEmpty ? body : body + "\n\n" + footer
                }
            }
            
            // Run LLM post processing if enabled.
            let postProcessedText: String
            if CleanupModelDownloader.shared.isEnabled, self.cleanupManager.isReady {
                logger.info("Running post processing on transcription...")
                diagnosticLog.event("cleanup.start", fields: [
                    "id": String(transcriptionID.uuidString.prefix(8)),
                    "input_length": "\(text.count)"
                ])
                if let cleaned = await self.cleanupManager.clean(text: text) {
                    logger.info("Post processing completed; output length: \(cleaned.count)")
                    diagnosticLog.event("cleanup.success", fields: [
                        "id": String(transcriptionID.uuidString.prefix(8)),
                        "output_length": "\(cleaned.count)"
                    ])
                    postProcessedText = cleaned
                } else {
                    logger.info("Post processing returned nil, using original text")
                    diagnosticLog.event("cleanup.fallback_to_original", level: .warning, fields: [
                        "id": String(transcriptionID.uuidString.prefix(8))
                    ])
                    postProcessedText = text
                }
            } else {
                postProcessedText = text
            }

            // Swap clip placeholders for the verbatim copied text AFTER all cleanup,
            // so copied content (code, names) is reproduced exactly.
            // Swap clip placeholders for the verbatim copied text AFTER all cleanup,
            // so copied content (code, names) is reproduced exactly.
            let processedText = TranscriptProcessor.process(postProcessedText)
            let finalText = TranscriptInterleaver.substituteClips(processedText, clips: clips)
            return TranscriptionOutput(raw: text, postProcessed: postProcessedText, finalText: finalText)
    }

    /// Handle a transcription that failed even after the auto-retry: preserve the
    /// audio so nothing is lost, and (for normal dictation) record a failed history
    /// entry the user can retry later from the History window.
    @MainActor
    private func handleTranscriptionFailure(audioURL: URL, audioDuration: Double, transcriptionID: UUID, error: Error?) {
        logger.info("Transcription \(transcriptionID.uuidString.prefix(8)): ERROR, checking if stale...")
        guard self.currentTranscriptionID == transcriptionID else {
            logger.info("Transcription \(transcriptionID.uuidString.prefix(8)): STALE (current: \(self.currentTranscriptionID?.uuidString ?? "nil")), skipping UI update")
            diagnosticLog.event("transcription.stale", level: .warning, fields: [
                "id": String(transcriptionID.uuidString.prefix(8)),
                "phase": "error"
            ])
            return
        }
        logger.info("Transcription \(transcriptionID.uuidString.prefix(8)): showing error and scheduling dismiss")
        if let error = error {
            var fields = diagnosticLog.errorFields(for: error)
            fields["id"] = String(transcriptionID.uuidString.prefix(8))
            diagnosticLog.event("transcription.failed", level: .error, fields: fields)
        }

        // Preserve the recording so it isn't wasted; record a retryable entry.
        let isPasteMode: Bool
        if case .pasteAtCursor = self.activeDictationMode { isPasteMode = true } else { isPasteMode = false }
        if isPasteMode, let savedPath = self.preserveRecording(audioURL: audioURL) {
            HistoryStore.shared.add(text: "", durationSeconds: audioDuration, audioFilePath: savedPath, failed: true)
            logger.info("Saved failed recording for retry: \(savedPath)")
            diagnosticLog.event("transcription.failed_audio_saved", level: .warning, fields: [
                "id": String(transcriptionID.uuidString.prefix(8))
            ])
        }

        self.recordingIndicator.setState(.error("Failed"))
        self.scheduleIndicatorDismiss(after: 2.0)
        self.failActiveCallerDictation(error?.localizedDescription ?? "Transcription failed")
    }

    /// Re-run transcription on a saved failed recording and, on success, update the
    /// history entry in place. Transcribes the whole file (figure positions aren't
    /// persisted, so retries recover the spoken text without figure interleaving).
    func retryFailedTranscription(_ item: TranscriptionItem, completion: @escaping (Bool) -> Void) {
        guard let path = item.audioFilePath, FileManager.default.fileExists(atPath: path) else {
            logger.warning("Retry requested but audio missing for item \(item.id)")
            completion(false)
            return
        }
        if transcriber == nil { _ = configureTranscriberIfAvailable() }
        guard let transcriber = transcriber else {
            completion(false)
            return
        }

        let audioURL = URL(fileURLWithPath: path)
        let duration = item.durationSeconds
        let retryID = UUID()
        Task {
            do {
                let output = try await computeTranscript(audioURL: audioURL, figures: [], clips: [], audioDuration: duration, transcriptionID: retryID, transcriber: transcriber)
                await MainActor.run {
                    HistoryStore.shared.update(item.updating(text: output.finalText, failed: nil))
                    completion(true)
                }
                logger.info("Retry succeeded for item \(item.id)")
            } catch {
                logger.error("Retry transcription failed: \(error.localizedDescription)")
                await MainActor.run { completion(false) }
            }
        }
    }

    private var currentDictationState: DictationState {
        if isRecording {
            return .recording
        }
        if isTranscribing {
            return .transcribing
        }
        if transcriber == nil && !configureTranscriberIfAvailable() {
            return .unavailable
        }
        return .idle
    }

    private func deliverTranscriptToFocusedApp(_ finalText: String) {
        // Insert text based on clipboard/paste preferences
        let copyEnabled = UserDefaults.standard.object(forKey: "copyToClipboard") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "copyToClipboard")
        let pasteEnabled = UserDefaults.standard.object(forKey: "autoPasteAtCursor") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "autoPasteAtCursor")

        if copyEnabled && pasteEnabled {
            TextInserter.insert(finalText)
        } else if copyEnabled {
            TextInserter.copyToClipboard(finalText)
        } else if pasteEnabled {
            TextInserter.insertWithoutClipboard(finalText)
        }
        SoundPlayer.shared.play(.paste)
    }

    private func failActiveCallerDictation(_ message: String) {
        if let requestId = activeCallerRequest?.id {
            localAPIServer?.publishError(requestId: requestId, message: message)
        }
        clearActiveDictationSession()
    }

    private func clearActiveDictationSession() {
        isTranscribing = false
        currentTranscriptionID = nil
        activeCallerRequest = nil
        activeDictationMode = .pasteAtCursor
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
        diagnosticLog.event("indicator.dismiss_scheduled", fields: [
            "dismiss_id": String(dismissID.uuidString.prefix(8)),
            "delay_seconds": String(format: "%.2f", delay)
        ])
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            logger.info("Dismiss \(dismissID.uuidString.prefix(8)) firing...")
            diagnosticLog.event("indicator.dismiss_fired", fields: [
                "dismiss_id": String(dismissID.uuidString.prefix(8)),
                "is_recording": "\(self.isRecording)",
                "state": "\(self.recordingIndicator.state)"
            ])
            
            // Check if this dismiss was cancelled (a new recording started)
            guard self.currentDismissID == dismissID else {
                logger.info("Dismiss \(dismissID.uuidString.prefix(8)) cancelled (current: \(self.currentDismissID?.uuidString ?? "nil"))")
                diagnosticLog.event("indicator.dismiss_cancelled", level: .warning, fields: [
                    "dismiss_id": String(dismissID.uuidString.prefix(8)),
                    "reason": "id_mismatch"
                ])
                return
            }
            
            // Never hide while actively recording
            if self.isRecording {
                logger.info("Dismiss \(dismissID.uuidString.prefix(8)) skipped - recording is active")
                diagnosticLog.event("indicator.dismiss_skipped", level: .warning, fields: [
                    "dismiss_id": String(dismissID.uuidString.prefix(8)),
                    "reason": "recording_active"
                ])
                return
            }
            
            // Final check: only dismiss if we're in a done/error state
            // This prevents dismissing if a new recording started between scheduling and execution
            switch self.recordingIndicator.state {
            case .done, .error:
                logger.info("Dismiss \(dismissID.uuidString.prefix(8)) proceeding - state is final, calling fadeOut")
                diagnosticLog.event("indicator.dismiss_executing", fields: [
                    "dismiss_id": String(dismissID.uuidString.prefix(8))
                ])
                break
            case .recording, .transcribing:
                logger.info("Dismiss \(dismissID.uuidString.prefix(8)) skipped - state is not final")
                diagnosticLog.event("indicator.dismiss_skipped", level: .warning, fields: [
                    "dismiss_id": String(dismissID.uuidString.prefix(8)),
                    "reason": "state_not_final"
                ])
                return
            }
            
            self.recordingWindow.fadeOut()
            self.indicatorDismissWorkItem = nil
            self.currentDismissID = nil
        }
        
        indicatorDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
    
    private func dismissIndicatorAfterDelay(extended: Bool = false) {
        let delay = extended ? 3.0 : Constants.doneDisplayDuration
        scheduleIndicatorDismiss(after: delay)
    }
    
    // MARK: - Dev Mode
    
    private func preserveRecording(audioURL: URL) -> String? {
        let dir = Constants.recordingsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "recording_\(formatter.string(from: Date())).wav"
        let destURL = dir.appendingPathComponent(filename)
        
        do {
            try FileManager.default.copyItem(at: audioURL, to: destURL)
            logger.info("Saved recording to \(destURL.path)")
            return destURL.path
        } catch {
            logger.error("Failed to save recording: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Error Handling

    private func handleRecorderStopFailure() {
        let now = Date()
        if let last = lastRecorderStopFailureAt, now.timeIntervalSince(last) <= 30 {
            recentRecorderStopFailures += 1
        } else {
            recentRecorderStopFailures = 1
        }
        lastRecorderStopFailureAt = now

        diagnosticLog.event("recording.recorder_reset", level: .error, fields: [
            "recent_failures": "\(recentRecorderStopFailures)"
        ])

        // Recreate recorder to clear any transient AVAudioEngine/CoreAudio bad state.
        setupAudioRecorder()
        recordingWindow.fadeOut()

        // After repeated failures in a short window, do a one-time self-relaunch.
        if recentRecorderStopFailures >= 2, !didAutoRelaunchForRecorderFailure {
            didAutoRelaunchForRecorderFailure = true
            relaunchAppAfterRecorderFailure()
            return
        }

        showError("Recorder reset. Try again")
    }

    private func relaunchAppAfterRecorderFailure() {
        logger.error("Repeated recorder failures detected; relaunching app")
        diagnosticLog.event("app.relaunch_requested", level: .error, fields: [
            "reason": "repeated_recorder_failures"
        ])

        recordingIndicator.setState(.error("Restarting app..."))
        recordingWindow.fadeIn()

        let appURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { [weak self] _, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let error {
                    logger.error("Failed to relaunch app: \(error.localizedDescription)")
                    diagnosticLog.event("app.relaunch_failed", level: .error, fields: diagnosticLog.errorFields(for: error))
                    self.showError("Please restart Hearsay")
                    self.didAutoRelaunchForRecorderFailure = false
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    NSApp.terminate(nil)
                }
            }
        }
    }
    
    private func showError(_ message: String) {
        recordingIndicator.setState(.error(message))
        recordingWindow.fadeIn()
        scheduleIndicatorDismiss(after: 2.0)
    }

    // MARK: - Diagnostics

    private func openDiagnosticLog() {
        do {
            let snapshotURL = try DiagnosticLog.shared.writeSnapshotFile()
            let bytes = (try? FileManager.default.attributesOfItem(atPath: snapshotURL.path)[.size] as? NSNumber)?.intValue ?? 0
            diagnosticLog.event("diagnostics.opened", fields: [
                "bytes": "\(bytes)"
            ])
            NSWorkspace.shared.open(snapshotURL)
        } catch {
            diagnosticLog.event("diagnostics.open_failed", level: .error, fields: diagnosticLog.errorFields(for: error))
            showDiagnosticAlert(
                title: "Could Not Open Logs",
                message: "Hearsay could not create the diagnostic log snapshot."
            )
        }
    }

    private func copyDiagnosticLogs() {
        let text = DiagnosticLog.shared.snapshotText()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        diagnosticLog.event("diagnostics.copied", fields: [
            "bytes": "\(text.utf8.count)"
        ])
        showDiagnosticAlert(
            title: "Diagnostic Logs Copied",
            message: "The last day of metadata-only Hearsay diagnostic logs is on your clipboard. Raw transcripts, audio, clipboard text, screenshots, and prompts are not included."
        )
    }

    private func emailDiagnosticLogs() {
        do {
            let snapshotURL = try DiagnosticLog.shared.writeSnapshotFile()
            let bytes = (try? FileManager.default.attributesOfItem(atPath: snapshotURL.path)[.size] as? NSNumber)?.intValue ?? 0
            diagnosticLog.event("diagnostics.email_requested", fields: [
                "bytes": "\(bytes)"
            ])

            if let service = NSSharingService(named: .composeEmail),
               service.canPerform(withItems: [snapshotURL]) {
                service.subject = "Hearsay Diagnostic Logs"
                service.perform(withItems: [snapshotURL])
            } else {
                let text = try String(contentsOf: snapshotURL, encoding: .utf8)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                showDiagnosticAlert(
                    title: "Diagnostic Logs Copied",
                    message: "Mail sharing is not available, so the metadata-only diagnostic log was copied to your clipboard instead."
                )
            }
        } catch {
            diagnosticLog.event("diagnostics.email_failed", level: .error, fields: diagnosticLog.errorFields(for: error))
            showDiagnosticAlert(
                title: "Could Not Prepare Logs",
                message: "Hearsay could not create the diagnostic log snapshot."
            )
        }
    }

    private func clearDiagnosticLogs() {
        DiagnosticLog.shared.clear()
        diagnosticLog.event("diagnostics.cleared")
        showDiagnosticAlert(
            title: "Diagnostic Logs Cleared",
            message: "The local Hearsay diagnostic log has been cleared."
        )
    }

    private func showDiagnosticAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    // MARK: - Updates
    
    private func checkForUpdates() {
        Task {
            let result = await UpdateChecker.check()
            await MainActor.run {
                switch result {
                case .updateAvailable(let info):
                    let alert = NSAlert()
                    alert.messageText = "Update Available"
                    alert.informativeText = "Hearsay \(info.version) is available. You're currently on \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown").\n\n\(info.releaseNotes)"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "View on GitHub")
                    alert.addButton(withTitle: "Later")
                    
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(info.htmlURL)
                    }
                    
                case .upToDate(let currentVersion):
                    let alert = NSAlert()
                    alert.messageText = "You're Up to Date"
                    alert.informativeText = "Hearsay \(currentVersion) is the latest version."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    
                case .error(let message):
                    let alert = NSAlert()
                    alert.messageText = "Update Check Failed"
                    alert.informativeText = "Couldn't check for updates: \(message)"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }
    
    // MARK: - Windows
    
    private func showHistory() {
        ensureSettingsWindowController().show(tab: .history)
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
            // Stop an in-flight recording before pausing hotkeys for shortcut capture,
            // otherwise the indicator can get stuck in recording state.
            if self?.isRecording == true {
                self?.stopRecording()
            }
            // Stop hotkey monitor while settings is open to allow shortcut recording
            self?.hotkeyMonitor.stop()
        }
        controller.onWindowClosed = { [weak self] in
            // Restart hotkey monitor when settings closes
            self?.tryStartHotkeyMonitor()
        }
        controller.onModelChanged = { [weak self] in
            guard let self else { return }
            let hasTranscriber = self.configureTranscriberIfAvailable()
            if hasTranscriber {
                self.prewarmActiveTranscriber()
            }
        }
        controller.onRetryTranscription = { [weak self] item, completion in
            self?.retryFailedTranscription(item, completion: completion)
        }
        controller.isTranscriptionInProgress = { [weak self] in
            self?.isTranscribing ?? false
        }
        controller.onCleanupSettingsChanged = { [weak self] in
            guard let self = self else { return }
            if CleanupModelDownloader.shared.isEnabled && CleanupModelDownloader.shared.isModelInstalled() {
                Task {
                    await self.cleanupManager.loadModel()
                }
            } else {
                self.cleanupManager.unloadModel()
            }
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
    
    private func showModels() {
        ensureSettingsWindowController().show(tab: .models)
    }
}

// MARK: - Local API

extension AppDelegate: HearsayLocalAPIServerDelegate {
    @MainActor
    func localAPIState() -> DictationState {
        currentDictationState
    }

    @MainActor
    func startCallerDictation(request: DictationRequest) throws {
        guard activeCallerRequest == nil else {
            throw CallerDictationError.busy(state: currentDictationState)
        }

        activeCallerRequest = request
        do {
            try beginRecording(mode: request.mode)
            localAPIServer?.publishState(requestId: request.id, state: .recording)
            logger.info("Started caller dictation \(request.id.uuidString) for \(request.caller)")
            diagnosticLog.event("caller_dictation.start", fields: [
                "request_id": String(request.id.uuidString.prefix(8)),
                "auto_stop": "\(request.autoStop)",
                "metadata_keys": "\(request.metadata.keys.count)"
            ])
        } catch {
            clearActiveDictationSession()
            diagnosticLog.event("caller_dictation.start_failed", level: .error, fields: diagnosticLog.errorFields(for: error))
            throw error
        }
    }

    @MainActor
    func stopCallerDictation(requestId: UUID) throws {
        guard activeCallerRequest?.id == requestId else {
            throw CallerDictationError.notFound
        }

        guard isRecording else {
            throw CallerDictationError.busy(state: currentDictationState)
        }

        stopRecording()
    }

    @MainActor
    func cancelCallerDictation(requestId: UUID) throws {
        guard activeCallerRequest?.id == requestId else {
            throw CallerDictationError.notFound
        }

        if isRecording {
            isRecording = false
            statusBar.showRecordingState(false)
            _ = audioRecorder.stop()
            _ = ScreenshotManager.shared.endSession()
            _ = ClipboardManager.shared.endSession()
            hotkeyMonitor.disableScreenshotHotKey()
            recordingIndicator.showFigureCount = false
            recordingIndicator.showClipCount = false
        }

        if isTranscribing {
            currentTranscriptionID = nil
        }

        localAPIServer?.publishResult(.cancelled(requestId: requestId))
        clearActiveDictationSession()
        recordingIndicator.setState(.error("Cancelled"))
        dismissIndicatorAfterDelay()
        logger.info("Cancelled caller dictation \(requestId.uuidString)")
        diagnosticLog.event("caller_dictation.cancelled", level: .warning, fields: [
            "request_id": String(requestId.uuidString.prefix(8))
        ])
    }
}
