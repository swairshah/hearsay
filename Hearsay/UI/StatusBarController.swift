import AppKit

/// Manages the menu bar status item and dropdown menu.
final class StatusBarController: NSObject, NSMenuDelegate {
    
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    
    // Menu items we need to update
    private var toggleItem: NSMenuItem!
    private var modelItem: NSMenuItem!
    private var historySubmenu: NSMenu!
    private var historyMenuItem: NSMenuItem!
    private var meetingItem: NSMenuItem!
    private var liveTranscriptItem: NSMenuItem!
    private var meetingMenuTimer: Timer?

    /// Dictation and meeting recording each turn the icon red; track both so
    /// one finishing doesn't clear the other.
    private var isDictating = false
    private var isRecordingMeeting = false

    /// Anchor the inline "Recent" section is rebuilt around, plus the rows we
    /// currently own so they can be swapped out without rebuilding the menu.
    private var recentHeaderItem: NSMenuItem!
    private var inlineHistoryItems: [NSMenuItem] = []

    /// How many transcriptions render inline in the dropdown itself.
    private let inlineHistoryCount = 4
    /// How many *more* are reachable by hovering the "Older" submenu.
    private let submenuHistoryCount = 20
    
    var onToggleEnabled: ((Bool) -> Void)?
    var onShowHistory: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onShowPermissions: (() -> Void)?
    var onShowOnboarding: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onOpenDiagnosticLog: (() -> Void)?
    var onCopyDiagnosticLogs: (() -> Void)?
    var onEmailDiagnosticLogs: (() -> Void)?
    var onRevealDiagnosticLog: (() -> Void)?
    var onClearDiagnosticLogs: (() -> Void)?
    var onCopyHistoryItem: ((TranscriptionItem) -> Void)?
    var onToggleMeetingRecording: (() -> Void)?
    var onShowMeetings: (() -> Void)?
    /// Opens the Meetings pane on the meeting being recorded.
    var onShowLiveMeeting: (() -> Void)?
    var onQuit: (() -> Void)?
    /// Mirrors the active model name so other chrome (e.g. the window's sidebar
    /// footer) can show the same status without re-deriving it.
    var onModelNameChanged: ((String?) -> Void)?
    
    private(set) var isEnabled = true
    
    override init() {
        super.init()
        setupStatusItem()
        setupMenu()
        
        // Listen for history changes
        HistoryStore.shared.addChangeObserver { [weak self] in
            self?.refreshHistorySections()
        }
    }
    
