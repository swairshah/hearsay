import AppKit
import Carbon.HIToolbox
import Combine

/// Settings window with tabs for Settings, History, and Permissions
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    
    enum Tab {
        case settings
        case history
        case permissions
        case models
    }
    
    var onHotkeyChanged: (() -> Void)?
    var onWindowOpened: (() -> Void)?
    var onWindowClosed: (() -> Void)?
    var onModelChanged: (() -> Void)?
    
    private let tabView = NSTabView()
    private var settingsTab: SettingsTabView!
    private var historyTab: HistoryTabView!
    private var permissionsTab: PermissionsTabView!
    private var modelsTab: ModelsTabView!
    
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hearsay"
        window.center()
        window.isReleasedWhenClosed = false
        
        self.init(window: window)
        window.delegate = self
        setupUI()
    }
    
    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        
        tabView.tabViewType = .topTabsBezelBorder
        tabView.frame = contentView.bounds
        tabView.autoresizingMask = [.width, .height]
        contentView.addSubview(tabView)
        
        // Settings tab
        settingsTab = SettingsTabView(frame: NSRect(x: 0, y: 0, width: 540, height: 400))
        settingsTab.onHotkeyChanged = { [weak self] in self?.onHotkeyChanged?() }
        let settingsItem = NSTabViewItem(identifier: "settings")
        settingsItem.label = "Settings"
        settingsItem.view = settingsTab
        tabView.addTabViewItem(settingsItem)
        
        // History tab
        historyTab = HistoryTabView(frame: NSRect(x: 0, y: 0, width: 540, height: 400))
        let historyItem = NSTabViewItem(identifier: "history")
        historyItem.label = "History"
        historyItem.view = historyTab
        tabView.addTabViewItem(historyItem)
        
        // Permissions tab
        permissionsTab = PermissionsTabView(frame: NSRect(x: 0, y: 0, width: 540, height: 400))
        let permissionsItem = NSTabViewItem(identifier: "permissions")
        permissionsItem.label = "Permissions"
        permissionsItem.view = permissionsTab
        tabView.addTabViewItem(permissionsItem)
        
        // Models tab
        modelsTab = ModelsTabView(frame: NSRect(x: 0, y: 0, width: 540, height: 400))
        modelsTab.onModelSelected = { [weak self] in
            self?.onModelChanged?()
        }
        let modelsItem = NSTabViewItem(identifier: "models")
        modelsItem.label = "Models"
        modelsItem.view = modelsTab
        tabView.addTabViewItem(modelsItem)
    }
    
    func show(tab: Tab = .settings) {
        historyTab.refresh()
        permissionsTab.refresh()
        modelsTab.refresh()
        
        switch tab {
        case .settings:
            tabView.selectTabViewItem(withIdentifier: "settings")
        case .history:
            tabView.selectTabViewItem(withIdentifier: "history")
        case .permissions:
            tabView.selectTabViewItem(withIdentifier: "permissions")
        case .models:
            tabView.selectTabViewItem(withIdentifier: "models")
        }
        
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        // Only pause hotkeys when opening the Settings tab (shortcut recorder needs key capture).
        if tab == .settings {
            onWindowOpened?()
        } else {
            onWindowClosed?()
        }
    }
    
    func windowWillClose(_ notification: Notification) {
        onWindowClosed?()
    }
    
    func windowDidResignKey(_ notification: Notification) {
        // Always resume hotkeys when window loses focus
        onWindowClosed?()
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        // Only pause hotkeys when Settings tab is active (shortcut recorder needs key capture)
        let currentID = tabView.selectedTabViewItem?.identifier as? String
        if currentID == "settings" {
            onWindowOpened?()
        } else {
            onWindowClosed?()
        }
    }
}

// MARK: - Settings Tab

private class SettingsTabView: NSView {
    
    var onHotkeyChanged: (() -> Void)?
    
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Hearsay")
    private let subtitleLabel = NSTextField(labelWithString: "Local Speech-to-Text")
    
