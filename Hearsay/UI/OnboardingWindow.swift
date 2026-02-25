import AppKit
import Combine

/// Onboarding window shown on first launch for permissions and model download.
final class OnboardingWindowController: NSWindowController {
    
    private var permissionsView: PermissionsContentView!
    private var modelDownloadView: OnboardingContentView!
    private var cancellables = Set<AnyCancellable>()
    var onComplete: (() -> Void)?
    
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up Hearsay"
        window.center()
        window.isReleasedWhenClosed = false
        
        self.init(window: window)
        setupUI()
    }
    
    private func setupUI() {
        showPermissionsView()
    }
    
    private func showPermissionsView() {
        window?.title = "Set Up Hearsay"
        permissionsView = PermissionsContentView(frame: window!.contentView!.bounds)
        permissionsView.autoresizingMask = [.width, .height]
        permissionsView.onContinue = { [weak self] in
            self?.showModelDownload(animated: true)
        }
        window?.contentView = permissionsView
    }
    
    private func showModelDownload(animated: Bool) {
        window?.title = "Download Model"
        modelDownloadView = OnboardingContentView(frame: window!.contentView!.bounds)
        modelDownloadView.autoresizingMask = [.width, .height]
        modelDownloadView.onComplete = { [weak self] in
            self?.window?.close()
            self?.onComplete?()
        }
        
        if animated, window?.contentView === permissionsView {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.permissionsView.animator().alphaValue = 0
            } completionHandler: {
                self.window?.contentView = self.modelDownloadView
                self.modelDownloadView.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    self.modelDownloadView.animator().alphaValue = 1
                }
            }
        } else {
            window?.contentView = modelDownloadView
        }
    }
    
    func showSetup() {
        showPermissionsView()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func showModelManager() {
        showModelDownload(animated: false)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Permissions Content View

private class PermissionsContentView: NSView {
    
    var onContinue: (() -> Void)?
    
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let permissionsStack = NSStackView()
    private let continueButton = NSButton()
    
    private var microphoneRow: PermissionRow!
    private var accessibilityRow: PermissionRow!
    private var screenRecordingRow: PermissionRow!
    
    private var permissionCheckTimer: Timer?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        startPermissionChecking()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        permissionCheckTimer?.invalidate()
    }
    
    private func setupUI() {
        wantsLayer = true
        
        // Title
        titleLabel.stringValue = "Set Up Hearsay"
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.alignment = .center
        addSubview(titleLabel)
        
        // Subtitle
        subtitleLabel.stringValue = "Hearsay needs a few permissions to work properly."
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        addSubview(subtitleLabel)
        
        // Permission rows
        microphoneRow = PermissionRow(
            title: "Microphone",
            description: "Records your voice for transcription",
            buttonTitle: "Allow",
            onAction: { [weak self] in
                Task {
                    switch PermissionsManager.checkMicrophone() {
                    case .notDetermined:
                        _ = await PermissionsManager.requestMicrophone()
                    case .denied:
                        PermissionsManager.openMicrophoneSettings()
                    case .granted:
                        break
                    }
                    await MainActor.run {
                        self?.updatePermissionStates()
                    }
                }
            }
        )
        
        accessibilityRow = PermissionRow(
            title: "Accessibility",
            description: "Handles hotkeys and pasting text",
            buttonTitle: "Open Settings",
            onAction: {
                PermissionsManager.requestAccessibility()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    PermissionsManager.openAccessibilitySettings()
                }
            }
        )
        
        screenRecordingRow = PermissionRow(
            title: "Screen Recording",
            description: "Allows taking screenshots (for figures)",
            buttonTitle: "Open Settings",
            note: "May need to restart app after granting",
            onAction: {
                // First request access - this adds our app to the list in System Settings
                PermissionsManager.requestScreenRecording()
                // Then open settings so user can enable it
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    PermissionsManager.openScreenRecordingSettings()
                }
            }
        )
        
        permissionsStack.orientation = .vertical
        permissionsStack.spacing = 12
        permissionsStack.addArrangedSubview(microphoneRow)
        permissionsStack.addArrangedSubview(accessibilityRow)
        permissionsStack.addArrangedSubview(screenRecordingRow)
        addSubview(permissionsStack)
        
        // Continue button
        continueButton.title = "Continue"
        continueButton.bezelStyle = .rounded
        continueButton.controlSize = .large
        continueButton.target = self
        continueButton.action = #selector(continueTapped)
        addSubview(continueButton)
        
        updatePermissionStates()
    }
    
    private func startPermissionChecking() {
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updatePermissionStates()
        }
    }
    
    private func updatePermissionStates() {
        let micGranted = PermissionsManager.checkMicrophone() == .granted
        let accessGranted = PermissionsManager.checkAccessibility() == .granted
        let screenGranted = PermissionsManager.checkScreenRecording() == .granted
        
        microphoneRow.setGranted(micGranted)
        accessibilityRow.setGranted(accessGranted)
        screenRecordingRow.setGranted(screenGranted)
        
        // Enable continue if at least mic and accessibility are granted
        // Screen recording is optional but recommended
        let canContinue = micGranted && accessGranted
        continueButton.isEnabled = canContinue
        continueButton.alphaValue = canContinue ? 1.0 : 0.5
    }
    
    @objc private func continueTapped() {
        permissionCheckTimer?.invalidate()
        onContinue?()
    }
    
    override func layout() {
        super.layout()
        
        let centerX = bounds.midX
        var y = bounds.height - 50
        
        // Title
        titleLabel.sizeToFit()
        titleLabel.frame = NSRect(x: 20, y: y - 30, width: bounds.width - 40, height: 30)
        y -= 50
        
        // Subtitle
        subtitleLabel.sizeToFit()
        subtitleLabel.frame = NSRect(x: 20, y: y - 20, width: bounds.width - 40, height: 20)
        y -= 50
        
        // Permissions stack
        let stackWidth: CGFloat = bounds.width - 80
        let stackHeight: CGFloat = 220
        permissionsStack.frame = NSRect(x: centerX - stackWidth/2, y: y - stackHeight, width: stackWidth, height: stackHeight)
        y -= stackHeight + 30
        
        // Continue button
        continueButton.sizeToFit()
        let buttonWidth = max(180, continueButton.frame.width + 40)
        continueButton.frame = NSRect(x: centerX - buttonWidth/2, y: y - 32, width: buttonWidth, height: 32)
    }
}

