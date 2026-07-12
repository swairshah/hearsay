import AppKit

/// Manages the menu bar status item and dropdown menu.
final class StatusBarController {
    
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    
    // Menu items we need to update
    private var toggleItem: NSMenuItem!
    private var modelItem: NSMenuItem!
    private var historySubmenu: NSMenu!
    private var historyMenuItem: NSMenuItem!
    
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
    var onQuit: (() -> Void)?
    
    private(set) var isEnabled = true
    
    init() {
        setupStatusItem()
        setupMenu()
        
        // Listen for history changes
        HistoryStore.shared.addChangeObserver { [weak self] in
            self?.updateHistorySubmenu()
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
        
        // History submenu
        historyMenuItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
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
        
        statusItem.menu = menu
        
        // Initial history update
        updateHistorySubmenu()
    }
    
    private func updateHistorySubmenu() {
        historySubmenu.removeAllItems()
        
        let recentItems = HistoryStore.shared.getRecent(10)
        
        if recentItems.isEmpty {
            let emptyItem = NSMenuItem(title: "No transcriptions yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            historySubmenu.addItem(emptyItem)
        } else {
            for (index, item) in recentItems.enumerated() {
                let menuItem = NSMenuItem(
                    title: item.menuTitle,
                    action: #selector(copyHistoryItem(_:)),
                    keyEquivalent: index < 9 ? "\(index + 1)" : ""
                )
                menuItem.target = self
                menuItem.representedObject = item
                menuItem.toolTip = "\(item.formattedTime)\n\n\(item.text)"
                historySubmenu.addItem(menuItem)
            }
        }
    }
    
    // MARK: - Public
    
    func updateModelName(_ name: String?) {
        if let name = name {
            modelItem.title = "Model: \(name)"
        } else {
            modelItem.title = "Model: Not installed"
        }
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
        if let button = statusItem.button {
            if isRecording {
                // Change to red tint during recording
                button.contentTintColor = Constants.recordingDot
            } else {
                // Reset to normal (template mode handles dark/light)
                button.contentTintColor = nil
            }
        }
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
    
    @objc private func showHistory(_ sender: NSMenuItem) {
        onShowHistory?()
    }
    
    @objc private func showSettings(_ sender: NSMenuItem) {
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