    private let generalBox = NSBox()
    private let dockIconCheckbox = NSButton(checkboxWithTitle: "Show Dock Icon", target: nil, action: nil)
    
    private let shortcutsBox = NSBox()
    private let holdKeyLabel = NSTextField(labelWithString: "Hold to Record")
    private var holdKeyRecorder: ShortcutRecorderView!
    private let toggleStartLabel = NSTextField(labelWithString: "Toggle Record")
    private var toggleStartRecorder: ShortcutRecorderView!
    private let resetButton = NSButton(title: "Reset to Defaults", target: nil, action: nil)
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        loadSettings()
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    private func setupUI() {
        // Header
        if let settingsIconURL = Bundle.main.url(forResource: "settings-icon", withExtension: "png"),
           let icon = NSImage(contentsOf: settingsIconURL) {
            iconView.image = icon
        } else if let icon = NSImage(named: NSImage.applicationIconName) {
            iconView.image = icon
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.alignment = .center
        addSubview(titleLabel)
        
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        addSubview(subtitleLabel)
        
        // General box
        generalBox.title = "General"
        generalBox.titleFont = .systemFont(ofSize: 12, weight: .semibold)
        addSubview(generalBox)
        
        dockIconCheckbox.target = self
        dockIconCheckbox.action = #selector(dockIconChanged(_:))
        generalBox.contentView?.addSubview(dockIconCheckbox)
        
        // Shortcuts box
        shortcutsBox.title = "Shortcuts"
        shortcutsBox.titleFont = .systemFont(ofSize: 12, weight: .semibold)
        addSubview(shortcutsBox)
        
        for label in [holdKeyLabel, toggleStartLabel] {
            label.font = .systemFont(ofSize: 12)
            label.alignment = .right
            shortcutsBox.contentView?.addSubview(label)
        }
        
        holdKeyRecorder = ShortcutRecorderView(captureMode: .singleModifier, placeholder: "Click to set") { [weak self] s in
            UserDefaults.standard.set(s.keyCode, forKey: "holdKeyCode")
            self?.onHotkeyChanged?()
        }
        shortcutsBox.contentView?.addSubview(holdKeyRecorder)
        
        toggleStartRecorder = ShortcutRecorderView(captureMode: .keyCombo, placeholder: "Click to set") { [weak self] s in
            UserDefaults.standard.set(s.keyCode, forKey: "toggleStartKeyCode")
            UserDefaults.standard.set(s.modifiers, forKey: "toggleStartModifiers")
            self?.onHotkeyChanged?()
        }
        shortcutsBox.contentView?.addSubview(toggleStartRecorder)
        
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.target = self
        resetButton.action = #selector(resetToDefaults(_:))
        shortcutsBox.contentView?.addSubview(resetButton)
    }
    
    private func loadSettings() {
        dockIconCheckbox.state = UserDefaults.standard.bool(forKey: "showDockIcon") ? .on : .off
        
        holdKeyRecorder.setShortcut(Shortcut(
            keyCode: UserDefaults.standard.object(forKey: "holdKeyCode") as? Int ?? 61,
            modifiers: 0
        ))
        
        toggleStartRecorder.setShortcut(Shortcut(
            keyCode: UserDefaults.standard.object(forKey: "toggleStartKeyCode") as? Int ?? 49,
            modifiers: UInt(UserDefaults.standard.object(forKey: "toggleStartModifiers") as? Int ?? Int(NSEvent.ModifierFlags.option.rawValue))
        ))
    }
    
    override func layout() {
        super.layout()
        
        let pad: CGFloat = 20
        let boxW = bounds.width - pad * 2
        var y = bounds.height - 16
        
        // Header
        let iconSz: CGFloat = 48
        iconView.frame = NSRect(x: bounds.midX - iconSz/2, y: y - iconSz, width: iconSz, height: iconSz)
        y -= iconSz + 4
        
        titleLabel.frame = NSRect(x: 0, y: y - 22, width: bounds.width, height: 22)
        y -= 20
        
        subtitleLabel.frame = NSRect(x: 0, y: y - 16, width: bounds.width, height: 16)
        y -= 28
        
        // General box
        generalBox.frame = NSRect(x: pad, y: y - 54, width: boxW, height: 54)
        if let cv = generalBox.contentView {
            dockIconCheckbox.frame = NSRect(x: 12, y: (cv.bounds.height - 20) / 2, width: 200, height: 20)
        }
        y -= 66
        
        // Shortcuts box
        shortcutsBox.frame = NSRect(x: pad, y: y - 108, width: boxW, height: 108)
        layoutShortcutsBox()
    }
    
    private func layoutShortcutsBox() {
        guard let cv = shortcutsBox.contentView else { return }
        let labelW: CGFloat = 100
        let inputW: CGFloat = 140
        let inputX: CGFloat = labelW + 16
        var y = cv.bounds.height - 32
        
        holdKeyLabel.frame = NSRect(x: 8, y: y, width: labelW, height: 20)
        holdKeyRecorder.frame = NSRect(x: inputX, y: y - 2, width: inputW, height: 24)
        y -= 32
        
        toggleStartLabel.frame = NSRect(x: 8, y: y, width: labelW, height: 20)
        toggleStartRecorder.frame = NSRect(x: inputX, y: y - 2, width: inputW, height: 24)
        
        resetButton.sizeToFit()
        resetButton.frame.origin = NSPoint(x: inputX + inputW + 16, y: cv.bounds.height - 34)
    }
    
    @objc private func dockIconChanged(_ sender: NSButton) {
        let show = sender.state == .on
        UserDefaults.standard.set(show, forKey: "showDockIcon")
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }
    
    @objc private func resetToDefaults(_ sender: NSButton) {
        UserDefaults.standard.set(61, forKey: "holdKeyCode")
        UserDefaults.standard.set(49, forKey: "toggleStartKeyCode")
        UserDefaults.standard.set(Int(NSEvent.ModifierFlags.option.rawValue), forKey: "toggleStartModifiers")
        loadSettings()
        onHotkeyChanged?()
    }
}

// MARK: - Models Tab

private class ModelsTabView: NSView {
    