// MARK: - Permission Row

private class PermissionRow: NSView {
    
    private let containerBox = NSBox()
    private let titleLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    private let checkmark = NSTextField(labelWithString: "")
    
    private let onAction: () -> Void
    private var isGranted = false
    private let hasNote: Bool
    
    init(title: String, description: String, buttonTitle: String, note: String? = nil, onAction: @escaping () -> Void) {
        self.onAction = onAction
        self.hasNote = note != nil
        super.init(frame: .zero)
        
        setupUI()
        titleLabel.stringValue = title
        descLabel.stringValue = description
        actionButton.title = buttonTitle
        if let note = note {
            noteLabel.stringValue = note
            noteLabel.isHidden = false
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        containerBox.boxType = .custom
        containerBox.cornerRadius = 10
        containerBox.borderWidth = 1
        containerBox.borderColor = .separatorColor
        containerBox.fillColor = NSColor.controlBackgroundColor
        addSubview(containerBox)
        
        // Checkmark circle (empty or filled)
        checkmark.font = .systemFont(ofSize: 18)
        checkmark.textColor = .tertiaryLabelColor
        checkmark.alignment = .center
        containerBox.addSubview(checkmark)
        
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        containerBox.addSubview(titleLabel)
        
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor
        containerBox.addSubview(descLabel)
        
        noteLabel.font = .systemFont(ofSize: 10)
        noteLabel.textColor = .tertiaryLabelColor
        noteLabel.isHidden = true
        containerBox.addSubview(noteLabel)
        
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .regular
        actionButton.target = self
        actionButton.action = #selector(buttonTapped)
        containerBox.addSubview(actionButton)
        
        updateUI()
    }
    
    func setGranted(_ granted: Bool) {
        guard isGranted != granted else { return }
        isGranted = granted
        updateUI()
    }
    
    private func updateUI() {
        if isGranted {
            checkmark.stringValue = "✓"
            checkmark.textColor = .systemGreen
            containerBox.borderColor = .systemGreen.withAlphaComponent(0.5)
            containerBox.fillColor = NSColor.systemGreen.withAlphaComponent(0.05)
            actionButton.isHidden = true
        } else {
            checkmark.stringValue = "○"
            checkmark.textColor = .tertiaryLabelColor
            containerBox.borderColor = .separatorColor
            containerBox.fillColor = NSColor.controlBackgroundColor
            actionButton.isHidden = false
        }
    }
    
    @objc private func buttonTapped() {
        onAction()
    }
    
    override func layout() {
        super.layout()
        
        containerBox.frame = bounds
        
        let padding: CGFloat = 16
        let checkSize: CGFloat = 24
        let buttonWidth: CGFloat = 110
        
        // Checkmark on left
        checkmark.frame = NSRect(x: padding, y: (bounds.height - checkSize) / 2, width: checkSize, height: checkSize)
        
        // Button on right
        actionButton.frame = NSRect(
            x: bounds.width - padding - buttonWidth,
            y: (bounds.height - 28) / 2,
            width: buttonWidth,
            height: 28
        )
        
        // Labels in the middle
        let labelX = padding + checkSize + 12
        let labelWidth = bounds.width - labelX - buttonWidth - padding - 16
        
        if hasNote {
            titleLabel.frame = NSRect(x: labelX, y: bounds.height / 2 + 8, width: labelWidth, height: 18)
            descLabel.frame = NSRect(x: labelX, y: bounds.height / 2 - 8, width: labelWidth, height: 14)
            noteLabel.frame = NSRect(x: labelX, y: bounds.height / 2 - 22, width: labelWidth, height: 14)
        } else {
            titleLabel.frame = NSRect(x: labelX, y: bounds.height / 2 + 2, width: labelWidth, height: 18)
            descLabel.frame = NSRect(x: labelX, y: bounds.height / 2 - 16, width: labelWidth, height: 16)
        }
    }
    
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: hasNote ? 72 : 64)
    }
}

