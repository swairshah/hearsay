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
        case microphone
        case cleanup
    }
    
    var onHotkeyChanged: (() -> Void)?
    var onWindowOpened: (() -> Void)?
    var onWindowClosed: (() -> Void)?
    var onModelChanged: (() -> Void)?
    var onCleanupSettingsChanged: (() -> Void)?
    
    private let tabView = NSTabView()
    private var settingsTab: SettingsTabView!
    private var historyTab: HistoryTabView!
    private var permissionsTab: PermissionsTabView!
    private var modelsTab: ModelsTabView!
    private var microphoneTab: MicrophoneTabView!
    private var cleanupTab: CleanupTabView!
    
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hearsay"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 560)
        
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
        
        // Microphone tab
        microphoneTab = MicrophoneTabView(frame: NSRect(x: 0, y: 0, width: 540, height: 400))
        let micItem = NSTabViewItem(identifier: "microphone")
        micItem.label = "Microphone"
        micItem.view = microphoneTab
        tabView.addTabViewItem(micItem)
        
        // Cleanup tab
        cleanupTab = CleanupTabView(frame: NSRect(x: 0, y: 0, width: 540, height: 400))
        cleanupTab.onSettingsChanged = { [weak self] in
            self?.onCleanupSettingsChanged?()
        }
        let cleanupItem = NSTabViewItem(identifier: "cleanup")
        cleanupItem.label = "Cleanup"
        cleanupItem.view = cleanupTab
        tabView.addTabViewItem(cleanupItem)
    }
    
    func show(tab: Tab = .settings) {
        historyTab.refresh()
        permissionsTab.refresh()
        modelsTab.refresh()
        microphoneTab.refresh()
        cleanupTab.refresh()
        
        switch tab {
        case .settings:
            tabView.selectTabViewItem(withIdentifier: "settings")
        case .history:
            tabView.selectTabViewItem(withIdentifier: "history")
        case .permissions:
            tabView.selectTabViewItem(withIdentifier: "permissions")
        case .models:
            tabView.selectTabViewItem(withIdentifier: "models")
        case .microphone:
            tabView.selectTabViewItem(withIdentifier: "microphone")
        case .cleanup:
            tabView.selectTabViewItem(withIdentifier: "cleanup")
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
    private let copyToClipboardCheckbox = NSButton(checkboxWithTitle: "Copy to Clipboard", target: nil, action: nil)
    private let autoPasteCheckbox = NSButton(checkboxWithTitle: "Auto-Paste at Cursor", target: nil, action: nil)
    private let dockIconCheckbox = NSButton(checkboxWithTitle: "Show Dock Icon", target: nil, action: nil)
    private let soundEffectsCheckbox = NSButton(checkboxWithTitle: "Sound Effects", target: nil, action: nil)
    private let maxHistoryLabel = NSTextField(labelWithString: "Max History Size")
    private let maxHistorySlider = NSSlider()
    private let maxHistoryValueLabel = NSTextField(labelWithString: "")

    
    private let shortcutsBox = NSBox()
    private let activationLabel = NSTextField(labelWithString: "Activation")
    private let activationPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let activationSeparator = NSBox()
    private var holdRow: ShortcutRowView!
    private var toggleRow: ShortcutRowView!
    private var screenshotRow: ShortcutRowView!
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
        
        copyToClipboardCheckbox.target = self
        copyToClipboardCheckbox.action = #selector(copyToClipboardChanged(_:))
        generalBox.contentView?.addSubview(copyToClipboardCheckbox)

        autoPasteCheckbox.target = self
        autoPasteCheckbox.action = #selector(autoPasteChanged(_:))
        generalBox.contentView?.addSubview(autoPasteCheckbox)

        dockIconCheckbox.target = self
        dockIconCheckbox.action = #selector(dockIconChanged(_:))
        generalBox.contentView?.addSubview(dockIconCheckbox)
        
        soundEffectsCheckbox.target = self
        soundEffectsCheckbox.action = #selector(soundEffectsChanged(_:))
        generalBox.contentView?.addSubview(soundEffectsCheckbox)
        
        maxHistoryLabel.font = .systemFont(ofSize: 13)
        maxHistoryLabel.textColor = .labelColor
        generalBox.contentView?.addSubview(maxHistoryLabel)
        
        // Slider: logarithmic from 1,000 to 100,000
        maxHistorySlider.minValue = 0
        maxHistorySlider.maxValue = 1
        maxHistorySlider.isContinuous = true
        maxHistorySlider.target = self
        maxHistorySlider.action = #selector(maxHistorySliderChanged(_:))
        generalBox.contentView?.addSubview(maxHistorySlider)
        
        maxHistoryValueLabel.font = .systemFont(ofSize: 11)
        maxHistoryValueLabel.textColor = .secondaryLabelColor
        maxHistoryValueLabel.alignment = .right
        generalBox.contentView?.addSubview(maxHistoryValueLabel)
        

        
        // Shortcuts box
        shortcutsBox.title = "Shortcuts"
        shortcutsBox.titleFont = .systemFont(ofSize: 12, weight: .semibold)
        addSubview(shortcutsBox)
        
        // Activation mode picker
        activationLabel.font = .systemFont(ofSize: 13)
        activationLabel.textColor = .labelColor
        shortcutsBox.contentView?.addSubview(activationLabel)
        
        activationPicker.addItems(withTitles: ["Hold", "Double-Tap"])
        activationPicker.controlSize = .regular
        activationPicker.font = .systemFont(ofSize: 12)
        activationPicker.target = self
        activationPicker.action = #selector(activationChanged(_:))
        shortcutsBox.contentView?.addSubview(activationPicker)
        
        activationSeparator.boxType = .separator
        shortcutsBox.contentView?.addSubview(activationSeparator)
        
        holdRow = ShortcutRowView(
            label: "Hold to Record",
            captureMode: .singleModifier,
            placeholder: "Click to set",
            canClear: false,
            showSeparator: true
        ) { [weak self] s in
            UserDefaults.standard.set(s.keyCode, forKey: "holdKeyCode")
            self?.onHotkeyChanged?()
        }
        shortcutsBox.contentView?.addSubview(holdRow)
        
        toggleRow = ShortcutRowView(
            label: "Toggle Record",
            captureMode: .keyCombo,
            placeholder: "Not set",
            canClear: true,
            showSeparator: true
        ) { [weak self] s in
            UserDefaults.standard.set(s.keyCode, forKey: "toggleStartKeyCode")
            UserDefaults.standard.set(Int(s.modifiers), forKey: "toggleStartModifiers")
            self?.onHotkeyChanged?()
        }
        shortcutsBox.contentView?.addSubview(toggleRow)
        
        screenshotRow = ShortcutRowView(
            label: "Take Screenshot",
            captureMode: .keyCombo,
            placeholder: "Not set",
            canClear: true,
            showSeparator: false
        ) { [weak self] s in
            UserDefaults.standard.set(s.keyCode, forKey: "screenshotKeyCode")
            UserDefaults.standard.set(Int(s.modifiers), forKey: "screenshotModifiers")
            self?.onHotkeyChanged?()
        }
        shortcutsBox.contentView?.addSubview(screenshotRow)
        
        // Conflict detection
        toggleRow.recorder.onConflict = { [weak self] candidate in
            guard let self = self else { return nil }
            if candidate.conflicts(with: self.screenshotRow.recorder.currentShortcut) {
                return "This shortcut is already used by \"Take Screenshot\"."
            }
            return nil
        }
        screenshotRow.recorder.onConflict = { [weak self] candidate in
            guard let self = self else { return nil }
            if candidate.conflicts(with: self.toggleRow.recorder.currentShortcut) {
                return "This shortcut is already used by \"Toggle Record\"."
            }
            return nil
        }
        
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.target = self
        resetButton.action = #selector(resetToDefaults(_:))
        shortcutsBox.contentView?.addSubview(resetButton)
    }
    
    private func loadSettings() {
        // copyToClipboard defaults to true when key is absent
        let copyEnabled = UserDefaults.standard.object(forKey: "copyToClipboard") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "copyToClipboard")
        copyToClipboardCheckbox.state = copyEnabled ? .on : .off
        let autoPasteEnabled = UserDefaults.standard.object(forKey: "autoPasteAtCursor") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "autoPasteAtCursor")
        autoPasteCheckbox.state = autoPasteEnabled ? .on : .off
        dockIconCheckbox.state = UserDefaults.standard.bool(forKey: "showDockIcon") ? .on : .off
        soundEffectsCheckbox.state = SoundPlayer.shared.isEnabled ? .on : .off
        
        let maxItems = HistoryStore.shared.maxItems
        maxHistorySlider.doubleValue = Self.itemsToSlider(maxItems)
        updateMaxHistoryLabel(maxItems)
        

        
        let modeRaw = UserDefaults.standard.integer(forKey: "activationMode")
        activationPicker.selectItem(at: modeRaw)
        updateHoldRowLabel()
        
        holdRow.recorder.setShortcut(Shortcut(
            keyCode: UserDefaults.standard.object(forKey: "holdKeyCode") as? Int ?? 61,
            modifiers: 0
        ))
        
        toggleRow.recorder.setShortcut(Shortcut(
            keyCode: UserDefaults.standard.object(forKey: "toggleStartKeyCode") as? Int ?? 49,
            modifiers: UInt(UserDefaults.standard.object(forKey: "toggleStartModifiers") as? Int ?? Int(NSEvent.ModifierFlags.option.rawValue))
        ))
        
        screenshotRow.recorder.setShortcut(Shortcut(
            keyCode: UserDefaults.standard.object(forKey: "screenshotKeyCode") as? Int ?? 21,
            modifiers: UInt(UserDefaults.standard.object(forKey: "screenshotModifiers") as? Int ?? Int(NSEvent.ModifierFlags.option.rawValue))
        ))
    }
    
    private func updateHoldRowLabel() {
        let isDoubleTap = activationPicker.indexOfSelectedItem == 1
        holdRow.setLabel(isDoubleTap ? "Record Key" : "Hold to Record")
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
        let generalH: CGFloat = 156
        generalBox.frame = NSRect(x: pad, y: y - generalH, width: boxW, height: generalH)
        if let cv = generalBox.contentView {
            let inset: CGFloat = 12
            let sliderRight = cv.bounds.width - inset

            copyToClipboardCheckbox.frame = NSRect(x: inset, y: cv.bounds.height - 28, width: 200, height: 20)
            autoPasteCheckbox.frame = NSRect(x: inset, y: cv.bounds.height - 50, width: 200, height: 20)
            soundEffectsCheckbox.frame = NSRect(x: inset, y: cv.bounds.height - 72, width: 200, height: 20)
            dockIconCheckbox.frame = NSRect(x: inset, y: cv.bounds.height - 94, width: 200, height: 20)

            let historyRowY = cv.bounds.height - 116
            maxHistoryLabel.frame = NSRect(x: inset, y: historyRowY, width: 120, height: 18)
            maxHistoryValueLabel.sizeToFit()
            let valueLabelW = max(130, maxHistoryValueLabel.frame.width)
            maxHistoryValueLabel.frame = NSRect(x: sliderRight - valueLabelW, y: historyRowY, width: valueLabelW, height: 18)
            maxHistorySlider.frame = NSRect(x: inset, y: historyRowY - 22, width: sliderRight - inset, height: 21)
        }
        y -= generalH + 12
        
        // Shortcuts box
        let rowH: CGFloat = 40
        let resetH: CGFloat = 32
        let shortcutsH: CGFloat = rowH * 4 + resetH + 20  // activation + 3 rows + reset + padding
        shortcutsBox.frame = NSRect(x: pad, y: y - shortcutsH, width: boxW, height: shortcutsH)
        layoutShortcutsBox()
    }
    
    private func layoutShortcutsBox() {
        guard let cv = shortcutsBox.contentView else { return }
        let rowH: CGFloat = 40
        let inset: CGFloat = 12
        let rowW = cv.bounds.width - inset * 2
        var y = cv.bounds.height - 4
        
        // Activation mode row
        y -= rowH
        let pickerW: CGFloat = 130
        activationLabel.frame = NSRect(x: inset, y: y, width: rowW - pickerW - 8, height: rowH)
        activationPicker.frame = NSRect(x: cv.bounds.width - inset - pickerW, y: y + (rowH - 26) / 2, width: pickerW, height: 26)
        activationSeparator.frame = NSRect(x: inset, y: y, width: rowW, height: 1)
        
        // Shortcut rows
        y -= rowH
        holdRow.frame = NSRect(x: inset, y: y, width: rowW, height: rowH)
        y -= rowH
        toggleRow.frame = NSRect(x: inset, y: y, width: rowW, height: rowH)
        y -= rowH
        screenshotRow.frame = NSRect(x: inset, y: y, width: rowW, height: rowH)
        
        // Reset button below everything
        resetButton.sizeToFit()
        resetButton.frame.origin = NSPoint(x: cv.bounds.width - inset - resetButton.frame.width, y: y - 28)
    }
    
    @objc private func copyToClipboardChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "copyToClipboard")
    }

    @objc private func autoPasteChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "autoPasteAtCursor")
    }

    @objc private func soundEffectsChanged(_ sender: NSButton) {
        SoundPlayer.shared.isEnabled = sender.state == .on
    }
    
    @objc private func maxHistorySliderChanged(_ sender: NSSlider) {
        let items = Self.sliderToItems(sender.doubleValue)
        updateMaxHistoryLabel(items)
        UserDefaults.standard.set(items, forKey: HistoryStore.maxItemsKey)
    }
    
    private func updateMaxHistoryLabel(_ items: Int) {
        let sizeBytes = items * HistoryStore.estimatedBytesPerEntry
        let sizeStr: String
        if sizeBytes < 1_000_000 {
            sizeStr = "\(sizeBytes / 1_000) KB"
        } else {
            sizeStr = String(format: "%.0f MB", Double(sizeBytes) / 1_000_000)
        }
        let itemsStr = items >= 1000 ? "\(items / 1000)K" : "\(items)"
        maxHistoryValueLabel.stringValue = "\(itemsStr) items · ~\(sizeStr)"
    }
    
    // Logarithmic mapping: slider 0..1 → 1,000..100,000
    private static let sliderMin = log(1_000.0)
    private static let sliderMax = log(100_000.0)
    
    private static func sliderToItems(_ t: Double) -> Int {
        let clamped = min(1, max(0, t))
        let raw = exp(sliderMin + clamped * (sliderMax - sliderMin))
        // Snap to nice round numbers
        let rounded: Int
        if raw < 2_000 { rounded = Int((raw / 500).rounded()) * 500 }
        else if raw < 10_000 { rounded = Int((raw / 1_000).rounded()) * 1_000 }
        else { rounded = Int((raw / 5_000).rounded()) * 5_000 }
        return max(1_000, min(100_000, rounded))
    }
    
    private static func itemsToSlider(_ items: Int) -> Double {
        let clamped = Double(max(1_000, min(100_000, items)))
        return (log(clamped) - sliderMin) / (sliderMax - sliderMin)
    }
    
    @objc private func dockIconChanged(_ sender: NSButton) {
        let show = sender.state == .on
        UserDefaults.standard.set(show, forKey: "showDockIcon")
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }
    
    @objc private func activationChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem, forKey: "activationMode")
        updateHoldRowLabel()
        onHotkeyChanged?()
    }
    
    @objc private func resetToDefaults(_ sender: NSButton) {
        UserDefaults.standard.set(true, forKey: "copyToClipboard")
        UserDefaults.standard.set(true, forKey: "autoPasteAtCursor")
        UserDefaults.standard.set(0, forKey: "activationMode")
        UserDefaults.standard.set(61, forKey: "holdKeyCode")
        UserDefaults.standard.set(49, forKey: "toggleStartKeyCode")
        UserDefaults.standard.set(Int(NSEvent.ModifierFlags.option.rawValue), forKey: "toggleStartModifiers")
        UserDefaults.standard.set(21, forKey: "screenshotKeyCode")
        UserDefaults.standard.set(Int(NSEvent.ModifierFlags.option.rawValue), forKey: "screenshotModifiers")
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

// MARK: - Microphone Tab

private class MicrophoneTabView: NSView {
    
    private let titleLabel = NSTextField(labelWithString: "Microphone")
    private let subtitleLabel = NSTextField(labelWithString: "Choose which microphone Hearsay uses for recording.")
    
    private let micBox = NSBox()
    private let micLabel = NSTextField(labelWithString: "Input Device")
    private let micPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let activeLabel = NSTextField(labelWithString: "")
    
    private var devices: [MicrophoneManager.AudioDevice] = []
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        setupNotifications()
        refresh()
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    private func setupUI() {
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.alignment = .center
        addSubview(titleLabel)
        
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        addSubview(subtitleLabel)
        
        // Microphone selection box
        micBox.title = "Input Device"
        micBox.titleFont = .systemFont(ofSize: 12, weight: .semibold)
        addSubview(micBox)
        
        micLabel.font = .systemFont(ofSize: 13)
        micLabel.textColor = .labelColor
        micBox.contentView?.addSubview(micLabel)
        
        micPopup.controlSize = .regular
        micPopup.font = .systemFont(ofSize: 13)
        micPopup.target = self
        micPopup.action = #selector(micSelected(_:))
        micBox.contentView?.addSubview(micPopup)
        
        activeLabel.font = .systemFont(ofSize: 11)
        activeLabel.textColor = .secondaryLabelColor
        activeLabel.alignment = .left
        micBox.contentView?.addSubview(activeLabel)
    }
    
    private func setupNotifications() {
        MicrophoneManager.shared.onDeviceListChanged = { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
        MicrophoneManager.shared.onActiveDeviceChanged = { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateActiveLabel()
            }
        }
    }
    
    func refresh() {
        devices = MicrophoneManager.shared.availableDevices
        
        // Rebuild popup menu
        micPopup.removeAllItems()
        
        // "None" = follow system default
        micPopup.addItem(withTitle: "None (System Default)")
        micPopup.menu?.addItem(.separator())
        
        for device in devices {
            let title = device.isBuiltIn ? "\(device.name)" : "\(device.name)"
            micPopup.addItem(withTitle: title)
        }
        
        // Select the current preferred device
        let selectedUID = MicrophoneManager.shared.selectedDeviceUID
        if let uid = selectedUID, let idx = devices.firstIndex(where: { $0.uid == uid }) {
            micPopup.selectItem(at: idx + 2)  // +2 for "None" + separator
        } else {
            micPopup.selectItem(at: 0)  // "None"
        }
        
        updateActiveLabel()
    }
    
    private func updateActiveLabel() {
        if let active = MicrophoneManager.shared.activeDevice {
            activeLabel.stringValue = "Currently using: \(active.name)"
            activeLabel.textColor = .secondaryLabelColor
        } else {
            activeLabel.stringValue = "No microphone available"
            activeLabel.textColor = .systemRed
        }
    }
    
    override func layout() {
        super.layout()
        
        let pad: CGFloat = 20
        var y = bounds.height - 22
        
        titleLabel.frame = NSRect(x: pad, y: y - 24, width: bounds.width - pad * 2, height: 24)
        y -= 32
        subtitleLabel.frame = NSRect(x: pad, y: y - 18, width: bounds.width - pad * 2, height: 18)
        y -= 36
        
        // Mic box
        let boxH: CGFloat = 110
        micBox.frame = NSRect(x: pad, y: y - boxH, width: bounds.width - pad * 2, height: boxH)
        
        if let cv = micBox.contentView {
            let inset: CGFloat = 12
            let popupW: CGFloat = cv.bounds.width - inset * 2
            
            micLabel.frame = NSRect(x: inset, y: cv.bounds.height - 26, width: 200, height: 18)
            micPopup.frame = NSRect(x: inset, y: cv.bounds.height - 56, width: popupW, height: 26)
            activeLabel.frame = NSRect(x: inset, y: cv.bounds.height - 78, width: popupW, height: 16)
        }
    }
    
    @objc private func micSelected(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        
        if idx == 0 {
            // "None" — use system default
            MicrophoneManager.shared.selectDevice(uid: nil)
        } else {
            // Account for separator at index 1
            let deviceIdx = idx - 2
            guard deviceIdx >= 0, deviceIdx < devices.count else { return }
            MicrophoneManager.shared.selectDevice(uid: devices[deviceIdx].uid)
        }
        
        updateActiveLabel()
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
            PermissionsManager.openAccessibilitySettings()
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
        items = HistoryStore.shared.getRecent(100)
        items.sort { $0.timestamp > $1.timestamp }
        tableView.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        scrollView.isHidden = items.isEmpty

        if !items.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.tableView.scrollRowToVisible(0)
            }
        }
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
        
        let previewText = compactDisplayText(item.text)
        let text = NSTextField(labelWithString: previewText)
        text.font = .systemFont(ofSize: 12)
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.cell?.lineBreakMode = .byTruncatingTail
        text.cell?.usesSingleLineMode = true
        text.cell?.wraps = false
        text.toolTip = item.text
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
            
            time.topAnchor.constraint(greaterThanOrEqualTo: text.bottomAnchor, constant: 4),
            time.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -6),
            time.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
        ])
        
        return cell
    }

    private func compactDisplayText(_ text: String) -> String {
        var result = text

        if let range = result.range(of: "\n\nFigure 1:", options: .literal) {
            result = String(result[..<range.lowerBound])
        } else if let range = result.range(of: "\nFigure 1:", options: .literal) {
            result = String(result[..<range.lowerBound])
        }

        result = result
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\t", with: " ")
            .replacingOccurrences(of: "\\r", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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

struct Shortcut: Equatable {
    var keyCode: Int
    var modifiers: UInt
    
    var isEmpty: Bool { keyCode == 0 }
    
    var displayString: String {
        guard !isEmpty else { return "" }
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(ShortcutRecorderView.keyName(for: keyCode))
        return parts.joined()
    }
    
    /// Check if two shortcuts conflict (same effective key combo)
    func conflicts(with other: Shortcut) -> Bool {
        guard !isEmpty && !other.isEmpty else { return false }
        return keyCode == other.keyCode && modifiers == other.modifiers
    }
}

// MARK: - Shortcut Row

/// A full-width row: label on the left, optional Clear link + shortcut badge on the right.
/// Optionally draws a bottom separator line.
private class ShortcutRowView: NSView {
    
    let recorder: ShortcutRecorderView
    private let label = NSTextField(labelWithString: "")
    private let separator = NSBox()
    
    init(label text: String, captureMode: ShortcutRecorderView.CaptureMode, placeholder: String,
         canClear: Bool, showSeparator: Bool, onChange: @escaping (Shortcut) -> Void) {
        self.recorder = ShortcutRecorderView(captureMode: captureMode, placeholder: placeholder, canClear: canClear, onChange: onChange)
        super.init(frame: .zero)
        
        label.stringValue = text
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        addSubview(recorder)
        
        separator.boxType = .separator
        separator.isHidden = !showSeparator
        addSubview(separator)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    func setLabel(_ text: String) {
        label.stringValue = text
    }
    
    override func layout() {
        super.layout()
        let recorderW: CGFloat = 200
        let h = bounds.height
        
        label.frame = NSRect(x: 0, y: 0, width: bounds.width - recorderW - 12, height: h)
        recorder.frame = NSRect(x: bounds.width - recorderW, y: (h - 28) / 2, width: recorderW, height: 28)
        separator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
    }
}

// MARK: - Shortcut Recorder

private class ShortcutRecorderView: NSView {
    enum CaptureMode { case singleModifier, singleKey, keyCombo }
    
    private let captureMode: CaptureMode
    private let placeholder: String
    private let canClear: Bool
    private let onChange: (Shortcut) -> Void
    private let button = NSButton()
    private let clearButton = NSButton()
    private var isRecording = false
    private(set) var currentShortcut = Shortcut(keyCode: 0, modifiers: 0)
    private var eventMonitor: Any?
    var onConflict: ((Shortcut) -> String?)?
    
    var displayString: String {
        guard !currentShortcut.isEmpty else { return "" }
        return captureMode == .singleModifier ? Self.keyName(for: currentShortcut.keyCode) : currentShortcut.displayString
    }
    
    init(captureMode: CaptureMode, placeholder: String, canClear: Bool = false, onChange: @escaping (Shortcut) -> Void) {
        self.captureMode = captureMode
        self.placeholder = placeholder
        self.canClear = canClear
        self.onChange = onChange
        super.init(frame: .zero)
        
        clearButton.title = "Clear"
        clearButton.bezelStyle = .inline
        clearButton.controlSize = .small
        clearButton.isBordered = false
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.font = .systemFont(ofSize: 12)
        clearButton.target = self
        clearButton.action = #selector(clearClicked(_:))
        clearButton.isHidden = true
        addSubview(clearButton)
        
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        button.target = self
        button.action = #selector(clicked(_:))
        button.title = placeholder
        addSubview(button)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    func setShortcut(_ s: Shortcut) {
        currentShortcut = s
        button.title = s.isEmpty ? placeholder : displayString
        updateButtonStyle()
        updateClearButton()
    }
    
    private func updateClearButton() {
        clearButton.isHidden = !canClear || currentShortcut.isEmpty
    }
    
    override func layout() {
        super.layout()
        let buttonW: CGFloat = 120
        let clearW: CGFloat = 42
        let gap: CGFloat = 6
        
        // Button pinned to the right
        button.frame = NSRect(x: bounds.width - buttonW, y: 0, width: buttonW, height: bounds.height)
        
        if canClear && !clearButton.isHidden {
            clearButton.frame = NSRect(x: bounds.width - buttonW - gap - clearW, y: (bounds.height - 18) / 2, width: clearW, height: 18)
        } else {
            clearButton.frame = .zero
        }
    }
    
    @objc private func clicked(_ sender: NSButton) { isRecording ? stop() : start() }
    
    @objc private func clearClicked(_ sender: NSButton) {
        currentShortcut = Shortcut(keyCode: 0, modifiers: 0)
        button.title = placeholder
        updateButtonStyle()
        updateClearButton()
        onChange(currentShortcut)
        needsLayout = true
    }
    
    private func updateButtonStyle() {
        if isRecording {
            button.contentTintColor = .controlAccentColor
            button.font = .systemFont(ofSize: 12, weight: .medium)
        } else if currentShortcut.isEmpty {
            button.contentTintColor = .tertiaryLabelColor
            button.font = .systemFont(ofSize: 12)
        } else {
            button.contentTintColor = nil
            button.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        }
    }
    
    private func start() {
        isRecording = true
        button.title = "Press key…"
        updateButtonStyle()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] in self?.handle($0) }
    }
    
    private func stop() {
        isRecording = false
        button.title = currentShortcut.isEmpty ? placeholder : displayString
        updateButtonStyle()
        updateClearButton()
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        eventMonitor = nil
        needsLayout = true
    }
    
    private func handle(_ e: NSEvent) -> NSEvent? {
        let kc = Int(e.keyCode)
        let mods = e.modifierFlags.intersection([.command, .option, .shift, .control]).rawValue
        
        // Escape cancels
        if kc == 53 { stop(); return nil }
        
        // Delete/Backspace clears (if clearable)
        if canClear && (kc == 51 || kc == 117) && e.type == .keyDown {
            clearClicked(clearButton)
            stop()
            return nil
        }
        
        var candidate: Shortcut?
        
        switch captureMode {
        case .singleModifier where Self.isMod(kc) && e.type == .flagsChanged:
            candidate = Shortcut(keyCode: kc, modifiers: 0)
        case .singleKey where !Self.isMod(kc) && e.type == .keyDown:
            candidate = Shortcut(keyCode: kc, modifiers: 0)
        case .keyCombo where !Self.isMod(kc) && e.type == .keyDown:
            candidate = Shortcut(keyCode: kc, modifiers: mods)
        default: break
        }
        
        if let candidate = candidate {
            // Check for conflict
            if let conflictMsg = onConflict?(candidate) {
                showConflictAlert(conflictMsg)
            } else {
                currentShortcut = candidate
                onChange(currentShortcut)
            }
            stop()
        }
        
        return nil
    }
    
    private func showConflictAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Shortcut Conflict"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

// MARK: - Cleanup Tab

private class CleanupTabView: NSView, NSTextViewDelegate {
    
    var onSettingsChanged: (() -> Void)?
    
    private let titleLabel = NSTextField(labelWithString: "Text Cleanup")
    private let subtitleLabel = NSTextField(labelWithString: "Use a local LLM to clean up transcriptions — removes filler words, fixes punctuation, and polishes text.")
    
    private let enabledCheckbox = NSButton(checkboxWithTitle: "Enable text cleanup", target: nil, action: nil)
    
    private let modelBox = NSBox()
    private let modelNameLabel = NSTextField(labelWithString: "")
    private let modelSizeLabel = NSTextField(labelWithString: "")
    private let modelDescLabel = NSTextField(labelWithString: "")
    private let modelStatusLabel = NSTextField(labelWithString: "")
    
    private let actionButton = NSButton()
    private let deleteButton = NSButton(title: "Delete Model", target: nil, action: nil)
    
    private let progressContainer = NSView()
    private let progressBar = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")

    private let promptBox = NSBox()
    private let promptScrollView = NSScrollView()
    private let promptTextView = NSTextView()
    private let resetPromptButton = NSButton(title: "Reset to Default Prompt", target: nil, action: nil)
    private let openPromptEditorButton = NSButton(title: "Open Full Editor…", target: nil, action: nil)
    private let promptEditorController = CleanupPromptEditorController()
    
    private let exampleBox = NSBox()
    private let exampleLabel = NSTextField(wrappingLabelWithString: "")
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        setupObservers()
        refresh()
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    private func setupUI() {
        // Title
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.alignment = .center
        addSubview(titleLabel)
        
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.preferredMaxLayoutWidth = 480
        addSubview(subtitleLabel)
        
        // Enable checkbox
        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(enabledChanged(_:))
        addSubview(enabledCheckbox)
        
        // Model card box
        modelBox.title = "Cleanup Model"
        modelBox.titleFont = .systemFont(ofSize: 12, weight: .semibold)
        addSubview(modelBox)
        
        let model = CleanupModelDownloader.CleanupModel.qwen35_0_8b
        modelNameLabel.stringValue = model.displayName
        modelNameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        modelBox.contentView?.addSubview(modelNameLabel)
        
        modelSizeLabel.stringValue = "Size: \(model.estimatedSizeString)"
        modelSizeLabel.font = .systemFont(ofSize: 11)
        modelSizeLabel.textColor = .secondaryLabelColor
        modelBox.contentView?.addSubview(modelSizeLabel)
        
        modelDescLabel.stringValue = model.description
        modelDescLabel.font = .systemFont(ofSize: 11)
        modelDescLabel.textColor = .tertiaryLabelColor
        modelBox.contentView?.addSubview(modelDescLabel)
        
        modelStatusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        modelStatusLabel.alignment = .right
        modelBox.contentView?.addSubview(modelStatusLabel)
        
        // Action button
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .large
        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        addSubview(actionButton)
        
        // Delete button
        deleteButton.bezelStyle = .rounded
        deleteButton.controlSize = .regular
        deleteButton.contentTintColor = .systemRed
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        addSubview(deleteButton)
        
        // Progress
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

        // Prompt editor
        promptBox.title = "Cleanup Prompt"
        promptBox.titleFont = .systemFont(ofSize: 12, weight: .semibold)
        addSubview(promptBox)

        promptScrollView.borderType = .bezelBorder
        promptScrollView.hasVerticalScroller = true
        promptScrollView.hasHorizontalScroller = false
        promptScrollView.autohidesScrollers = true
        promptScrollView.drawsBackground = true
        promptScrollView.backgroundColor = .textBackgroundColor

        promptTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        promptTextView.isRichText = false
        promptTextView.isAutomaticQuoteSubstitutionEnabled = false
        promptTextView.isAutomaticDashSubstitutionEnabled = false
        promptTextView.isAutomaticTextReplacementEnabled = false
        promptTextView.delegate = self
        promptTextView.string = CleanupSettings.prompt
        promptScrollView.documentView = promptTextView
        promptBox.contentView?.addSubview(promptScrollView)

        resetPromptButton.bezelStyle = .rounded
        resetPromptButton.controlSize = .small
        resetPromptButton.target = self
        resetPromptButton.action = #selector(resetPromptTapped)
        promptBox.contentView?.addSubview(resetPromptButton)

        openPromptEditorButton.bezelStyle = .rounded
        openPromptEditorButton.controlSize = .small
        openPromptEditorButton.target = self
        openPromptEditorButton.action = #selector(openPromptEditorTapped)
        promptBox.contentView?.addSubview(openPromptEditorButton)
        
        // Example box
        exampleBox.title = "Example"
        exampleBox.titleFont = .systemFont(ofSize: 12, weight: .semibold)
        addSubview(exampleBox)
        
        let exampleText = """
        Before: "So um like the meeting is at 3pm you know on Tuesday"
        After:    "The meeting is at 3pm on Tuesday"
        """
        exampleLabel.stringValue = exampleText
        exampleLabel.font = .systemFont(ofSize: 11)
        exampleLabel.textColor = .secondaryLabelColor
        exampleLabel.maximumNumberOfLines = 3
        exampleBox.contentView?.addSubview(exampleLabel)
    }
    
    private func setupObservers() {
        // Poll-based refresh since CleanupModelDownloader uses @Published (Combine)
        // and we're in AppKit — simplest to just refresh on a timer when downloading
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let downloader = CleanupModelDownloader.shared
            if downloader.isDownloading {
                self.progressBar.doubleValue = downloader.progress
                self.progressLabel.stringValue = "\(Int(downloader.progress * 100))%"
            }
            if downloader.isComplete || downloader.error != nil {
                self.refresh()
            }
        }
    }
    
    func refresh() {
        let downloader = CleanupModelDownloader.shared
        let installed = downloader.isModelInstalled()
        let enabled = downloader.isEnabled

        if window?.firstResponder as AnyObject? !== promptTextView,
           promptTextView.string != CleanupSettings.prompt {
            promptTextView.string = CleanupSettings.prompt
        }
        
        enabledCheckbox.state = enabled ? .on : .off
        enabledCheckbox.isEnabled = installed  // Can only enable if model is downloaded
        
        if downloader.isDownloading {
            actionButton.isHidden = true
            deleteButton.isHidden = true
            progressContainer.isHidden = false
        } else {
            progressContainer.isHidden = true
            
            if installed {
                actionButton.isHidden = true
                deleteButton.isHidden = false
                enabledCheckbox.isEnabled = true
                modelStatusLabel.stringValue = "✓ Downloaded"
                modelStatusLabel.textColor = .systemGreen
            } else {
                actionButton.isHidden = false
                actionButton.title = "Download Model"
                deleteButton.isHidden = true
                enabledCheckbox.state = .off
                enabledCheckbox.isEnabled = false
                modelStatusLabel.stringValue = "Not downloaded"
                modelStatusLabel.textColor = .tertiaryLabelColor
            }
        }
        
        if let error = downloader.error {
            modelStatusLabel.stringValue = "Error: \(error)"
            modelStatusLabel.textColor = .systemRed
        }
    }
    
    override func layout() {
        super.layout()
        
        let pad: CGFloat = 20
        let contentW = bounds.width - pad * 2
        var y = bounds.height - 22
        
        // Title
        titleLabel.frame = NSRect(x: pad, y: y - 24, width: contentW, height: 24)
        y -= 30
        
        subtitleLabel.frame = NSRect(x: pad, y: y - 34, width: contentW, height: 34)
        y -= 46
        
        // Checkbox
        enabledCheckbox.frame = NSRect(x: pad, y: y - 20, width: contentW, height: 20)
        y -= 32
        
        // Model box
        let boxH: CGFloat = 90
        modelBox.frame = NSRect(x: pad, y: y - boxH, width: contentW, height: boxH)
        if let cv = modelBox.contentView {
            let inset: CGFloat = 12
            modelNameLabel.frame = NSRect(x: inset, y: cv.bounds.height - 24, width: cv.bounds.width - inset * 2 - 120, height: 18)
            modelStatusLabel.frame = NSRect(x: cv.bounds.width - inset - 120, y: cv.bounds.height - 24, width: 120, height: 18)
            modelSizeLabel.frame = NSRect(x: inset, y: cv.bounds.height - 44, width: cv.bounds.width - inset * 2, height: 16)
            modelDescLabel.frame = NSRect(x: inset, y: cv.bounds.height - 62, width: cv.bounds.width - inset * 2, height: 16)
        }
        y -= boxH + 12
        
        // Action / Progress / Delete
        let buttonW: CGFloat = 200
        actionButton.frame = NSRect(x: bounds.midX - buttonW / 2, y: y - 34, width: buttonW, height: 34)
        deleteButton.sizeToFit()
        deleteButton.frame.origin = NSPoint(x: bounds.midX - deleteButton.frame.width / 2, y: y - 30)

        progressContainer.frame = NSRect(x: 60, y: y - 42, width: bounds.width - 120, height: 42)
        progressBar.frame = NSRect(x: 0, y: 20, width: progressContainer.bounds.width, height: 18)
        progressLabel.frame = NSRect(x: 0, y: 0, width: progressContainer.bounds.width, height: 16)
        y -= 54

        // Prompt + Example layout (adaptive so controls never overlap)
        let bottomPad: CGFloat = 12
        let spacing: CGFloat = 10
        let minPromptH: CGFloat = 90
        let preferredExampleH: CGFloat = 70
        let available = max(0, y - bottomPad)

        let canShowExample = available >= (minPromptH + spacing + preferredExampleH)
        let exampleH: CGFloat = canShowExample ? preferredExampleH : 0
        let promptH = max(minPromptH, available - (canShowExample ? (spacing + exampleH) : 0))

        promptBox.frame = NSRect(x: pad, y: max(bottomPad, y - promptH), width: contentW, height: promptH)
        if let cv = promptBox.contentView {
            let inset: CGFloat = 10
            openPromptEditorButton.sizeToFit()
            openPromptEditorButton.frame = NSRect(
                x: inset,
                y: cv.bounds.height - 24,
                width: openPromptEditorButton.frame.width,
                height: 18
            )

            resetPromptButton.sizeToFit()
            resetPromptButton.frame = NSRect(
                x: cv.bounds.width - inset - resetPromptButton.frame.width,
                y: cv.bounds.height - 24,
                width: resetPromptButton.frame.width,
                height: 18
            )
            promptScrollView.frame = NSRect(
                x: inset,
                y: 10,
                width: cv.bounds.width - inset * 2,
                height: max(40, cv.bounds.height - 40)
            )
            promptTextView.frame = promptScrollView.bounds
        }

        if canShowExample {
            exampleBox.isHidden = false
            exampleBox.frame = NSRect(x: pad, y: bottomPad, width: contentW, height: exampleH)
            if let cv = exampleBox.contentView {
                exampleLabel.frame = cv.bounds.insetBy(dx: 12, dy: 4)
            }
        } else {
            exampleBox.isHidden = true
        }
    }
    
    func textDidChange(_ notification: Notification) {
        CleanupSettings.prompt = promptTextView.string
    }

    @objc private func resetPromptTapped() {
        CleanupSettings.resetPrompt()
        promptTextView.string = CleanupSettings.prompt
    }

    @objc private func openPromptEditorTapped() {
        promptEditorController.show()
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        CleanupModelDownloader.shared.isEnabled = sender.state == .on
        onSettingsChanged?()
    }
    
    @objc private func actionTapped() {
        CleanupModelDownloader.shared.download { [weak self] success in
            DispatchQueue.main.async {
                if success {
                    CleanupModelDownloader.shared.isEnabled = true
                    self?.onSettingsChanged?()
                }
                self?.refresh()
            }
        }
        refresh()
    }
    
    @objc private func deleteTapped() {
        let alert = NSAlert()
        alert.messageText = "Delete Cleanup Model?"
        alert.informativeText = "This will remove the downloaded model (\(CleanupModelDownloader.CleanupModel.qwen35_0_8b.estimatedSizeString)). You can re-download it anytime."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            CleanupModelDownloader.shared.isEnabled = false
            CleanupModelDownloader.shared.deleteModel()
            onSettingsChanged?()
            refresh()
        }
    }
}