    var onModelSelected: (() -> Void)?
    
    private let titleLabel = NSTextField(labelWithString: "Manage Models")
    private let subtitleLabel = NSTextField(labelWithString: "Choose a model and set it as active.")
    private let modelSelector = NSStackView()
    private var smallModelButton: SettingsModelCardView!
    private var largeModelButton: SettingsModelCardView!
    private let actionButton = NSButton()
    private let progressContainer = NSView()
    private let progressBar = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    
    private var selectedModel: ModelDownloader.Model = .small
    private var cancellables = Set<AnyCancellable>()
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        setupBindings()
        refresh(initial: true)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    private func setupUI() {
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.alignment = .center
        addSubview(titleLabel)
        
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        addSubview(subtitleLabel)
        
        smallModelButton = SettingsModelCardView(model: .small, isSelected: true) { [weak self] in
            self?.selectModel(.small)
        }
        largeModelButton = SettingsModelCardView(model: .large, isSelected: false) { [weak self] in
            self?.selectModel(.large)
        }
        
        modelSelector.orientation = .horizontal
        modelSelector.spacing = 16
        modelSelector.addArrangedSubview(smallModelButton)
        modelSelector.addArrangedSubview(largeModelButton)
        addSubview(modelSelector)
        
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .large
        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        addSubview(actionButton)
        
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
        
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        addSubview(detailLabel)
    }
    
    private func setupBindings() {
        let downloader = ModelDownloader.shared
        
        downloader.$overallProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.progressBar.doubleValue = progress
                self?.progressLabel.stringValue = "\(Int(progress * 100))%"
            }
            .store(in: &cancellables)
        
        downloader.$currentFile
            .receive(on: DispatchQueue.main)
            .sink { [weak self] file in
                guard let self = self, !file.isEmpty, ModelDownloader.shared.isDownloading else { return }
                self.statusLabel.stringValue = "Downloading \(file)..."
            }
            .store(in: &cancellables)
        