    // MARK: - Setup
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem.button {
            // Use custom template image for menu bar
            if let image = NSImage(named: "hearsayTemplate") {
                image.isTemplate = true  // Allows system to adjust for dark/light mode
                button.image = image
            } else if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Hearsay") {
                // Fallback to SF Symbol
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                button.image = image.withSymbolConfiguration(config)
            } else {
                button.title = "🎙"
            }
            
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }
    
    private func setupMenu() {
        menu = NSMenu()
        menu.autoenablesItems = false  // Disable auto-validation for status bar menu
        
        // Open main app window
        let openWindowItem = NSMenuItem(title: "Open Window", action: #selector(openWindow(_:)), keyEquivalent: "o")
        openWindowItem.target = self
        openWindowItem.isEnabled = true
        menu.addItem(openWindowItem)

        menu.addItem(.separator())

        // Meeting recording
        meetingItem = NSMenuItem(title: "Record Meeting", action: #selector(toggleMeetingRecording(_:)), keyEquivalent: "")
        meetingItem.target = self
        meetingItem.isEnabled = true
        meetingItem.image = Self.recordMeetingImage
        menu.addItem(meetingItem)

        liveTranscriptItem = NSMenuItem(title: "Show Live Transcript", action: #selector(showLiveMeeting(_:)), keyEquivalent: "")
        liveTranscriptItem.target = self
        liveTranscriptItem.isEnabled = true
        liveTranscriptItem.isHidden = true
        menu.addItem(liveTranscriptItem)

        let meetingsItem = NSMenuItem(title: "Meetings…", action: #selector(showMeetings(_:)), keyEquivalent: "")
        meetingsItem.target = self
        meetingsItem.isEnabled = true
        menu.addItem(meetingsItem)

        menu.addItem(.separator())
        
        // Toggle enabled
        toggleItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = .on
        toggleItem.isEnabled = true
        menu.addItem(toggleItem)
        
        menu.addItem(.separator())
        
        // Current model
        modelItem = NSMenuItem(title: "Model: None", action: nil, keyEquivalent: "")
        modelItem.isEnabled = false
        menu.addItem(modelItem)
        
        // Download/Manage models
        let modelsMenuItem = NSMenuItem(title: "Manage Models...", action: #selector(showOnboarding(_:)), keyEquivalent: "")
        modelsMenuItem.target = self
        modelsMenuItem.isEnabled = true
        menu.addItem(modelsMenuItem)
        
        let permissionsItem = NSMenuItem(title: "Permissions...", action: #selector(showPermissions(_:)), keyEquivalent: "")
        permissionsItem.target = self
        permissionsItem.isEnabled = true
        menu.addItem(permissionsItem)
        
        menu.addItem(.separator())
        
        // Inline "Recent" section — the newest few transcriptions render as
        // custom rows directly in the dropdown (no hovering required).
        recentHeaderItem = NSMenuItem()
        recentHeaderItem.isEnabled = false
        recentHeaderItem.view = MenuSectionHeaderView(title: "Recent")
        menu.addItem(recentHeaderItem)

        // Everything older stays behind a hover submenu.
        historyMenuItem = NSMenuItem(title: "Older", action: nil, keyEquivalent: "")
        historySubmenu = NSMenu()
        historyMenuItem.submenu = historySubmenu
        menu.addItem(historyMenuItem)
        
        // View all history
        let allHistoryItem = NSMenuItem(title: "View All History...", action: #selector(showHistory(_:)), keyEquivalent: "h")
        allHistoryItem.target = self
        allHistoryItem.isEnabled = true
        menu.addItem(allHistoryItem)
        
        menu.addItem(.separator())
        
        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.isEnabled = true
        menu.addItem(settingsItem)
        
        // Help
        let helpItem = NSMenuItem(title: "How to Use", action: #selector(showHelp(_:)), keyEquivalent: "")
        helpItem.target = self
        helpItem.isEnabled = true
        menu.addItem(helpItem)
        
        // Check for Updates
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = self
        updateItem.isEnabled = true
        menu.addItem(updateItem)

        let diagnosticsItem = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        let diagnosticsMenu = NSMenu()

        let openLogItem = NSMenuItem(title: "Open Diagnostic Log", action: #selector(openDiagnosticLog(_:)), keyEquivalent: "")
        openLogItem.target = self
        openLogItem.isEnabled = true
        diagnosticsMenu.addItem(openLogItem)

        let copyLogsItem = NSMenuItem(title: "Copy Diagnostic Logs", action: #selector(copyDiagnosticLogs(_:)), keyEquivalent: "")
        copyLogsItem.target = self
        copyLogsItem.isEnabled = true
        diagnosticsMenu.addItem(copyLogsItem)

        let emailLogsItem = NSMenuItem(title: "Send Diagnostic Logs…", action: #selector(emailDiagnosticLogs(_:)), keyEquivalent: "")
        emailLogsItem.target = self
        emailLogsItem.isEnabled = true
        diagnosticsMenu.addItem(emailLogsItem)

        let revealLogItem = NSMenuItem(title: "Reveal Diagnostic Log", action: #selector(revealDiagnosticLog(_:)), keyEquivalent: "")
        revealLogItem.target = self
        revealLogItem.isEnabled = true
        diagnosticsMenu.addItem(revealLogItem)

        diagnosticsMenu.addItem(.separator())

        let clearLogsItem = NSMenuItem(title: "Clear Diagnostic Logs", action: #selector(clearDiagnosticLogs(_:)), keyEquivalent: "")
        clearLogsItem.target = self
        clearLogsItem.isEnabled = true
        diagnosticsMenu.addItem(clearLogsItem)

        diagnosticsItem.submenu = diagnosticsMenu
        menu.addItem(diagnosticsItem)
        
        menu.addItem(.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit Hearsay", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)
        
        menu.delegate = self
        statusItem.menu = menu
        
        // Initial history update
        refreshHistorySections()
    }

    // MARK: - History sections

    /// Rebuilds both the inline rows and the "Older" hover submenu.
    private func refreshHistorySections() {
        let recent = HistoryStore.shared.getRecent(inlineHistoryCount + submenuHistoryCount)
        updateInlineHistory(Array(recent.prefix(inlineHistoryCount)))
        updateHistorySubmenu(Array(recent.dropFirst(inlineHistoryCount)))
    }

    private func updateInlineHistory(_ items: [TranscriptionItem]) {
        // Drop the rows we inserted last time.
        for item in inlineHistoryItems where menu.index(of: item) >= 0 {
            menu.removeItem(item)
        }
        inlineHistoryItems.removeAll()

        guard let anchor = recentHeaderItem, menu.index(of: anchor) >= 0 else { return }
        var insertIndex = menu.index(of: anchor) + 1

        if items.isEmpty {
            let empty = NSMenuItem()
            empty.isEnabled = false
            empty.view = MenuEmptyStateView(message: "No transcriptions yet")
            menu.insertItem(empty, at: insertIndex)
            inlineHistoryItems.append(empty)
            return
        }

        for (index, item) in items.enumerated() {
            let menuItem = NSMenuItem()
            // ⌘1…⌘4 still work even though the row draws itself.
            menuItem.keyEquivalent = "\(index + 1)"
            menuItem.keyEquivalentModifierMask = [.command]
            menuItem.action = #selector(copyHistoryItem(_:))
            menuItem.target = self
            menuItem.representedObject = item
            menuItem.view = MenuHistoryRowView(item: item) { [weak self] selected in
                self?.onCopyHistoryItem?(selected)
            }
            menu.insertItem(menuItem, at: insertIndex)
            inlineHistoryItems.append(menuItem)
            insertIndex += 1
        }
    }
    
    private func updateHistorySubmenu(_ items: [TranscriptionItem]) {
        historySubmenu.removeAllItems()

        historyMenuItem.isHidden = items.isEmpty
        guard !items.isEmpty else { return }

        historyMenuItem.title = "Older (\(items.count))"

        for item in items {
            let menuItem = NSMenuItem(
                title: item.menuTitle,
                action: #selector(copyHistoryItem(_:)),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.representedObject = item
            menuItem.toolTip = "\(item.formattedTime)\n\n\(item.text)"
            historySubmenu.addItem(menuItem)
        }
    }

    // MARK: - NSMenuDelegate

    /// Relative timestamps go stale between openings, so rebuild on every open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        refreshHistorySections()
        refreshMeetingItem()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu, isRecordingMeeting else { return }
        // Keep the elapsed time ticking while the menu is open (menu tracking
        // runs the loop in event-tracking mode, hence `.common`).
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshMeetingItem() }
        RunLoop.main.add(timer, forMode: .common)
        meetingMenuTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        meetingMenuTimer?.invalidate()
        meetingMenuTimer = nil
    }

    /// Shows the global Record Meeting shortcut on the item (nil clears it).
    /// Only single-character keys can be shown as a menu key equivalent.
    func setMeetingShortcut(_ shortcut: Shortcut?) {
        guard let shortcut, shortcut.keyLabel.count == 1 else {
            meetingItem.keyEquivalent = ""
            meetingItem.keyEquivalentModifierMask = []
            return
        }
        meetingItem.keyEquivalent = shortcut.keyLabel.lowercased()
        meetingItem.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: shortcut.modifiers)
            .intersection([.command, .option, .control, .shift])
    }

    /// Red, like a record button; menu item images are template (grey) by default.
    private static let recordMeetingImage: NSImage? = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record")?
        .withSymbolConfiguration(.init(paletteColors: [.systemRed]))

    private static let stopMeetingImage: NSImage? = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop")?
        .withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))

    private func refreshMeetingItem() {
        let recorder = MeetingRecorder.shared
        if let live = recorder.live {
            if live.phase == .recording {
                meetingItem.title = "Stop Recording Meeting  (\(MeetingTranscriptFormatter.timestamp(live.elapsed)))"
                meetingItem.image = Self.stopMeetingImage
                meetingItem.isEnabled = true
            } else {
                meetingItem.title = "Saving Meeting…"
                meetingItem.isEnabled = false
            }
            liveTranscriptItem.isHidden = false
        } else {
            meetingItem.title = "Record Meeting"
            meetingItem.image = Self.recordMeetingImage
            meetingItem.isEnabled = true
            liveTranscriptItem.isHidden = true
        }
    }
    
    // MARK: - Public
    
    private(set) var modelName: String?

    func updateModelName(_ name: String?) {
        modelName = name
        if let name = name {
            modelItem.title = "Model: \(name)"
        } else {
            modelItem.title = "Model: Not installed"
        }
        onModelNameChanged?(name)
    }
    
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        toggleItem.state = enabled ? .on : .off
        
        // Update icon appearance
        if let button = statusItem.button {
            button.appearsDisabled = !enabled
        }
    }
    
    func showRecordingState(_ isRecording: Bool) {
        isDictating = isRecording
        updateRecordingTint()
    }

    func showMeetingRecordingState(_ isRecording: Bool) {
        isRecordingMeeting = isRecording
        updateRecordingTint()
        refreshMeetingItem()
        statusItem.button?.toolTip = isRecording ? "Hearsay — recording a meeting" : nil
    }

    private func updateRecordingTint() {
        guard let button = statusItem.button else { return }
        // Red while anything records; nil restores the template (dark/light) tint.
        button.contentTintColor = (isDictating || isRecordingMeeting) ? Constants.recordingDot : nil
    }
    
    // MARK: - Actions
    
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        // Just show the menu
        statusItem.button?.performClick(nil)
    }
    
    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        isEnabled.toggle()
        sender.state = isEnabled ? .on : .off
        
        if let button = statusItem.button {
            button.appearsDisabled = !isEnabled
        }
        
        onToggleEnabled?(isEnabled)
    }
    
    @objc private func toggleMeetingRecording(_ sender: NSMenuItem) {
        onToggleMeetingRecording?()
    }

    @objc private func showMeetings(_ sender: NSMenuItem) {
        onShowMeetings?()
    }

    @objc private func showLiveMeeting(_ sender: NSMenuItem) {
        onShowLiveMeeting?()
    }

    @objc private func showHistory(_ sender: NSMenuItem) {
        onShowHistory?()
    }
    
    @objc private func showSettings(_ sender: NSMenuItem) {
        onShowSettings?()
    }
    
    @objc private func openWindow(_ sender: NSMenuItem) {
        onShowSettings?()
    }
    
    @objc private func showPermissions(_ sender: NSMenuItem) {
        onShowPermissions?()
    }
    
    @objc private func showOnboarding(_ sender: NSMenuItem) {
        onShowOnboarding?()
    }
    
    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? TranscriptionItem else { return }
        onCopyHistoryItem?(item)
    }
    
    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        onCheckForUpdates?()
    }

    @objc private func openDiagnosticLog(_ sender: NSMenuItem) {
        onOpenDiagnosticLog?()
    }

    @objc private func copyDiagnosticLogs(_ sender: NSMenuItem) {
        onCopyDiagnosticLogs?()
    }

    @objc private func emailDiagnosticLogs(_ sender: NSMenuItem) {
        onEmailDiagnosticLogs?()
    }

    @objc private func revealDiagnosticLog(_ sender: NSMenuItem) {
        onRevealDiagnosticLog?()
    }

    @objc private func clearDiagnosticLogs(_ sender: NSMenuItem) {
        onClearDiagnosticLogs?()
    }
    
    @objc private func showHelp(_ sender: NSMenuItem) {
        // Show a simple alert with usage instructions
        let alert = NSAlert()
        alert.messageText = "How to Use Hearsay"
        alert.informativeText = """
        1. Hold the RIGHT Option (⌥) key to start recording
        2. Speak your message
        3. Release Option to transcribe
        4. Text is automatically pasted at your cursor and copied to clipboard
        
        Tips:
        • Make sure Hearsay has Accessibility and Microphone permissions
        • The indicator shows recording status at the bottom of your screen
        • Recent transcriptions appear in the menu for quick access
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Got it")
        alert.runModal()
    }
    
    @objc private func quit(_ sender: NSMenuItem) {
        onQuit?()
    }
}