// MARK: - Content View

private class OnboardingContentView: NSView {
    
    var onComplete: (() -> Void)?
    
    // UI Elements
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    
    private let modelSelector = NSStackView()
    private var smallModelButton: ModelButton!
    private var largeModelButton: ModelButton!
    
    private let downloadButton = NSButton()
    private let progressContainer = NSView()
    private let progressBar = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    
    private var selectedModel: ModelDownloader.Model = .small
    private var cancellables = Set<AnyCancellable>()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        setupBindings()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        wantsLayer = true
        
        // Icon
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            iconView.image = appIcon
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        
        // Title
        titleLabel.stringValue = "Welcome to Hearsay"
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.alignment = .center
        addSubview(titleLabel)
        
        // Subtitle
        subtitleLabel.stringValue = "Local speech-to-text that respects your privacy.\nChoose a model to get started:"
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 2
        addSubview(subtitleLabel)
        
        // Model buttons
        smallModelButton = ModelButton(
            model: .small,
            isSelected: true,
            onSelect: { [weak self] in self?.selectModel(.small) }
        )
        
        largeModelButton = ModelButton(
            model: .large,
            isSelected: false,
            onSelect: { [weak self] in self?.selectModel(.large) }
        )
        
        modelSelector.orientation = .horizontal
        modelSelector.spacing = 16
        modelSelector.addArrangedSubview(smallModelButton)
        modelSelector.addArrangedSubview(largeModelButton)
        addSubview(modelSelector)
        
        // Download button
        downloadButton.title = "Download & Continue"
        downloadButton.bezelStyle = .rounded
        downloadButton.controlSize = .large
        downloadButton.target = self
        downloadButton.action = #selector(downloadTapped)
        addSubview(downloadButton)
        
        // Apply preferred/saved selection
        applyPreferredModelSelection()
        