        downloader.$isDownloading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
        
        downloader.$isComplete
            .receive(on: DispatchQueue.main)
            .sink { [weak self] complete in
                guard let self = self, complete else { return }
                self.statusLabel.stringValue = "Download complete"
                self.refresh()
            }
            .store(in: &cancellables)
        
        downloader.$error
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self = self, let error else { return }
                self.statusLabel.stringValue = "Error: \(error)"
                self.refresh()
            }
            .store(in: &cancellables)
    }
    
    private func selectModel(_ model: ModelDownloader.Model) {
        selectedModel = model
        smallModelButton.setSelected(model == .small)
        largeModelButton.setSelected(model == .large)
        refresh()
    }
    
    func refresh(initial: Bool = false) {
        if initial {
            if let preferred = ModelDownloader.shared.selectedModelPreference() {
                selectedModel = preferred
            } else {
                selectedModel = .small
            }
            smallModelButton.setSelected(selectedModel == .small)
            largeModelButton.setSelected(selectedModel == .large)
        }
        
        let downloader = ModelDownloader.shared
        let installedSmall = downloader.isModelInstalled(.small)
        let installedLarge = downloader.isModelInstalled(.large)
        let selectedInstalled = downloader.isModelInstalled(selectedModel)
        let active = downloader.selectedModelPreference()
        
        smallModelButton.setInstalled(installedSmall)
        largeModelButton.setInstalled(installedLarge)
        smallModelButton.setActive(active == .small)
        largeModelButton.setActive(active == .large)
        
        if downloader.isDownloading {
            actionButton.isHidden = true
            progressContainer.isHidden = false
            smallModelButton.isEnabled = false
            largeModelButton.isEnabled = false
        } else {
            actionButton.isHidden = false
            progressContainer.isHidden = true
            smallModelButton.isEnabled = true
            largeModelButton.isEnabled = true
            
            actionButton.title = selectedInstalled ? "Use Selected Model" : "Download Selected Model"
            
            let installedNames = downloader.installedModels().map { $0.displayName }.joined(separator: ", ")
            if installedNames.isEmpty {
                detailLabel.stringValue = "No models installed yet."
            } else if let active = active {
                detailLabel.stringValue = "Installed: \(installedNames). Active: \(active.displayName)."
            } else {
                detailLabel.stringValue = "Installed: \(installedNames)."
            }
        }
    }
    
    @objc private func actionTapped() {
        let model = selectedModel
        let downloader = ModelDownloader.shared
        
        if downloader.isModelInstalled(model) {
            downloader.setSelectedModelPreference(model)
            statusLabel.stringValue = "Active model set to \(model.displayName)"
            onModelSelected?()
            refresh()
            return
        }
        
        statusLabel.stringValue = "Starting download..."
        refresh()
        
        downloader.download(model) { [weak self] success in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if success {
                    downloader.setSelectedModelPreference(model)
                    self.statusLabel.stringValue = "Download complete"
                    self.onModelSelected?()
                }
                self.refresh()
            }
        }
    }
    
    override func layout() {
        super.layout()
        
        let centerX = bounds.midX
        var y = bounds.height - 32
        
        titleLabel.frame = NSRect(x: 20, y: y - 30, width: bounds.width - 40, height: 30)
        y -= 38
        subtitleLabel.frame = NSRect(x: 20, y: y - 22, width: bounds.width - 40, height: 22)
        y -= 34
        
        let selectorWidth: CGFloat = min(460, bounds.width - 40)
        let selectorHeight: CGFloat = 100
        modelSelector.frame = NSRect(x: centerX - selectorWidth/2, y: y - selectorHeight, width: selectorWidth, height: selectorHeight)
        y -= selectorHeight + 24
        
        actionButton.sizeToFit()
        let buttonWidth = max(220, actionButton.frame.width + 36)
        actionButton.frame = NSRect(x: centerX - buttonWidth/2, y: y - 34, width: buttonWidth, height: 34)
        
        progressContainer.frame = NSRect(x: 60, y: y - 42, width: bounds.width - 120, height: 62)
        progressBar.frame = NSRect(x: 0, y: 36, width: progressContainer.bounds.width, height: 18)
        progressLabel.frame = NSRect(x: 0, y: 16, width: progressContainer.bounds.width, height: 16)
        statusLabel.frame = NSRect(x: 0, y: 0, width: progressContainer.bounds.width, height: 15)
        
        detailLabel.frame = NSRect(x: 20, y: 24, width: bounds.width - 40, height: 18)
    }
}

private class SettingsModelCardView: NSView {
    
    private let model: ModelDownloader.Model
    private let onSelect: () -> Void
    private var selected: Bool
    private var installed: Bool = false
    private var active: Bool = false
    
    private let containerBox = NSBox()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(labelWithString: "")
    private let checkmark = NSTextField(labelWithString: "✓")
    private let downloadedBadge = NSTextField(labelWithString: "✓ Downloaded")
    private let activeBadge = NSTextField(labelWithString: "Active")
    
    var isEnabled: Bool = true {
        didSet { alphaValue = isEnabled ? 1.0 : 0.5 }
    }
    
    init(model: ModelDownloader.Model, isSelected: Bool, onSelect: @escaping () -> Void) {
        self.model = model
        self.selected = isSelected
        self.onSelect = onSelect
        super.init(frame: .zero)
        setupUI()
        updateUI()
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
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
        
        downloadedBadge.font = .systemFont(ofSize: 10, weight: .medium)
        downloadedBadge.textColor = .systemGreen
        containerBox.addSubview(downloadedBadge)
        
        activeBadge.font = .systemFont(ofSize: 10, weight: .medium)
        activeBadge.textColor = .systemBlue
        activeBadge.alignment = .right
        containerBox.addSubview(activeBadge)
    }
    
    func setSelected(_ selected: Bool) {
        self.selected = selected
        updateUI()
    }
    
    func setInstalled(_ installed: Bool) {
        self.installed = installed
        updateUI()
    }
    
    func setActive(_ active: Bool) {
        self.active = active
        updateUI()
    }
    
    private func updateUI() {
        containerBox.borderColor = selected ? .systemBlue : .separatorColor
        checkmark.isHidden = !selected
        downloadedBadge.isHidden = !installed
        activeBadge.isHidden = !active
    }
    
    override func layout() {
        super.layout()
        
        containerBox.frame = bounds
        
        let padding: CGFloat = 12
        let contentWidth = bounds.width - padding * 2 - 24
        var y = bounds.height - padding - 18
        
        nameLabel.frame = NSRect(x: padding, y: y, width: contentWidth, height: 18)
        checkmark.sizeToFit()
        checkmark.frame.origin = NSPoint(x: bounds.width - padding - checkmark.frame.width, y: y)
        
        y -= 18
        sizeLabel.frame = NSRect(x: padding, y: y, width: contentWidth, height: 16)
        
        y -= 18
        descLabel.frame = NSRect(x: padding, y: y, width: bounds.width - padding * 2, height: 16)
        
        y -= 18
        downloadedBadge.sizeToFit()
        downloadedBadge.frame.origin = NSPoint(x: padding, y: y)
        
        activeBadge.sizeToFit()
        activeBadge.frame.origin = NSPoint(x: bounds.width - padding - activeBadge.frame.width, y: y)
    }
    
    override var intrinsicContentSize: NSSize {
        NSSize(width: 220, height: 100)
    }
    
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onSelect()
    }
}

// MARK: - Permissions Tab

private class PermissionsTabView: NSView {
    
    private let titleLabel = NSTextField(labelWithString: "Permissions")
    private let subtitleLabel = NSTextField(labelWithString: "Grant or review permissions anytime.")
    private let stack = NSStackView()
    private let noteLabel = NSTextField(labelWithString: "Screen Recording may require restarting Hearsay after granting.")
    