        // Progress container (hidden initially)
        progressContainer.isHidden = true
        addSubview(progressContainer)
        
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressContainer.addSubview(progressBar)
        
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.alignment = .center
        progressContainer.addSubview(progressLabel)
        
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.alignment = .center
        progressContainer.addSubview(statusLabel)
    }
    
    private func setupBindings() {
        let downloader = ModelDownloader.shared
        
        downloader.$overallProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.progressBar.doubleValue = progress
                let percent = Int(progress * 100)
                self?.progressLabel.stringValue = "\(percent)%"
            }
            .store(in: &cancellables)
        
        downloader.$currentFile
            .receive(on: DispatchQueue.main)
            .sink { [weak self] file in
                if !file.isEmpty {
                    self?.statusLabel.stringValue = "Downloading \(file)..."
                }
            }
            .store(in: &cancellables)
        
        downloader.$isComplete
            .receive(on: DispatchQueue.main)
            .sink { [weak self] complete in
                if complete {
                    self?.downloadComplete()
                }
            }
            .store(in: &cancellables)
        
        downloader.$error
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                if let error = error {
                    self?.showError(error)
                }
            }
            .store(in: &cancellables)
    }
    
    override func layout() {
        super.layout()
        
        let centerX = bounds.midX
        var y = bounds.height - 50
        
        // Icon
        let iconSize: CGFloat = 80
        iconView.frame = NSRect(x: centerX - iconSize/2, y: y - iconSize, width: iconSize, height: iconSize)
        y -= iconSize + 20
        
        // Title
        titleLabel.sizeToFit()
        titleLabel.frame = NSRect(x: 20, y: y - 30, width: bounds.width - 40, height: 30)
        y -= 40
        
        // Subtitle
        subtitleLabel.frame = NSRect(x: 20, y: y - 45, width: bounds.width - 40, height: 45)
        y -= 60
        
        // Model selector
        let selectorWidth: CGFloat = 440
        let selectorHeight: CGFloat = 100
        modelSelector.frame = NSRect(x: centerX - selectorWidth/2, y: y - selectorHeight, width: selectorWidth, height: selectorHeight)
        y -= selectorHeight + 30
        
        // Download button
        downloadButton.sizeToFit()
        let buttonWidth = max(180, downloadButton.frame.width + 40)
        downloadButton.frame = NSRect(x: centerX - buttonWidth/2, y: y - 32, width: buttonWidth, height: 32)
        
        // Progress container (same position as button, with bottom padding)
        progressContainer.frame = NSRect(x: 60, y: y - 40, width: bounds.width - 120, height: 60)
        
        // Progress bar
        progressBar.frame = NSRect(x: 0, y: 35, width: progressContainer.bounds.width, height: 20)
        
        // Progress label
        progressLabel.frame = NSRect(x: 0, y: 15, width: progressContainer.bounds.width, height: 18)
        
        // Status label
        statusLabel.frame = NSRect(x: 0, y: 0, width: progressContainer.bounds.width, height: 15)
    }
    
    private func applyPreferredModelSelection() {
        if let preferred = ModelDownloader.shared.selectedModelPreference() {
            selectModel(preferred)
        } else {
            selectModel(.small)
        }
    }
    
    private func persistSelectedModelPreference() {
        ModelDownloader.shared.setSelectedModelPreference(selectedModel)
    }
    
    private func selectModel(_ model: ModelDownloader.Model) {
        selectedModel = model
        smallModelButton.setSelected(model == .small)
        largeModelButton.setSelected(model == .large)
        updateDownloadButton()
    }
    
    private func updateDownloadButton() {
        let isInstalled = ModelDownloader.shared.isModelInstalled(selectedModel)
        if isInstalled {
            downloadButton.title = "Continue"
        } else {
            downloadButton.title = "Download & Continue"
        }
    }
    
    @objc private func downloadTapped() {
        // If already installed, just continue
        if ModelDownloader.shared.isModelInstalled(selectedModel) {
            persistSelectedModelPreference()
            onComplete?()
            return
        }
        
        downloadButton.isHidden = true
        progressContainer.isHidden = false
        smallModelButton.isEnabled = false
        largeModelButton.isEnabled = false
        
        ModelDownloader.shared.download(selectedModel) { [weak self] success in
            if !success {
                self?.resetUI()
            }
        }
    }
    
    private func downloadComplete() {
        statusLabel.stringValue = "Download complete!"
        persistSelectedModelPreference()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.onComplete?()
        }
    }
    
    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Download Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            resetUI()
        }
    }
    
    private func resetUI() {
        downloadButton.isHidden = false
        progressContainer.isHidden = true
        smallModelButton.isEnabled = true
        largeModelButton.isEnabled = true
        progressBar.doubleValue = 0
    }
}