    private var microphoneRow: PermissionStatusRowView!
    private var accessibilityRow: PermissionStatusRowView!
    private var screenRecordingRow: PermissionStatusRowView!
    private var refreshTimer: Timer?
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        startTimer()
        refresh()
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    deinit {
        refreshTimer?.invalidate()
    }
    
    private func setupUI() {
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.alignment = .center
        addSubview(titleLabel)
        
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        addSubview(subtitleLabel)
        
        microphoneRow = PermissionStatusRowView(
            title: "Microphone",
            description: "Records your voice for transcription",
            buttonTitle: "Allow"
        ) {
            Task {
                switch PermissionsManager.checkMicrophone() {
                case .notDetermined:
                    _ = await PermissionsManager.requestMicrophone()
                case .denied:
                    PermissionsManager.openMicrophoneSettings()
                case .granted:
                    break
                }
            }
        }
        
        accessibilityRow = PermissionStatusRowView(
            title: "Accessibility",
            description: "Needed for global hotkeys and paste",
            buttonTitle: "Open Settings"
        ) {
            PermissionsManager.requestAccessibility()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                PermissionsManager.openAccessibilitySettings()
            }
        }
        
        screenRecordingRow = PermissionStatusRowView(
            title: "Screen Recording",
            description: "Needed for Option+4 figure screenshots",
            buttonTitle: "Open Settings",
            note: "May need app restart after granting"
        ) {
            PermissionsManager.requestScreenRecording()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                PermissionsManager.openScreenRecordingSettings()
            }
        }
        
        stack.orientation = .vertical
        stack.spacing = 12
        stack.addArrangedSubview(microphoneRow)
        stack.addArrangedSubview(accessibilityRow)
        stack.addArrangedSubview(screenRecordingRow)
        addSubview(stack)
        
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .tertiaryLabelColor
        noteLabel.alignment = .center
        addSubview(noteLabel)
    }
    
    private func startTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }
    
    func refresh() {
        microphoneRow.setGranted(PermissionsManager.checkMicrophone() == .granted)
        accessibilityRow.setGranted(PermissionsManager.checkAccessibility() == .granted)
        screenRecordingRow.setGranted(PermissionsManager.checkScreenRecording() == .granted)
    }
    
    override func layout() {
        super.layout()
        
        var y = bounds.height - 22
        titleLabel.frame = NSRect(x: 20, y: y - 24, width: bounds.width - 40, height: 24)
        y -= 30
        subtitleLabel.frame = NSRect(x: 20, y: y - 18, width: bounds.width - 40, height: 18)
        y -= 24
        
        let stackWidth = bounds.width - 40
        let stackHeight: CGFloat = 220
        stack.frame = NSRect(x: 20, y: y - stackHeight, width: stackWidth, height: stackHeight)
        y -= stackHeight + 8
        
        noteLabel.frame = NSRect(x: 20, y: max(12, y - 16), width: bounds.width - 40, height: 16)
    }
}

private class PermissionStatusRowView: NSView {
    
    private let onAction: () -> Void
    private let hasNote: Bool
    private var isGranted = false
    