// MARK: - Model Button

private class ModelButton: NSView {
    
    private let model: ModelDownloader.Model
    private var isSelected: Bool
    private let onSelect: () -> Void
    
    private let containerBox = NSBox()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(labelWithString: "")
    private let checkmark = NSTextField(labelWithString: "✓")
    private let downloadedBadge = NSTextField(labelWithString: "Downloaded")
    
    var isEnabled: Bool = true {
        didSet {
            alphaValue = isEnabled ? 1.0 : 0.5
        }
    }
    
    init(model: ModelDownloader.Model, isSelected: Bool, onSelect: @escaping () -> Void) {
        self.model = model
        self.isSelected = isSelected
        self.onSelect = onSelect
        super.init(frame: .zero)
        setupUI()
        updateSelection()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        containerBox.boxType = .custom
        containerBox.cornerRadius = 10
        containerBox.borderWidth = 2
        containerBox.fillColor = NSColor.controlBackgroundColor
        addSubview(containerBox)
        
        nameLabel.stringValue = model.displayName
        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        containerBox.addSubview(nameLabel)
        
        sizeLabel.stringValue = model.estimatedSizeString
        sizeLabel.font = .systemFont(ofSize: 11)
        sizeLabel.textColor = .secondaryLabelColor
        containerBox.addSubview(sizeLabel)
        
        descLabel.stringValue = model.description
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = .tertiaryLabelColor
        containerBox.addSubview(descLabel)
        
        checkmark.font = .systemFont(ofSize: 16, weight: .bold)
        checkmark.textColor = .systemBlue
        containerBox.addSubview(checkmark)
        
        downloadedBadge.stringValue = "✓ Downloaded"
        downloadedBadge.font = .systemFont(ofSize: 10, weight: .medium)
        downloadedBadge.textColor = .systemGreen
        downloadedBadge.isHidden = !ModelDownloader.shared.isModelInstalled(model)
        containerBox.addSubview(downloadedBadge)
    }
    
    func setSelected(_ selected: Bool) {
        isSelected = selected
        updateSelection()
    }
    
    private func updateSelection() {
        containerBox.borderColor = isSelected ? .systemBlue : .separatorColor
        checkmark.isHidden = !isSelected
    }
    
    override func layout() {
        super.layout()
        
        containerBox.frame = bounds
        
        let padding: CGFloat = 12
        let contentWidth = bounds.width - padding * 2 - 24  // Leave room for checkmark
        var y = bounds.height - padding - 18
        
        // Title row
        nameLabel.frame = NSRect(x: padding, y: y, width: contentWidth, height: 18)
        
        checkmark.sizeToFit()
        checkmark.frame.origin = NSPoint(x: bounds.width - padding - checkmark.frame.width, y: y)
        
        // Size row
        y -= 18
        sizeLabel.frame = NSRect(x: padding, y: y, width: contentWidth, height: 16)
        
        // Description row
        y -= 18
        descLabel.frame = NSRect(x: padding, y: y, width: bounds.width - padding * 2, height: 16)
        
        // Downloaded badge row (bottom)
        y -= 18
        downloadedBadge.sizeToFit()
        downloadedBadge.frame.origin = NSPoint(x: padding, y: y)
    }
    
    override var intrinsicContentSize: NSSize {
        NSSize(width: 210, height: 100)
    }
    
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onSelect()
    }
}