    private let box = NSBox()
    private let statusLabel = NSTextField(labelWithString: "○")
    private let titleLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    
    init(title: String, description: String, buttonTitle: String, note: String? = nil, onAction: @escaping () -> Void) {
        self.onAction = onAction
        self.hasNote = note != nil
        super.init(frame: .zero)
        
        titleLabel.stringValue = title
        descriptionLabel.stringValue = description
        actionButton.title = buttonTitle
        if let note {
            noteLabel.stringValue = note
            noteLabel.isHidden = false
        }
        
        setupUI()
        updateUI()
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    private func setupUI() {
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        addSubview(box)
        
        statusLabel.font = .systemFont(ofSize: 18)
        statusLabel.alignment = .center
        statusLabel.textColor = .tertiaryLabelColor
        box.addSubview(statusLabel)
        
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        box.addSubview(titleLabel)
        
        descriptionLabel.font = .systemFont(ofSize: 11)
        descriptionLabel.textColor = .secondaryLabelColor
        box.addSubview(descriptionLabel)
        
        noteLabel.font = .systemFont(ofSize: 10)
        noteLabel.textColor = .tertiaryLabelColor
        noteLabel.isHidden = true
        box.addSubview(noteLabel)
        
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .regular
        actionButton.target = self
        actionButton.action = #selector(didTapAction)
        box.addSubview(actionButton)
    }
    
    func setGranted(_ granted: Bool) {
        guard granted != isGranted else { return }
        isGranted = granted
        updateUI()
    }
    
    private func updateUI() {
        if isGranted {
            statusLabel.stringValue = "✓"
            statusLabel.textColor = .systemGreen
            box.borderColor = .systemGreen.withAlphaComponent(0.5)
            box.fillColor = .systemGreen.withAlphaComponent(0.05)
            actionButton.isHidden = true
        } else {
            statusLabel.stringValue = "○"
            statusLabel.textColor = .tertiaryLabelColor
            box.borderColor = .separatorColor
            box.fillColor = .controlBackgroundColor
            actionButton.isHidden = false
        }
    }
    
    override func layout() {
        super.layout()
        box.frame = bounds
        
        let padding: CGFloat = 16
        let statusSize: CGFloat = 24
        let buttonWidth: CGFloat = 112
        
        statusLabel.frame = NSRect(x: padding, y: (bounds.height - statusSize) / 2, width: statusSize, height: statusSize)
        actionButton.frame = NSRect(x: bounds.width - padding - buttonWidth, y: (bounds.height - 28) / 2, width: buttonWidth, height: 28)
        
        let labelX = padding + statusSize + 12
        let labelWidth = bounds.width - labelX - buttonWidth - padding - 16
        
        if hasNote {
            titleLabel.frame = NSRect(x: labelX, y: bounds.height / 2 + 8, width: labelWidth, height: 18)
            descriptionLabel.frame = NSRect(x: labelX, y: bounds.height / 2 - 8, width: labelWidth, height: 14)
            noteLabel.frame = NSRect(x: labelX, y: bounds.height / 2 - 22, width: labelWidth, height: 14)
        } else {
            titleLabel.frame = NSRect(x: labelX, y: bounds.height / 2 + 2, width: labelWidth, height: 18)
            descriptionLabel.frame = NSRect(x: labelX, y: bounds.height / 2 - 16, width: labelWidth, height: 16)
        }
    }
    
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: hasNote ? 72 : 64)
    }
    
    @objc private func didTapAction() {
        onAction()
    }
}

// MARK: - History Tab

private class HistoryTabView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let clearButton = NSButton(title: "Clear All", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy Selected", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "No transcriptions yet")
    
    private var items: [TranscriptionItem] = []
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    private func setupUI() {
        // Table
        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = nil
        tableView.rowHeight = 52
        tableView.doubleAction = #selector(copySelected(_:))
        tableView.target = self
        
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        col.width = 400
        tableView.addTableColumn(col)
        
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        addSubview(scrollView)
        
        // Empty label
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
        
        // Buttons
        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearAll(_:))
        addSubview(clearButton)
        
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copySelected(_:))
        addSubview(copyButton)
    }
    
    func refresh() {
        items = HistoryStore.shared.getRecent(50)
        tableView.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        scrollView.isHidden = items.isEmpty
    }
    
    override func layout() {
        super.layout()
        
        let pad: CGFloat = 16
        let buttonH: CGFloat = 28
        
        // Buttons at bottom
        clearButton.sizeToFit()
        copyButton.sizeToFit()
        
        clearButton.frame.origin = NSPoint(x: pad, y: pad)
        copyButton.frame.origin = NSPoint(x: pad + clearButton.frame.width + 12, y: pad)
        
        // Table fills rest
        scrollView.frame = NSRect(
            x: pad,
            y: pad + buttonH + 12,
            width: bounds.width - pad * 2,
            height: bounds.height - buttonH - pad * 2 - 12
        )
        
        emptyLabel.frame = scrollView.frame
    }
    
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        
        let cell = NSView()
        
        let text = NSTextField(wrappingLabelWithString: item.text)
        text.font = .systemFont(ofSize: 12)
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 2
        cell.addSubview(text)
        
        let time = NSTextField(labelWithString: item.formattedTime)
        time.font = .systemFont(ofSize: 10)
        time.textColor = .tertiaryLabelColor
        cell.addSubview(time)
        
        text.translatesAutoresizingMaskIntoConstraints = false
        time.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            
            time.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -6),
            time.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
        ])
        
        return cell
    }
    
    @objc private func clearAll(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = "Clear All History?"
        alert.informativeText = "This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            HistoryStore.shared.clear()
            refresh()
        }
    }
    
    @objc private func copySelected(_ sender: Any) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items[row].text, forType: .string)
    }
}

// MARK: - Shortcut

struct Shortcut {
    var keyCode: Int
    var modifiers: UInt
    
    var displayString: String {
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(ShortcutRecorderView.keyName(for: keyCode))
        return parts.joined()
    }
}

// MARK: - Shortcut Recorder

private class ShortcutRecorderView: NSView {
    enum CaptureMode { case singleModifier, singleKey, keyCombo }
    
    private let captureMode: CaptureMode
    private let placeholder: String
    private let onChange: (Shortcut) -> Void
    private let button = NSButton()
    private var isRecording = false
    private var currentShortcut = Shortcut(keyCode: 0, modifiers: 0)
    private var eventMonitor: Any?
    
    var displayString: String {
        captureMode == .singleModifier ? Self.keyName(for: currentShortcut.keyCode) : currentShortcut.displayString
    }
    
    init(captureMode: CaptureMode, placeholder: String, onChange: @escaping (Shortcut) -> Void) {
        self.captureMode = captureMode
        self.placeholder = placeholder
        self.onChange = onChange
        super.init(frame: .zero)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(clicked(_:))
        button.title = placeholder
        addSubview(button)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    func setShortcut(_ s: Shortcut) {
        currentShortcut = s
        button.title = s.keyCode == 0 ? placeholder : displayString
    }
    
    override func layout() { super.layout(); button.frame = bounds }
    
    @objc private func clicked(_ sender: NSButton) { isRecording ? stop() : start() }
    
    private func start() {
        isRecording = true
        button.title = "Press..."
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] in self?.handle($0) }
    }
    
    private func stop() {
        isRecording = false
        button.title = currentShortcut.keyCode == 0 ? placeholder : displayString
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        eventMonitor = nil
    }
    
    private func handle(_ e: NSEvent) -> NSEvent? {
        let kc = Int(e.keyCode)
        let mods = e.modifierFlags.intersection([.command, .option, .shift, .control]).rawValue
        if kc == 53 { stop(); return nil }
        
        switch captureMode {
        case .singleModifier where Self.isMod(kc) && e.type == .flagsChanged:
            currentShortcut = Shortcut(keyCode: kc, modifiers: 0); onChange(currentShortcut); stop()
        case .singleKey where !Self.isMod(kc) && e.type == .keyDown:
            currentShortcut = Shortcut(keyCode: kc, modifiers: 0); onChange(currentShortcut); stop()
        case .keyCombo where !Self.isMod(kc) && e.type == .keyDown:
            currentShortcut = Shortcut(keyCode: kc, modifiers: mods); onChange(currentShortcut); stop()
        default: break
        }
        return nil
    }
    
    private static func isMod(_ kc: Int) -> Bool { (54...63).contains(kc) }
    
    static func keyName(for kc: Int) -> String {
        [54:"Right ⌘",55:"Left ⌘",56:"Left ⇧",57:"⇪",58:"Left ⌥",59:"Left ⌃",60:"Right ⇧",61:"Right ⌥",62:"Right ⌃",63:"fn",
         36:"↩",48:"⇥",49:"Space",51:"⌫",53:"⎋",76:"⌤",123:"←",124:"→",125:"↓",126:"↑",
         122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",
         0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",
         18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",
         33:"[",34:"I",35:"P",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",50:"`"
        ][kc] ?? "Key \(kc)"
    }
}
