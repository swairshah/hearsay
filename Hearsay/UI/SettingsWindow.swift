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
        case shortcuts
        case postProcessing
        case about
        case meetings
        case vocabulary
        case keyboard
    }
    
    var onHotkeyChanged: (() -> Void)?
    var onWindowOpened: (() -> Void)?
    var onWindowClosed: (() -> Void)?
    var onModelChanged: (() -> Void)?
    var onCleanupSettingsChanged: (() -> Void)?
    /// Re-run a failed transcription (provided by AppDelegate); calls back with success.
    var onRetryTranscription: ((TranscriptionItem, @escaping (Bool) -> Void) -> Void)?
    /// Returns true while a transcription is running; used to block model deletion.
    var isTranscriptionInProgress: (() -> Bool)?
    /// Start or stop meeting recording (provided by AppDelegate).
    var onToggleMeetingRecording: (() -> Void)?
    
    /// Sidebar navigation + a container that swaps in one pane at a time
    /// (replaces the old top-tab `NSTabView`).
    private let sidebarStack = NSStackView()
    private let detailContainer = AdaptiveBackgroundView(color: .windowBackgroundColor)
    private var sidebarItems: [SidebarItemView] = []
    private var panes: [String: NSView] = [:]
    private var currentPaneID: String?
    private var sidebarFooter: SidebarFooterView!

    private var settingsTab: SettingsTabView!
    private var keyboardTab: KeyboardShortcutsTabView!
    private var historyTab: HistoryTabView!
    private var permissionsTab: PermissionsTabView!
    private var modelsTab: ModelsTabView!
    private var microphoneTab: MicrophoneTabView!
    private var cleanupTab: DeterministicCleanupTabView!
    private var shortcutsTab: ShortcutReplacementTabView!
    private var postProcessingTab: CleanupTabView!
    private var aboutTab: AboutTabView!
    private var meetingsTab: MeetingsPaneView!
    private var vocabularyTab: VocabularyPaneView!
    
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
        window.minSize = NSSize(width: 780, height: 560)

        // Let the sidebar material run all the way up behind the traffic lights.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        
        self.init(window: window)
        window.delegate = self
        setupUI()
    }

    // MARK: - Layout

    /// One sidebar entry: pane identifier, label, SF Symbol.
    private struct NavEntry {
        let id: String
        let title: String
        let symbol: String
    }

    /// Sidebar grouping — flat lists get noisy past ~6 items.
    private static let navSections: [(title: String?, entries: [NavEntry])] = [
        (nil, [
            NavEntry(id: "settings", title: "Settings", symbol: "gearshape"),
            NavEntry(id: "models", title: "Models", symbol: "square.stack.3d.up"),
            NavEntry(id: "microphone", title: "Microphone", symbol: "mic"),
            NavEntry(id: "keyboard", title: "Keyboard Shortcuts", symbol: "keyboard"),
        ]),
        ("Text", [
            NavEntry(id: "shortcuts", title: "Replacements", symbol: "arrow.left.arrow.right"),
            NavEntry(id: "vocabulary", title: "Vocabulary", symbol: "character.book.closed"),
            NavEntry(id: "cleanup", title: "Cleanup", symbol: "sparkles"),
            NavEntry(id: "postProcessing", title: "Post Processing", symbol: "wand.and.stars"),
        ]),
        ("Library", [
            NavEntry(id: "meetings", title: "Meetings", symbol: "person.2.wave.2"),
            NavEntry(id: "history", title: "History", symbol: "clock"),
        ]),
        ("App", [
            NavEntry(id: "permissions", title: "Permissions", symbol: "lock.shield"),
            NavEntry(id: "about", title: "About", symbol: "info.circle"),
        ]),
    ]
    
    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        buildPanes()

        // --- Sidebar surface -------------------------------------------------
        let sidebar = SidebarMaterialView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(sidebar)

        let separator = Theme.makeHairline(vertical: true)
        contentView.addSubview(separator)

        // --- Detail surface --------------------------------------------------
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(detailContainer)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: contentView.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 196),

            separator.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            separator.topAnchor.constraint(equalTo: contentView.topAnchor),
            separator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            detailContainer.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            detailContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            detailContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            // The panes are constraint-driven, which makes AppKit size the window
            // from the content's fitting size — without a floor it collapses to
            // the sidebar's intrinsic 334×66. These keep the window usable.
            detailContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 560),
        ])

        buildSidebar(in: sidebar)
        selectPane("settings", animated: false)
    }

    private func buildPanes() {
        let paneFrame = NSRect(x: 0, y: 0, width: 640, height: 560)

        settingsTab = SettingsTabView(frame: paneFrame)
        keyboardTab = KeyboardShortcutsTabView(frame: paneFrame)
        keyboardTab.onHotkeyChanged = { [weak self] in self?.onHotkeyChanged?() }

        historyTab = HistoryTabView(frame: paneFrame)
        historyTab.onRetry = { [weak self] item, completion in
            if let handler = self?.onRetryTranscription {
                handler(item, completion)
            } else {
                completion(false)
            }
        }

        permissionsTab = PermissionsTabView(frame: paneFrame)

        modelsTab = ModelsTabView(frame: paneFrame)
        modelsTab.onModelSelected = { [weak self] in
            self?.onModelChanged?()
        }
        modelsTab.isTranscriptionInProgress = { [weak self] in
            self?.isTranscriptionInProgress?() ?? false
        }

        microphoneTab = MicrophoneTabView(frame: paneFrame)
        shortcutsTab = ShortcutReplacementTabView(frame: paneFrame)
        vocabularyTab = VocabularyPaneView(frame: paneFrame)
        cleanupTab = DeterministicCleanupTabView(frame: paneFrame)

        postProcessingTab = CleanupTabView(frame: paneFrame)
        postProcessingTab.onSettingsChanged = { [weak self] in
            self?.onCleanupSettingsChanged?()
        }

        aboutTab = AboutTabView(frame: paneFrame)

        meetingsTab = MeetingsPaneView(frame: paneFrame)
        meetingsTab.onToggleRecording = { [weak self] in self?.onToggleMeetingRecording?() }

        panes = [
            "meetings": meetingsTab,
            "settings": settingsTab,
            "keyboard": keyboardTab,
            "models": modelsTab,
            "microphone": microphoneTab,
            "shortcuts": shortcutsTab,
            "vocabulary": vocabularyTab,
            "cleanup": cleanupTab,
            "postProcessing": postProcessingTab,
            "history": historyTab,
            "permissions": permissionsTab,
            "about": aboutTab,
        ]
    }

    private func buildSidebar(in sidebar: NSView) {
        let identity = SidebarIdentityView(
            title: "Hearsay",
            image: NSImage(named: NSImage.applicationIconName)
        )
        sidebar.addSubview(identity)

        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 2
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarStack)

        for (index, section) in Self.navSections.enumerated() {
            if let title = section.title {
                let header = SidebarSectionLabel(title: title)
                sidebarStack.addArrangedSubview(header)
                header.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
            } else if index > 0 {
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                spacer.heightAnchor.constraint(equalToConstant: 8).isActive = true
                sidebarStack.addArrangedSubview(spacer)
            }

            for entry in section.entries {
                let item = SidebarItemView(
                    id: entry.id,
                    title: entry.title,
                    symbol: entry.symbol
                ) { [weak self] id in
                    self?.selectPane(id, animated: true)
                }
                sidebarItems.append(item)
                sidebarStack.addArrangedSubview(item)
                item.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
            }
        }

        sidebarFooter = SidebarFooterView(version: "v\(AppInfo.version)")
        sidebar.addSubview(sidebarFooter)

        NSLayoutConstraint.activate([
            // 46pt clears the traffic lights in a full-size-content window.
            identity.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 46),
            identity.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 6),
            identity.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -6),

            sidebarStack.topAnchor.constraint(equalTo: identity.bottomAnchor, constant: 16),
            sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 6),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -6),
            sidebarStack.bottomAnchor.constraint(lessThanOrEqualTo: sidebarFooter.topAnchor, constant: -8),

            sidebarFooter.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 6),
            sidebarFooter.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -6),
            sidebarFooter.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -12),
        ])
    }

    /// Swaps the detail pane, with a short crossfade.
    private func selectPane(_ id: String, animated: Bool) {
        guard let pane = panes[id], currentPaneID != id else { return }

        detailContainer.subviews.forEach { $0.removeFromSuperview() }

        pane.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            // Leave room for the (transparent) titlebar so content isn't clipped.
            pane.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 28),
            pane.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])

        if animated {
            pane.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.Motion.smooth
                context.allowsImplicitAnimation = true
                pane.animator().alphaValue = 1
            }
        }

        currentPaneID = id
        for item in sidebarItems {
            item.isActive = (item.identifier_ == id)
        }
        adjustWindowSize(forPane: id)

        // The Keyboard Shortcuts pane owns the shortcut recorders, so it needs key capture.
        if id == "keyboard" {
            onWindowOpened?()
        } else {
            onWindowClosed?()
        }
    }

    /// The Meetings pane needs room for its calendar column next to the transcript.
    private func adjustWindowSize(forPane id: String) {
        guard let window else { return }
        let meetingsMinimum = NSSize(width: 1000, height: 640)
        if id == "meetings" {
            window.minSize = meetingsMinimum
            var frame = window.frame
            let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
            let targetWidth = min(max(frame.width, 1120), visible.width)
            let targetHeight = min(max(frame.height, 760), visible.height)
            if targetWidth != frame.width || targetHeight != frame.height {
                frame.origin.x -= (targetWidth - frame.width) / 2
                frame.origin.y -= targetHeight - frame.height
                frame.size = NSSize(width: targetWidth, height: targetHeight)
                frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
                frame.origin.y = max(visible.minY, frame.origin.y)
                window.setFrame(frame, display: true, animate: window.isVisible)
            }
        } else {
            window.minSize = NSSize(width: 780, height: 560)
        }
    }

    /// Open the Meetings pane on a specific meeting (optionally highlighting a search).
    func showMeeting(_ id: UUID, query: String? = nil, mode: MeetingDetailView.Mode? = nil) {
        show(tab: .meetings)
        meetingsTab.reveal(meetingID: id, query: query)
        if let mode { meetingsTab.detailView.setMode(mode) }
    }

    /// Reflected in the sidebar footer (model name + enabled dot).
    func updateFooter(text: String, enabled: Bool) {
        sidebarFooter?.update(text: text, enabled: enabled)
    }
    
    func show(tab: Tab = .settings) {
        historyTab.refresh()
        permissionsTab.refresh()
        modelsTab.refresh()
        microphoneTab.refresh()
        cleanupTab.refresh()
        shortcutsTab.refresh()
        vocabularyTab.refresh()
        postProcessingTab.refresh()
        aboutTab.refresh()
        meetingsTab.refresh()
        
        let paneID: String
        switch tab {
        case .settings: paneID = "settings"
        case .history: paneID = "history"
        case .permissions: paneID = "permissions"
        case .models: paneID = "models"
        case .microphone: paneID = "microphone"
        case .cleanup: paneID = "cleanup"
        case .shortcuts: paneID = "shortcuts"
        case .postProcessing: paneID = "postProcessing"
        case .about: paneID = "about"
        case .meetings: paneID = "meetings"
        case .vocabulary: paneID = "vocabulary"
        case .keyboard: paneID = "keyboard"
        }
        selectPane(paneID, animated: false)
        
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        // Only pause hotkeys on the Keyboard Shortcuts pane (shortcut recorders need key capture).
        if tab == .keyboard {
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
        // Only pause hotkeys on the Keyboard Shortcuts pane (shortcut recorders need key capture)
        if currentPaneID == "keyboard" {
            onWindowOpened?()
        } else {
            onWindowClosed?()
        }
    }
}

private enum AppInfo {
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Hearsay"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    static var versionSummary: String {
        "Version \(version)"
    }

    static var buildSummary: String {
        "Build number \(build)"
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "Unknown"
    }

    static var minimumSystemVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String ?? "Unknown"
    }

    static var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }
}

// MARK: - Settings Tab

private class SettingsTabView: NSView {
    
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Hearsay")
    private let subtitleLabel = NSTextField(labelWithString: "Local Speech-to-Text")
    private let versionLabel = NSTextField(labelWithString: AppInfo.versionSummary)
    private let buildLabel = NSTextField(labelWithString: AppInfo.buildSummary)
    
    private let generalBox = NSBox()
    private let copyToClipboardCheckbox = NSButton(checkboxWithTitle: "Copy to Clipboard", target: nil, action: nil)
    private let autoPasteCheckbox = NSButton(checkboxWithTitle: "Auto-Paste at Cursor", target: nil, action: nil)
    private let captureClipboardCheckbox = NSButton(checkboxWithTitle: "Capture Clipboard During Dictation", target: nil, action: nil)
    private let dockIconCheckbox = NSButton(checkboxWithTitle: "Show Dock Icon", target: nil, action: nil)
    private let soundEffectsCheckbox = NSButton(checkboxWithTitle: "Sound Effects", target: nil, action: nil)
    private let maxHistoryLabel = NSTextField(labelWithString: "Max History Size")
    private let maxHistorySlider = NSSlider()
    private let maxHistoryValueLabel = NSTextField(labelWithString: "")

    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        loadSettings()
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    private func setupUI() {
        // Pane title. Identity (icon, name, version) now lives in the window's
        // sidebar, so this pane just needs a left-aligned heading.
        titleLabel.stringValue = "Settings"
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.alignment = .left
        addSubview(titleLabel)

        subtitleLabel.stringValue = "Recording and clipboard behaviour. Shortcuts live in Keyboard Shortcuts."
        
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .left
        addSubview(subtitleLabel)

        // versionLabel / buildLabel are intentionally not added — the sidebar
        // footer and the About pane carry version info now.
        
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

        captureClipboardCheckbox.target = self
        captureClipboardCheckbox.action = #selector(captureClipboardChanged(_:))
        captureClipboardCheckbox.toolTip = "When on, text you copy (⌘C) while recording is inserted into the transcript at that point. Off by default so copied secrets aren't captured or sent to the cleanup model."
        generalBox.contentView?.addSubview(captureClipboardCheckbox)

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
        captureClipboardCheckbox.state = ClipboardManager.isFeatureEnabled ? .on : .off
        dockIconCheckbox.state = UserDefaults.standard.bool(forKey: "showDockIcon") ? .on : .off
        soundEffectsCheckbox.state = SoundPlayer.shared.isEnabled ? .on : .off
        
        let maxItems = HistoryStore.shared.maxItems
        maxHistorySlider.doubleValue = Self.itemsToSlider(maxItems)
        updateMaxHistoryLabel(maxItems)
    }
    
    override func layout() {
        super.layout()
        
        let pad: CGFloat = 20
        let boxW = bounds.width - pad * 2
        var y = bounds.height - 16
        
        // Pane heading + subhead, left-aligned (Managerie-style detail pane).
        titleLabel.frame = NSRect(x: pad, y: y - 26, width: boxW, height: 26)
        y -= 28

        subtitleLabel.frame = NSRect(x: pad, y: y - 16, width: boxW, height: 16)
        y -= 30
        
        // General box
        let generalH: CGFloat = 178
        generalBox.frame = NSRect(x: pad, y: y - generalH, width: boxW, height: generalH)
        if let cv = generalBox.contentView {
            let inset: CGFloat = 12
            let sliderRight = cv.bounds.width - inset

            copyToClipboardCheckbox.frame = NSRect(x: inset, y: cv.bounds.height - 28, width: 200, height: 20)
            autoPasteCheckbox.frame = NSRect(x: inset, y: cv.bounds.height - 50, width: 200, height: 20)
            captureClipboardCheckbox.frame = NSRect(x: inset, y: cv.bounds.height - 72, width: 300, height: 20)
            soundEffectsCheckbox.frame = NSRect(x: inset, y: cv.bounds.height - 94, width: 200, height: 20)
            dockIconCheckbox.frame = NSRect(x: inset, y: cv.bounds.height - 116, width: 200, height: 20)

            let historyRowY = cv.bounds.height - 138
            maxHistoryLabel.frame = NSRect(x: inset, y: historyRowY, width: 120, height: 18)
            maxHistoryValueLabel.sizeToFit()
            let valueLabelW = max(130, maxHistoryValueLabel.frame.width)
            maxHistoryValueLabel.frame = NSRect(x: sliderRight - valueLabelW, y: historyRowY, width: valueLabelW, height: 18)
            maxHistorySlider.frame = NSRect(x: inset, y: historyRowY - 22, width: sliderRight - inset, height: 21)
        }
    }
    
    @objc private func copyToClipboardChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "copyToClipboard")
    }

    @objc private func autoPasteChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "autoPasteAtCursor")
    }

    @objc private func captureClipboardChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: ClipboardManager.enabledDefaultsKey)
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
    
}

// MARK: - Keyboard Shortcuts Tab

/// Every keyboard shortcut in one place: the global ones (editable) and the
/// fixed ones inside Hearsay's menu and windows (for reference).
private class KeyboardShortcutsTabView: NSView {

    var onHotkeyChanged: (() -> Void)?

    private let scrollView = NSScrollView()
    private let content = FlippedView()
    private let titleLabel = NSTextField(labelWithString: "Keyboard Shortcuts")
    private let subtitleLabel = NSTextField(labelWithString: "Global shortcuts work from any app. Click one to change it.")

    private let dictationBox = NSBox()
    private let activationLabel = NSTextField(labelWithString: "Activation")
    private let activationPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let activationSeparator = NSBox()
    private var holdRow: ShortcutRowView!
    private var toggleRow: ShortcutRowView!

    private let screenshotBox = NSBox()
    private var screenshotRow: ShortcutRowView!
    private var fullScreenshotRow: ShortcutRowView!

    private let meetingBox = NSBox()
    private var meetingRow: ShortcutRowView!

    private let resetButton = NSButton(title: "Reset to Defaults", target: nil, action: nil)

    private let referenceBox = NSBox()
    private var referenceRows: [(label: NSTextField, keys: NSTextField)] = []

    /// Fixed shortcuts, shown for reference.
    private static let reference: [(String, String)] = [
        ("Open Window (menu open)", "⌘O"),
        ("Copy a recent transcription (menu open)", "⌘1 – ⌘4"),
        ("View All History (menu open)", "⌘H"),
        ("Settings (menu open)", "⌘,"),
        ("Search this meeting", "⌘F"),
        ("Search all meetings", "⇧⌘F"),
        ("Choose the highlighted button in a prompt", "Return"),
    ]

    private static let rowHeight: CGFloat = 40

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        loadSettings()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = content
        addSubview(scrollView)

        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        content.addSubview(titleLabel)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        content.addSubview(subtitleLabel)

        for (box, title) in [(dictationBox, "Dictation"), (screenshotBox, "Screenshots While Dictating"),
                             (meetingBox, "Meetings"), (referenceBox, "Inside Hearsay")] {
            box.title = title
            box.titleFont = .systemFont(ofSize: 12, weight: .semibold)
            content.addSubview(box)
        }

        activationLabel.font = .systemFont(ofSize: 13)
        dictationBox.contentView?.addSubview(activationLabel)
        activationPicker.addItems(withTitles: ["Hold", "Double-Tap"])
        activationPicker.font = .systemFont(ofSize: 12)
        activationPicker.target = self
        activationPicker.action = #selector(activationChanged(_:))
        dictationBox.contentView?.addSubview(activationPicker)
        activationSeparator.boxType = .separator
        dictationBox.contentView?.addSubview(activationSeparator)

        holdRow = ShortcutRowView(label: "Hold to Record", captureMode: .singleModifier, placeholder: "Click to set",
                                  canClear: false, showSeparator: true) { [weak self] s in
            UserDefaults.standard.set(s.keyCode, forKey: "holdKeyCode")
            self?.onHotkeyChanged?()
        }
        toggleRow = comboRow("Toggle Record", keyCodeKey: "toggleStartKeyCode", modifiersKey: "toggleStartModifiers", separator: false)
        dictationBox.contentView?.addSubview(holdRow)
        dictationBox.contentView?.addSubview(toggleRow)

        screenshotRow = comboRow("Take Screenshot", keyCodeKey: "screenshotKeyCode", modifiersKey: "screenshotModifiers", separator: true)
        fullScreenshotRow = comboRow("Full-Screen Screenshot", keyCodeKey: "fullScreenshotKeyCode", modifiersKey: "fullScreenshotModifiers", separator: false)
        screenshotBox.contentView?.addSubview(screenshotRow)
        screenshotBox.contentView?.addSubview(fullScreenshotRow)

        meetingRow = comboRow("Record / Stop Meeting", keyCodeKey: HotkeyMonitor.meetingKeyCodeKey,
                              modifiersKey: HotkeyMonitor.meetingModifiersKey, separator: false)
        meetingBox.contentView?.addSubview(meetingRow)

        // Each combo shortcut must differ from the others.
        let combos: [(String, ShortcutRowView)] = [
            ("Toggle Record", toggleRow), ("Take Screenshot", screenshotRow),
            ("Full-Screen Screenshot", fullScreenshotRow), ("Record / Stop Meeting", meetingRow),
        ]
        for (_, row) in combos {
            row.recorder.onConflict = { candidate in
                for (name, other) in combos where other !== row {
                    if candidate.conflicts(with: other.recorder.currentShortcut) {
                        return "This shortcut is already used by \"\(name)\"."
                    }
                }
                return nil
            }
        }

        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.target = self
        resetButton.action = #selector(resetToDefaults(_:))
        content.addSubview(resetButton)

        for (title, keys) in Self.reference {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            let keyLabel = NSTextField(labelWithString: keys)
            keyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            keyLabel.textColor = .secondaryLabelColor
            keyLabel.alignment = .right
            referenceBox.contentView?.addSubview(label)
            referenceBox.contentView?.addSubview(keyLabel)
            referenceRows.append((label, keyLabel))
        }
    }

    private func comboRow(_ label: String, keyCodeKey: String, modifiersKey: String, separator: Bool) -> ShortcutRowView {
        ShortcutRowView(label: label, captureMode: .keyCombo, placeholder: "Not set",
                        canClear: true, showSeparator: separator) { [weak self] s in
            UserDefaults.standard.set(s.keyCode, forKey: keyCodeKey)
            UserDefaults.standard.set(Int(s.modifiers), forKey: modifiersKey)
            self?.onHotkeyChanged?()
        }
    }

    private func loadSettings() {
        let defaults = UserDefaults.standard
        let option = Int(NSEvent.ModifierFlags.option.rawValue)
        func combo(_ keyCodeKey: String, _ modifiersKey: String, _ keyCode: Int, _ modifiers: Int) -> Shortcut {
            Shortcut(keyCode: defaults.object(forKey: keyCodeKey) as? Int ?? keyCode,
                     modifiers: UInt(defaults.object(forKey: modifiersKey) as? Int ?? modifiers))
        }
        activationPicker.selectItem(at: defaults.integer(forKey: "activationMode"))
        updateHoldRowLabel()
        holdRow.recorder.setShortcut(Shortcut(keyCode: defaults.object(forKey: "holdKeyCode") as? Int ?? 61, modifiers: 0))
        toggleRow.recorder.setShortcut(combo("toggleStartKeyCode", "toggleStartModifiers", 49, option))
        screenshotRow.recorder.setShortcut(combo("screenshotKeyCode", "screenshotModifiers", 21, option))
        fullScreenshotRow.recorder.setShortcut(combo("fullScreenshotKeyCode", "fullScreenshotModifiers", 20, option))
        meetingRow.recorder.setShortcut(combo(HotkeyMonitor.meetingKeyCodeKey, HotkeyMonitor.meetingModifiersKey, 0, 0))
    }

    private func updateHoldRowLabel() {
        holdRow.setLabel(activationPicker.indexOfSelectedItem == 1 ? "Record Key" : "Hold to Record")
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let pad: CGFloat = 20
        let width = max(bounds.width - pad * 2, 300)
        let rowH = Self.rowHeight
        var y: CGFloat = 16

        titleLabel.frame = NSRect(x: pad, y: y, width: width, height: 26)
        y += 28
        subtitleLabel.frame = NSRect(x: pad, y: y, width: width, height: 16)
        y += 30

        func place(_ box: NSBox, rows: Int) -> CGFloat {
            // NSBox adds its title above the content; ~24pt covers it.
            let height = rowH * CGFloat(rows) + 30
            box.frame = NSRect(x: pad, y: y, width: width, height: height)
            y += height + 12
            return box.contentView?.bounds.height ?? 0
        }

        func layoutRows(_ rows: [NSView], in box: NSBox, top: CGFloat) {
            guard let contentView = box.contentView else { return }
            let inset: CGFloat = 12
            var rowTop = contentView.bounds.height - 4 - top
            for row in rows {
                rowTop -= rowH
                row.frame = NSRect(x: inset, y: rowTop, width: contentView.bounds.width - inset * 2, height: rowH)
            }
        }

        _ = place(dictationBox, rows: 3)
        if let contentView = dictationBox.contentView {
            let inset: CGFloat = 12
            let rowW = contentView.bounds.width - inset * 2
            let top = contentView.bounds.height - 4 - rowH
            let pickerW: CGFloat = 130
            activationLabel.frame = NSRect(x: inset, y: top + (rowH - 18) / 2, width: rowW - pickerW - 8, height: 18)
            activationPicker.frame = NSRect(x: contentView.bounds.width - inset - pickerW, y: top + (rowH - 26) / 2, width: pickerW, height: 26)
            activationSeparator.frame = NSRect(x: inset, y: top, width: rowW, height: 1)
            layoutRows([holdRow, toggleRow], in: dictationBox, top: rowH)
        }
        _ = place(screenshotBox, rows: 2)
        layoutRows([screenshotRow, fullScreenshotRow], in: screenshotBox, top: 0)
        _ = place(meetingBox, rows: 1)
        layoutRows([meetingRow], in: meetingBox, top: 0)

        resetButton.sizeToFit()
        resetButton.frame.origin = NSPoint(x: pad + width - resetButton.frame.width, y: y - 4)
        y += resetButton.frame.height + 12

        let lineH: CGFloat = 26
        let referenceH = lineH * CGFloat(referenceRows.count) + 34
        referenceBox.frame = NSRect(x: pad, y: y, width: width, height: referenceH)
        if let contentView = referenceBox.contentView {
            let inset: CGFloat = 12
            let keysW: CGFloat = 110
            var lineTop = contentView.bounds.height - 6
            for (label, keys) in referenceRows {
                lineTop -= lineH
                label.frame = NSRect(x: inset, y: lineTop + 4, width: contentView.bounds.width - inset * 2 - keysW, height: 18)
                keys.frame = NSRect(x: contentView.bounds.width - inset - keysW, y: lineTop + 4, width: keysW, height: 18)
            }
        }
        y += referenceH + 20

        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(y, bounds.height))
    }

    @objc private func activationChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem, forKey: "activationMode")
        updateHoldRowLabel()
        onHotkeyChanged?()
    }

    @objc private func resetToDefaults(_ sender: NSButton) {
        let defaults = UserDefaults.standard
        let option = Int(NSEvent.ModifierFlags.option.rawValue)
        defaults.set(0, forKey: "activationMode")
        defaults.set(61, forKey: "holdKeyCode")
        defaults.set(49, forKey: "toggleStartKeyCode")
        defaults.set(option, forKey: "toggleStartModifiers")
        defaults.set(21, forKey: "screenshotKeyCode")
        defaults.set(option, forKey: "screenshotModifiers")
        defaults.set(20, forKey: "fullScreenshotKeyCode")
        defaults.set(option, forKey: "fullScreenshotModifiers")
        defaults.removeObject(forKey: HotkeyMonitor.meetingKeyCodeKey)
        defaults.removeObject(forKey: HotkeyMonitor.meetingModifiersKey)
        loadSettings()
        onHotkeyChanged?()
    }
}

// MARK: - About Tab

private class AboutTabView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: AppInfo.displayName)
    private let subtitleLabel = NSTextField(labelWithString: "Local Speech-to-Text")
    private let versionLabel = NSTextField(labelWithString: AppInfo.versionSummary)
    private let buildLabel = NSTextField(labelWithString: AppInfo.buildSummary)
    private let infoCard = CardSectionView(title: "App Information", spacing: 2)
    private let copyButton = NSButton(title: "Copy Details", target: nil, action: nil)
    private let supportFolderButton = NSButton(title: "Open Support Folder", target: nil, action: nil)
    private let buttonRow = NSStackView()
    private var rows: [AboutInfoRowView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        // Identity row: icon beside the name, left-aligned (the old centred
        // "app splash" header duplicated the sidebar identity).
        if let icon = NSImage(named: NSImage.applicationIconName) {
            iconView.image = icon
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.alignment = .left
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .left
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitleLabel)

        versionLabel.font = Theme.Font.metaDigits
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.alignment = .left
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(versionLabel)

        // Build number is already one of the App Information rows.
        buildLabel.isHidden = true

        rows = Self.infoItems().map { item in
            let row = AboutInfoRowView(title: item.title, value: item.value)
            infoCard.addRow(row)
            row.heightAnchor.constraint(equalToConstant: 26).isActive = true
            return row
        }
        addSubview(infoCard)

        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyDetails(_:))

        supportFolderButton.bezelStyle = .rounded
        supportFolderButton.target = self
        supportFolderButton.action = #selector(openSupportFolder(_:))

        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addArrangedSubview(supportFolderButton)
        buttonRow.addArrangedSubview(copyButton)
        addSubview(buttonRow)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            iconView.widthAnchor.constraint(equalToConstant: 52),
            iconView.heightAnchor.constraint(equalToConstant: 52),

            titleLabel.topAnchor.constraint(equalTo: iconView.topAnchor, constant: 2),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            versionLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 3),
            versionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            infoCard.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: Theme.Space.sectionGap),
            infoCard.leadingAnchor.constraint(equalTo: iconView.leadingAnchor),
            infoCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),

            buttonRow.topAnchor.constraint(equalTo: infoCard.bottomAnchor, constant: 14),
            buttonRow.leadingAnchor.constraint(equalTo: infoCard.leadingAnchor),
        ])
    }

    func refresh() {
        titleLabel.stringValue = AppInfo.displayName
        versionLabel.stringValue = AppInfo.versionSummary
        buildLabel.stringValue = AppInfo.buildSummary

        for (row, item) in zip(rows, Self.infoItems()) {
            row.setTitle(item.title, value: item.value)
        }
    }

    private static func infoItems() -> [(title: String, value: String)] {
        var items = [
            ("Version", AppInfo.version),
            ("Build Number", AppInfo.build),
            ("Bundle ID", AppInfo.bundleIdentifier),
            ("Minimum macOS", AppInfo.minimumSystemVersion),
            ("App Support", Constants.appSupportDirectory.path),
            ("Models", Constants.modelsDirectory.path),
            ("Diagnostic Log", Constants.diagnosticLogURL.path)
        ]

        if !AppInfo.copyright.isEmpty {
            items.append(("Copyright", AppInfo.copyright))
        }

        return items
    }

    private static func detailsText() -> String {
        infoItems()
            .map { "\($0.title): \($0.value)" }
            .joined(separator: "\n")
    }

    @objc private func copyDetails(_ sender: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.detailsText(), forType: .string)
    }

    @objc private func openSupportFolder(_ sender: NSButton) {
        try? FileManager.default.createDirectory(at: Constants.appSupportDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Constants.appSupportDirectory)
    }
}

private class AboutInfoRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")

    init(title: String, value: String) {
        super.init(frame: .zero)
        setupUI()
        setTitle(title, value: value)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        addSubview(titleLabel)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.isSelectable = true
        addSubview(valueLabel)
    }

    func setTitle(_ title: String, value: String) {
        titleLabel.stringValue = title
        valueLabel.stringValue = value
        valueLabel.toolTip = value
    }

    override func layout() {
        super.layout()

        let titleWidth: CGFloat = 130
        titleLabel.frame = NSRect(x: 0, y: 4, width: titleWidth, height: 18)
        valueLabel.frame = NSRect(x: titleWidth + 12, y: 3, width: max(0, bounds.width - titleWidth - 12), height: 20)
    }
}

// MARK: - Models Tab

private class ModelsTabView: NSView {

    var onModelSelected: (() -> Void)?
    /// Returns true if a transcription is currently running (delete is blocked while it is).
    var isTranscriptionInProgress: (() -> Bool)?

    private let titleLabel = NSTextField(labelWithString: "Manage Models")
    private let subtitleLabel = NSTextField(labelWithString: "Choose a speech model backend and set it as active.")
    private let modelSelector = NSStackView()
    private var modelCards: [ModelDownloader.Model: SettingsModelCardView] = [:]
    private let actionButton = NSButton()
    private let progressContainer = NSView()
    private let progressBar = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    private var selectedModel: ModelDownloader.Model = .small
    private var isDeleting = false
    private var cancellables = Set<AnyCancellable>()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        setupBindings()
        refresh(initial: true)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        Theme.styleHeading(titleLabel, subtitleLabel)
        addSubview(titleLabel)
        addSubview(subtitleLabel)

        modelSelector.orientation = .vertical
        modelSelector.spacing = 12

        let models = ModelDownloader.Model.availableModels
        for chunkStart in stride(from: 0, to: models.count, by: 2) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 12
            row.distribution = .fillEqually

            for model in models[chunkStart..<min(chunkStart + 2, models.count)] {
                let card = SettingsModelCardView(model: model, isSelected: false) { [weak self] in
                    self?.selectModel(model)
                }
                card.onDelete = { [weak self] in
                    self?.requestDelete(model)
                }
                row.addArrangedSubview(card)
                modelCards[model] = card
            }

            if chunkStart + 1 >= models.count {
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                row.addArrangedSubview(spacer)
            }

            modelSelector.addArrangedSubview(row)
        }

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
        for (cardModel, card) in modelCards {
            card.setSelected(cardModel == model)
        }
        refresh()
    }

    func refresh(initial: Bool = false) {
        if initial {
            if let preferred = ModelDownloader.shared.selectedModelPreference() {
                selectedModel = preferred
            } else {
                selectedModel = .small
            }
        }

        let downloader = ModelDownloader.shared
        let active = downloader.selectedModelPreference()

        let controlsDisabled = downloader.isDownloading || isDeleting
        for model in ModelDownloader.Model.availableModels {
            let card = modelCards[model]
            card?.setSelected(model == selectedModel)
            card?.setInstalled(downloader.isModelInstalled(model))
            card?.setActive(active == model)
            card?.isEnabled = !controlsDisabled
        }

        let selectedInstalled = downloader.isModelInstalled(selectedModel)
        detailLabel.textColor = .secondaryLabelColor

        if downloader.isDownloading {
            actionButton.isHidden = true
            progressContainer.isHidden = false
        } else if isDeleting {
            actionButton.isHidden = true
            progressContainer.isHidden = true
        } else {
            actionButton.isHidden = false
            progressContainer.isHidden = true
            actionButton.title = selectedInstalled ? "Use Selected Model" : "Download Selected Model"

            let installedNames = downloader.installedModels().map { $0.displayName }.joined(separator: ", ")
            if installedNames.isEmpty {
                detailLabel.stringValue = "No models installed yet."
            } else if let active {
                detailLabel.stringValue = "Installed: \(installedNames). Active: \(active.displayName)."
            } else {
                detailLabel.stringValue = "Installed: \(installedNames)."
            }
        }
    }

    private func requestDelete(_ model: ModelDownloader.Model) {
        let downloader = ModelDownloader.shared
        guard !downloader.isDownloading, !isDeleting else { return }
        guard downloader.isModelInstalled(model) else { return }

        // Defensive: don't pull files out from under an in-flight transcription.
        if isTranscriptionInProgress?() == true {
            let alert = NSAlert()
            alert.messageText = "Transcription in Progress"
            alert.informativeText = "Hearsay is currently transcribing. Wait for it to finish, then try deleting the model again."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let isActive = downloader.selectedModelPreference() == model
        let isLastModel = downloader.installedModels().count <= 1

        let alert = NSAlert()
        alert.alertStyle = .warning
        if isLastModel {
            // Deleting the last installed model leaves nothing for transcription,
            // regardless of whether it is the persisted "active" one.
            alert.messageText = "Delete the only installed model?"
            alert.informativeText = "“\(model.displayName)” (\(model.estimatedSizeString)) is the only installed model. Deleting it leaves no model available for transcription until you download another. Are you sure?"
        } else if isActive {
            alert.messageText = "Delete the active model?"
            alert.informativeText = "“\(model.displayName)” (\(model.estimatedSizeString)) is currently active. Hearsay will switch to another installed model after deletion."
        } else {
            alert.messageText = "Delete this model?"
            alert.informativeText = "This removes “\(model.displayName)” (\(model.estimatedSizeString)) from disk. You can re-download it anytime."
        }
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isDeleting = true
        detailLabel.stringValue = "Deleting \(model.displayName)…"
        refresh()

        let wasActive = downloader.selectedModelPreference() == model

        Task { [weak self] in
            // Perform the (potentially large) file removal off the main thread.
            let deleteError: Error?
            do {
                try await downloader.delete(model)
                deleteError = nil
            } catch {
                deleteError = error
            }

            await MainActor.run {
                guard let self else { return }
                self.isDeleting = false

                if let deleteError {
                    self.refresh()
                    self.detailLabel.textColor = .systemRed
                    self.detailLabel.stringValue = "Couldn't delete \(model.displayName): \(deleteError.localizedDescription)"
                    return
                }

                if wasActive {
                    if let next = downloader.installedModels().first {
                        downloader.setSelectedModelPreference(next)
                    } else {
                        downloader.clearSelectedModelPreference()
                    }
                    // Active model changed → reconfigure transcriber + status bar.
                    self.onModelSelected?()
                }

                self.refresh()
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
                guard let self else { return }
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

        let rows = Int(ceil(Double(ModelDownloader.Model.availableModels.count) / 2.0))
        let selectorWidth: CGFloat = min(900, bounds.width - 40)
        let rowSpacing = modelSelector.spacing
        let selectorHeight: CGFloat = CGFloat(rows) * SettingsModelCardView.cardHeight + CGFloat(max(0, rows - 1)) * rowSpacing
        modelSelector.frame = NSRect(x: centerX - selectorWidth / 2, y: y - selectorHeight, width: selectorWidth, height: selectorHeight)
        y -= selectorHeight + 24

        actionButton.sizeToFit()
        let buttonWidth = max(220, actionButton.frame.width + 36)
        actionButton.frame = NSRect(x: centerX - buttonWidth / 2, y: y - 34, width: buttonWidth, height: 34)

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
    /// Invoked when the user taps the trash button (only present when installed).
    var onDelete: (() -> Void)?
    private var selected: Bool
    private var installed: Bool = false
    private var active: Bool = false

    private let containerBox = NSBox()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(labelWithString: "")
    /// Single status chip (top-right): "Active" or "Downloaded" — never both. Hidden when not installed.
    private let statusPill = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let deleteButton = NSButton()

    var isEnabled: Bool = true {
        didSet {
            alphaValue = isEnabled ? 1.0 : 0.5
            deleteButton.isEnabled = isEnabled
        }
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
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        containerBox.addSubview(nameLabel)

        sizeLabel.stringValue = model.estimatedSizeString
        sizeLabel.font = .systemFont(ofSize: 11)
        sizeLabel.textColor = .secondaryLabelColor
        containerBox.addSubview(sizeLabel)

        descLabel.stringValue = model.description
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = .tertiaryLabelColor
        descLabel.lineBreakMode = .byWordWrapping
        descLabel.maximumNumberOfLines = 2
        descLabel.cell?.truncatesLastVisibleLine = true
        containerBox.addSubview(descLabel)

        // Status chip (top-right): one rounded tinted pill, set in updateUI().
        statusPill.wantsLayer = true
        statusPill.layer?.cornerRadius = 9
        containerBox.addSubview(statusPill)

        statusLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        statusLabel.alignment = .center
        statusPill.addSubview(statusLabel)

        deleteButton.bezelStyle = .inline
        deleteButton.isBordered = false
        deleteButton.imagePosition = .imageOnly
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete model")
        deleteButton.contentTintColor = .systemRed
        deleteButton.toolTip = "Delete this downloaded model"
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        containerBox.addSubview(deleteButton)
    }

    @objc private func deleteTapped() {
        guard isEnabled else { return }
        onDelete?()
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
        // Selection is shown by the border alone (no separate checkmark).
        containerBox.borderColor = selected ? .systemBlue : .separatorColor
        containerBox.borderWidth = selected ? 2 : 1

        // One status chip: Active (green) takes precedence over Downloaded (blue); hidden when not installed.
        if active {
            statusLabel.stringValue = "Active"
            statusLabel.textColor = .systemGreen
            statusPill.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.16).cgColor
            statusPill.isHidden = false
        } else if installed {
            statusLabel.stringValue = "Downloaded"
            statusLabel.textColor = .systemBlue
            statusPill.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.16).cgColor
            statusPill.isHidden = false
        } else {
            statusPill.isHidden = true
        }

        deleteButton.isHidden = !installed
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Re-resolve the pill's tinted background for the new appearance.
        updateUI()
    }
    
    override func layout() {
        super.layout()

        containerBox.frame = bounds

        let padding: CGFloat = 16
        let contentWidth = bounds.width - padding * 2
        var y = bounds.height - padding - 18

        // Status pill: top-right, vertically aligned with the name row.
        var pillWidth: CGFloat = 0
        if !statusPill.isHidden {
            statusLabel.sizeToFit()
            let pillHeight: CGFloat = 18
            let hInset: CGFloat = 9
            pillWidth = ceil(statusLabel.frame.width) + hInset * 2
            statusPill.frame = NSRect(x: bounds.width - padding - pillWidth, y: y, width: pillWidth, height: pillHeight)
            statusLabel.frame = NSRect(
                x: hInset,
                y: (pillHeight - statusLabel.frame.height) / 2,
                width: statusPill.bounds.width - hInset * 2,
                height: statusLabel.frame.height
            )
        }

        // Name row: left, ending before the pill so they never collide.
        let nameRightInset = pillWidth > 0 ? pillWidth + 8 : 0
        nameLabel.frame = NSRect(x: padding, y: y, width: contentWidth - nameRightInset, height: 18)

        y -= 22
        sizeLabel.frame = NSRect(x: padding, y: y, width: contentWidth, height: 16)

        // Description: up to two wrapped lines, in the band between the size row and the trash.
        let descHeight: CGFloat = 32
        y -= descHeight + 4
        descLabel.frame = NSRect(x: padding, y: y, width: contentWidth, height: descHeight)

        // Trash button: alone in the bottom-right (only when installed).
        let trashSize: CGFloat = 18
        deleteButton.frame = NSRect(
            x: bounds.width - padding - trashSize,
            y: padding,
            width: trashSize,
            height: trashSize
        )
    }
    
    /// Shared so ModelsTabView's selector height math stays in sync with the card.
    static let cardHeight: CGFloat = 136

    override var intrinsicContentSize: NSSize {
        NSSize(width: 260, height: Self.cardHeight)
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
    
    private let micCard = CardSectionView(title: "Input Device")
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
        Theme.styleHeading(titleLabel, subtitleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        
        // Input-device card. The card header already says "Input Device", so the
        // popup needs no second label next to it.
        micPopup.controlSize = .regular
        micPopup.font = .systemFont(ofSize: 13)
        micPopup.target = self
        micPopup.action = #selector(micSelected(_:))
        micCard.addRow(micPopup)
        
        activeLabel.font = .systemFont(ofSize: 11)
        activeLabel.textColor = .secondaryLabelColor
        activeLabel.alignment = .left
        micCard.addRow(activeLabel)

        addSubview(micCard)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            micCard.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: Theme.Space.sectionGap),
            micCard.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            micCard.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
        ])
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
        Theme.styleHeading(titleLabel, subtitleLabel)
        addSubview(titleLabel)
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
        titleLabel.frame = NSRect(x: 20, y: y - 27, width: bounds.width - 40, height: 27)
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
    private let copyHintLabel = NSTextField(labelWithString: HistoryTabView.defaultHint)
    private let emptyLabel = NSTextField(labelWithString: "No transcriptions yet")
    
    private static let defaultHint = "Click a line to copy it."
    
    private var items: [TranscriptionItem] = []
    private var retryingIds = Set<UUID>()
    
    /// Re-run a failed transcription. Provided by the window controller.
    var onRetry: ((TranscriptionItem, @escaping (Bool) -> Void) -> Void)?
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        // Keep the list in sync while the window is open (new dictations, retries).
        HistoryStore.shared.addChangeObserver { [weak self] in
            self?.refresh()
        }
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    private func setupUI() {
        // Table
        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = nil
        tableView.rowHeight = 52
        tableView.action = #selector(rowClicked(_:))
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

        copyHintLabel.font = .systemFont(ofSize: 11)
        copyHintLabel.textColor = .secondaryLabelColor
        copyHintLabel.alignment = .right
        addSubview(copyHintLabel)
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
        
        clearButton.frame.origin = NSPoint(x: pad, y: pad)
        copyHintLabel.frame = NSRect(
            x: clearButton.frame.maxX + 16,
            y: pad + 6,
            width: bounds.width - clearButton.frame.maxX - pad - 16,
            height: 16
        )
        
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
        
        let text: NSTextField
        if item.isFailed {
            let isRetrying = retryingIds.contains(item.id)
            text = NSTextField(labelWithString: isRetrying ? "⏳ Retrying…" : "⚠️ Transcription failed — click to retry")
            text.textColor = .systemOrange
            text.toolTip = "Transcription failed. The audio was saved — click this row to run it again."
        } else {
            text = NSTextField(labelWithString: compactDisplayText(item.text))
            text.toolTip = item.text
        }
        text.font = .systemFont(ofSize: 12)
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.cell?.lineBreakMode = .byTruncatingTail
        text.cell?.usesSingleLineMode = true
        text.cell?.wraps = false
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
    
    @objc private func rowClicked(_ sender: Any) {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        if item.isFailed {
            retryItem(item)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.text, forType: .string)
            showCopiedFeedback(forRow: row)
        }
    }
    
    /// Re-run a failed item's transcription; the row shows a retrying state meanwhile.
    private func retryItem(_ item: TranscriptionItem) {
        guard let onRetry = onRetry, !retryingIds.contains(item.id) else { return }
        retryingIds.insert(item.id)
        tableView.reloadData()
        onRetry(item) { [weak self] success in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.retryingIds.remove(item.id)
                self.copyHintLabel.stringValue = success ? Self.defaultHint : "Retry failed — click the row to try again."
                self.refresh()  // on success the store observer also fires; harmless
            }
        }
    }
    
    /// Small "Copied ✓" pill that appears over the clicked row, floats up, and fades out.
    private func showCopiedFeedback(forRow row: Int) {
        let label = NSTextField(labelWithString: "Copied ✓")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.sizeToFit()
        
        let pill = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.width + 20, height: label.frame.height + 8))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        pill.layer?.cornerRadius = pill.frame.height / 2
        label.frame.origin = NSPoint(x: 10, y: 4)
        pill.addSubview(label)
        
        // Position over the right edge of the clicked row (accounts for scroll offset).
        let rowRect = convert(tableView.rect(ofRow: row), from: tableView)
        pill.frame.origin = NSPoint(
            x: scrollView.frame.maxX - pill.frame.width - 24,
            y: rowRect.midY - pill.frame.height / 2
        )
        pill.alphaValue = 0
        addSubview(pill)
        
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            pill.animator().alphaValue = 1
        }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.6
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    pill.animator().alphaValue = 0
                    pill.animator().frame.origin.y += 14
                }) {
                    pill.removeFromSuperview()
                }
            }
        }
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
    
    /// The key alone ("M", "Space"), without modifiers.
    var keyLabel: String { ShortcutRecorderView.keyName(for: keyCode) }

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

// MARK: - Deterministic Cleanup Tab

private class DeterministicCleanupTabView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Cleanup")
    private let subtitleLabel = NSTextField(labelWithString: "Remove deterministic transcription errors before text is inserted or copied.")
    private let enabledCheckbox = NSButton(checkboxWithTitle: "Enable cleanup rules", target: nil, action: nil)
    private let rulesCard = CardSectionView(title: "Rules", spacing: 8)
    private let headerRow = NSView()
    private let onHeader = NSTextField(labelWithString: "On")
    private let patternHeader = NSTextField(labelWithString: "Pattern")
    private let scrollView = NSScrollView()
    private let rowsContainer = RowListView()
    private let buttonRow = NSStackView()
    private let addButton = NSButton(title: "Add Rule", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset Defaults", target: nil, action: nil)
    private let exampleCard = CardSectionView(title: "Example")
    private let exampleLabel = NSTextField(wrappingLabelWithString: "")

    private var rules: [CleanupRule] = []
    private var rowViews: [CleanupRuleRowView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        Theme.styleHeading(titleLabel, subtitleLabel)
        subtitleLabel.preferredMaxLayoutWidth = 520
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(subtitleLabel)

        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(enabledChanged(_:))
        enabledCheckbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(enabledCheckbox)

        // Column headers aligned to CleanupRuleRowView's columns.
        for header in [onHeader, patternHeader] {
            header.font = .systemFont(ofSize: 11, weight: .medium)
            header.textColor = .secondaryLabelColor
            header.translatesAutoresizingMaskIntoConstraints = false
            headerRow.addSubview(header)
        }
        NSLayoutConstraint.activate([
            headerRow.heightAnchor.constraint(equalToConstant: 14),
            onHeader.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: 4),
            onHeader.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            patternHeader.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: CleanupRuleRowView.patternColumnX),
            patternHeader.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
        ])
        rulesCard.addRow(headerRow)

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = rowsContainer
        rowsContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // Full-width rows; height comes from the list's intrinsic size.
            rowsContainer.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            rowsContainer.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            rowsContainer.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])
        rulesCard.addRow(scrollView)

        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addRuleTapped)

        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(resetRulesTapped)

        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(addButton)
        buttonRow.addView(resetButton, in: .trailing)
        rulesCard.addRow(buttonRow)

        addSubview(rulesCard)

        exampleLabel.stringValue = "Before: \"So uh, the meeting is tomorrow.\"\nAfter:    \"So the meeting is tomorrow.\""
        exampleLabel.font = .systemFont(ofSize: 11)
        exampleLabel.textColor = .secondaryLabelColor
        exampleLabel.maximumNumberOfLines = 3
        exampleCard.addRow(exampleLabel)
        addSubview(exampleCard)

        let pad: CGFloat = 20
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            enabledCheckbox.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
            enabledCheckbox.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            rulesCard.topAnchor.constraint(equalTo: enabledCheckbox.bottomAnchor, constant: 14),
            rulesCard.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            rulesCard.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),

            exampleCard.topAnchor.constraint(equalTo: rulesCard.bottomAnchor, constant: 12),
            exampleCard.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            exampleCard.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            exampleCard.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
        ])
    }

    func refresh() {
        rules = TranscriptProcessingSettings.cleanupRules
        enabledCheckbox.state = TranscriptProcessingSettings.cleanupEnabled ? .on : .off
        reloadRows()
    }


    private func reloadRows() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = rules.map { rule in
            let row = CleanupRuleRowView(rule: rule)
            row.onChange = { [weak self] updated in
                self?.update(updated)
            }
            row.onDelete = { [weak self] id in
                self?.deleteRule(id)
            }
            return row
        }
        layoutRows()
    }

    private func layoutRows() {
        rowsContainer.setRows(rowViews)
    }

    private func persist() {
        TranscriptProcessingSettings.cleanupRules = rules
    }

    private func update(_ rule: CleanupRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        persist()
    }

    private func deleteRule(_ id: UUID) {
        rules.removeAll { $0.id == id }
        persist()
        reloadRows()
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        TranscriptProcessingSettings.cleanupEnabled = sender.state == .on
    }

    @objc private func addRuleTapped() {
        rules.append(CleanupRule(pattern: ""))
        persist()
        reloadRows()
    }

    @objc private func resetRulesTapped() {
        TranscriptProcessingSettings.resetCleanupRules()
        refresh()
    }
}

private class CleanupRuleRowView: NSView, NSTextFieldDelegate {
    var onChange: ((CleanupRule) -> Void)?
    var onDelete: ((UUID) -> Void)?

    private var rule: CleanupRule
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let patternField = NSTextField()
    private let deleteButton = NSButton(title: "", target: nil, action: nil)

    init(rule: CleanupRule) {
        self.rule = rule
        super.init(frame: .zero)
        wantsLayer = true

        checkbox.state = rule.isEnabled ? .on : .off
        checkbox.target = self
        checkbox.action = #selector(checkboxChanged(_:))
        addSubview(checkbox)

        patternField.placeholderString = "Regex pattern"
        patternField.stringValue = rule.pattern
        patternField.delegate = self
        addSubview(patternField)

        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
        deleteButton.bezelStyle = .inline
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        addSubview(deleteButton)
    }


    override var wantsUpdateLayer: Bool { true }

    /// Rows sit inside a themed card, so they use the shared wash rather than
    /// `controlBackgroundColor` (which is opaque white in Light and was baked in
    /// at init, leaving white slabs in Dark Mode).
    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.wash(Theme.Wash.control).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// X origin of the pattern column, shared with the tab's column headers.
    static let patternColumnX: CGFloat = 40

    override func layout() {
        super.layout()
        let inset: CGFloat = 8
        checkbox.frame = NSRect(x: inset, y: 9, width: 24, height: 20)
        deleteButton.frame = NSRect(x: bounds.width - inset - 28, y: 5, width: 28, height: 28)
        patternField.frame = NSRect(x: Self.patternColumnX, y: 6, width: max(80, bounds.width - 82), height: 24)
    }

    func controlTextDidChange(_ obj: Notification) {
        rule.pattern = patternField.stringValue
        onChange?(rule)
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        rule.isEnabled = sender.state == .on
        onChange?(rule)
    }

    @objc private func deleteTapped() {
        onDelete?(rule.id)
    }
}

// MARK: - Shortcut Replacement Tab

private class ShortcutReplacementTabView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Text Replacements")
    private let subtitleLabel = NSTextField(labelWithString: "Replace spoken phrases like my email with saved text snippets.")
    private let enabledCheckbox = NSButton(checkboxWithTitle: "Enable text replacements", target: nil, action: nil)
    private let shortcutsCard = CardSectionView(title: "Replacement Rules", spacing: 8)
    private let headerRow = NSView()
    private let onHeader = NSTextField(labelWithString: "On")
    private let keyHeader = NSTextField(labelWithString: "Key")
    private let valueHeader = NSTextField(labelWithString: "Value")
    private let scrollView = NSScrollView()
    private let rowsContainer = RowListView()
    private let addButton = NSButton(title: "+", target: nil, action: nil)
    private let exampleCard = CardSectionView(title: "Example")
    private let exampleLabel = NSTextField(wrappingLabelWithString: "")

    private var shortcuts: [TextShortcut] = []
    private var rowViews: [ShortcutRuleRowView] = []

    private enum FocusField {
        case key
        case value
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        Theme.styleHeading(titleLabel, subtitleLabel)
        subtitleLabel.preferredMaxLayoutWidth = 520
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(subtitleLabel)

        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(enabledChanged(_:))
        enabledCheckbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(enabledCheckbox)

        // Column headers, positioned to match ShortcutRuleRowView's columns.
        for header in [onHeader, keyHeader, valueHeader] {
            header.font = .systemFont(ofSize: 11, weight: .medium)
            header.textColor = .secondaryLabelColor
            header.translatesAutoresizingMaskIntoConstraints = false
            headerRow.addSubview(header)
        }
        NSLayoutConstraint.activate([
            headerRow.heightAnchor.constraint(equalToConstant: 14),
            onHeader.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: 4),
            onHeader.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            keyHeader.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: ShortcutRuleRowView.keyColumnX),
            keyHeader.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            valueHeader.leadingAnchor.constraint(equalTo: headerRow.centerXAnchor, constant: 24),
            valueHeader.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
        ])
        shortcutsCard.addRow(headerRow)

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = rowsContainer
        rowsContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // Full-width rows; height comes from the list's intrinsic size.
            rowsContainer.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            rowsContainer.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            rowsContainer.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])
        shortcutsCard.addRow(scrollView)

        addButton.bezelStyle = .rounded
        addButton.font = .systemFont(ofSize: 15, weight: .medium)
        addButton.target = self
        addButton.action = #selector(addShortcutTapped)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.toolTip = "Add a replacement rule"
        shortcutsCard.stack.addArrangedSubview(addButton)
        NSLayoutConstraint.activate([
            addButton.widthAnchor.constraint(equalToConstant: 34),
            addButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        addSubview(shortcutsCard)

        exampleLabel.stringValue = "Key: my email\nValue: sam@example.com"
        exampleLabel.font = .systemFont(ofSize: 11)
        exampleLabel.textColor = .secondaryLabelColor
        exampleLabel.maximumNumberOfLines = 3
        exampleCard.addRow(exampleLabel)
        addSubview(exampleCard)

        let pad: CGFloat = 20
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            enabledCheckbox.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
            enabledCheckbox.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            shortcutsCard.topAnchor.constraint(equalTo: enabledCheckbox.bottomAnchor, constant: 14),
            shortcutsCard.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            shortcutsCard.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),

            exampleCard.topAnchor.constraint(equalTo: shortcutsCard.bottomAnchor, constant: 12),
            exampleCard.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            exampleCard.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            exampleCard.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
        ])
    }

    func refresh() {
        shortcuts = TranscriptProcessingSettings.shortcuts.filter { !Self.isEmpty($0) }
        if shortcuts.count != TranscriptProcessingSettings.shortcuts.count {
            persist()
        }
        enabledCheckbox.state = TranscriptProcessingSettings.shortcutsEnabled ? .on : .off
        reloadRows()
    }


    private func reloadRows() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = shortcuts.map { shortcut in
            let row = ShortcutRuleRowView(shortcut: shortcut)
            row.onChange = { [weak self] updated in
                self?.update(updated)
            }
            row.onDelete = { [weak self] id in
                self?.deleteShortcut(id)
            }
            row.onAdvanceFromKey = { [weak self] id in
                self?.advanceFromKey(id)
            }
            row.onAdvanceFromValue = { [weak self] id in
                self?.focusNextKey(after: id)
            }
            row.onEditingEnded = { [weak self] id in
                self?.pruneEmptyShortcutIfInactive(id)
            }
            return row
        }
        layoutRows()
    }

    private func layoutRows() {
        rowsContainer.setRows(rowViews)
    }

    private func persist() {
        TranscriptProcessingSettings.shortcuts = shortcuts.filter { !Self.isEmpty($0) }
    }

    private func update(_ shortcut: TextShortcut) {
        guard let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        shortcuts[index] = shortcut
        persist()
    }

    private func deleteShortcut(_ id: UUID) {
        shortcuts.removeAll { $0.id == id }
        persist()
        reloadRows()
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        TranscriptProcessingSettings.shortcutsEnabled = sender.state == .on
    }

    @objc private func addShortcutTapped() {
        addShortcutAndFocus()
    }

    private func addShortcutAndFocus() {
        let shortcut = TextShortcut(match: "", replacement: "")
        shortcuts.append(shortcut)
        reloadRows()
        focus(.key, for: shortcut.id)
    }

    private func advanceFromKey(_ id: UUID) {
        if removeIfEmpty(id) {
            return
        }
        focus(.value, for: id)
    }

    private func focusNextKey(after id: UUID) {
        if removeIfEmpty(id) {
            return
        }

        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else {
            addShortcutAndFocus()
            return
        }

        let nextIndex = shortcuts.index(after: index)
        guard nextIndex < shortcuts.endIndex else {
            addShortcutAndFocus()
            return
        }

        focus(.key, for: shortcuts[nextIndex].id)
    }

    private func pruneEmptyShortcutIfInactive(_ id: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let row = self.rowViews.first(where: { $0.shortcutID == id }) else { return }
            guard !row.containsFirstResponder(in: self.window) else { return }
            _ = self.removeIfEmpty(id)
        }
    }

    private func removeIfEmpty(_ id: UUID) -> Bool {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }),
              Self.isEmpty(shortcuts[index]) else {
            return false
        }

        shortcuts.remove(at: index)
        persist()
        reloadRows()
        return true
    }

    private static func isEmpty(_ shortcut: TextShortcut) -> Bool {
        shortcut.match.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            shortcut.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func focus(_ field: FocusField, for id: UUID) {
        guard let row = rowViews.first(where: { $0.shortcutID == id }) else { return }
        scrollView.documentView?.scroll(row.frame.origin)
        DispatchQueue.main.async { [weak self, weak row] in
            guard let self, let row else { return }
            switch field {
            case .key:
                row.focusKey(in: self.window)
            case .value:
                row.focusValue(in: self.window)
            }
        }
    }
}

private class ShortcutRuleRowView: NSView, NSTextFieldDelegate {
    var onChange: ((TextShortcut) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onAdvanceFromKey: ((UUID) -> Void)?
    var onAdvanceFromValue: ((UUID) -> Void)?
    var onEditingEnded: ((UUID) -> Void)?

    var shortcutID: UUID { shortcut.id }

    private var shortcut: TextShortcut
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let matchField = NSTextField()
    private let replacementField = NSTextField()
    private let deleteButton = NSButton(title: "", target: nil, action: nil)

    init(shortcut: TextShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        wantsLayer = true

        checkbox.state = shortcut.isEnabled ? .on : .off
        checkbox.target = self
        checkbox.action = #selector(checkboxChanged(_:))
        addSubview(checkbox)

        matchField.placeholderString = "my email"
        matchField.stringValue = shortcut.match
        matchField.delegate = self
        addSubview(matchField)

        replacementField.placeholderString = "sam@example.com"
        replacementField.stringValue = shortcut.replacement
        replacementField.delegate = self
        addSubview(replacementField)

        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
        deleteButton.bezelStyle = .inline
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        addSubview(deleteButton)
    }


    override var wantsUpdateLayer: Bool { true }

    /// Rows sit inside a themed card, so they use the shared wash rather than
    /// `controlBackgroundColor` (which is opaque white in Light and was baked in
    /// at init, leaving white slabs in Dark Mode).
    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.wash(Theme.Wash.control).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// X origin of the key column, shared with the tab's column headers.
    static let keyColumnX: CGFloat = 40

    override func layout() {
        super.layout()
        let inset: CGFloat = 8
        checkbox.frame = NSRect(x: inset, y: 9, width: 24, height: 20)
        deleteButton.frame = NSRect(x: bounds.width - inset - 28, y: 5, width: 28, height: 28)

        let fieldsX: CGFloat = Self.keyColumnX
        let gap: CGFloat = 8
        let available = max(160, bounds.width - fieldsX - 44)
        let fieldW = (available - gap) / 2
        matchField.frame = NSRect(x: fieldsX, y: 6, width: fieldW, height: 24)
        replacementField.frame = NSRect(x: fieldsX + fieldW + gap, y: 6, width: fieldW, height: 24)
    }

    func controlTextDidChange(_ obj: Notification) {
        shortcut.match = matchField.stringValue
        shortcut.replacement = replacementField.stringValue
        onChange?(shortcut)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        shortcut.match = matchField.stringValue
        shortcut.replacement = replacementField.stringValue
        onChange?(shortcut)
        onEditingEnded?(shortcut.id)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) ||
              commandSelector == #selector(NSResponder.insertTab(_:)) else {
            return false
        }

        if control === matchField {
            onAdvanceFromKey?(shortcut.id)
        } else if control === replacementField {
            onAdvanceFromValue?(shortcut.id)
        }
        return true
    }

    func focusKey(in window: NSWindow?) {
        window?.makeFirstResponder(matchField)
        matchField.currentEditor()?.selectAll(nil)
    }

    func focusValue(in window: NSWindow?) {
        window?.makeFirstResponder(replacementField)
        replacementField.currentEditor()?.selectAll(nil)
    }

    func containsFirstResponder(in window: NSWindow?) -> Bool {
        guard let firstResponder = window?.firstResponder else { return false }
        if firstResponder === matchField || firstResponder === replacementField {
            return true
        }
        return firstResponder === matchField.currentEditor() ||
            firstResponder === replacementField.currentEditor()
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        shortcut.isEnabled = sender.state == .on
        onChange?(shortcut)
    }

    @objc private func deleteTapped() {
        onDelete?(shortcut.id)
    }
}

// MARK: - Post Processing Tab

private class CleanupTabView: NSView, NSTextViewDelegate {
    
    var onSettingsChanged: (() -> Void)?
    
    private let titleLabel = NSTextField(labelWithString: "Post Processing")
    private let subtitleLabel = NSTextField(labelWithString: "Use a local LLM after transcription to polish wording, punctuation, and recognition misses.")
    
    private let enabledCheckbox = NSButton(checkboxWithTitle: "Enable LLM post processing", target: nil, action: nil)
    
    private let modelCard = CardSectionView(title: "Post Processing Model", spacing: 4)
    private let modelNameRow = NSStackView()
    private let modelNameLabel = NSTextField(labelWithString: "")
    private let modelSizeLabel = NSTextField(labelWithString: "")
    private let modelDescLabel = NSTextField(labelWithString: "")
    private let modelStatusLabel = NSTextField(labelWithString: "")
    
    private let actionButton = NSButton()
    private let deleteButton = NSButton(title: "Delete Model", target: nil, action: nil)
    
    private let progressContainer = NSView()
    private let progressBar = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private var progressHeight: NSLayoutConstraint!

    private let promptCard = CardSectionView(title: "Post Processing Prompt", spacing: 8)
    private let promptButtonRow = NSStackView()
    private let buttonRow = NSStackView()
    private let promptScrollView = NSScrollView()
    private let promptTextView = NSTextView()
    private let resetPromptButton = NSButton(title: "Reset to Default Prompt", target: nil, action: nil)
    private let openPromptEditorButton = NSButton(title: "Open Full Editor…", target: nil, action: nil)
    private let promptEditorController = CleanupPromptEditorController()
    
    private let exampleCard = CardSectionView(title: "Example")
    private let exampleLabel = NSTextField(wrappingLabelWithString: "")
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        setupObservers()
        refresh()
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    private func setupUI() {
        Theme.styleHeading(titleLabel, subtitleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.preferredMaxLayoutWidth = 480
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        
        // Enable checkbox
        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(enabledChanged(_:))
        enabledCheckbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(enabledCheckbox)
        
        // Model card
        let model = CleanupModelDownloader.CleanupModel.qwen35_0_8b
        modelNameLabel.stringValue = model.displayName
        modelNameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        
        modelSizeLabel.stringValue = "Size: \(model.estimatedSizeString)"
        modelSizeLabel.font = .systemFont(ofSize: 11)
        modelSizeLabel.textColor = .secondaryLabelColor
        
        modelDescLabel.stringValue = model.description
        modelDescLabel.font = .systemFont(ofSize: 11)
        modelDescLabel.textColor = .tertiaryLabelColor
        modelDescLabel.lineBreakMode = .byTruncatingTail
        
        modelStatusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        modelStatusLabel.alignment = .right
        modelStatusLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Name on the left, status pinned right.
        modelNameRow.orientation = .horizontal
        modelNameRow.spacing = 8
        modelNameRow.addArrangedSubview(modelNameLabel)
        modelNameRow.addView(modelStatusLabel, in: .trailing)
        modelCard.addRow(modelNameRow)
        modelCard.addRow(modelSizeLabel)
        modelCard.addRow(modelDescLabel)
        addSubview(modelCard)
        
        // Action + delete, side by side under the card
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .large
        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        
        deleteButton.bezelStyle = .rounded
        deleteButton.controlSize = .regular
        deleteButton.contentTintColor = .systemRed
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)

        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addArrangedSubview(actionButton)
        buttonRow.addArrangedSubview(deleteButton)
        addSubview(buttonRow)
        
        // Progress
        progressContainer.isHidden = true
        progressContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressContainer)
        
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressContainer.addSubview(progressBar)
        
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.alignment = .center
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressContainer.addSubview(progressLabel)

        // Collapsed to zero height while idle so it leaves no gap.
        progressHeight = progressContainer.heightAnchor.constraint(equalToConstant: 0)
        progressHeight.isActive = true

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

        resetPromptButton.bezelStyle = .rounded
        resetPromptButton.controlSize = .small
        resetPromptButton.target = self
        resetPromptButton.action = #selector(resetPromptTapped)

        openPromptEditorButton.bezelStyle = .rounded
        openPromptEditorButton.controlSize = .small
        openPromptEditorButton.target = self
        openPromptEditorButton.action = #selector(openPromptEditorTapped)

        promptButtonRow.orientation = .horizontal
        promptButtonRow.spacing = 8
        promptButtonRow.addArrangedSubview(openPromptEditorButton)
        promptButtonRow.addView(resetPromptButton, in: .trailing)
        promptCard.addRow(promptButtonRow)
        promptCard.addRow(promptScrollView)
        addSubview(promptCard)
        
        // Example card
        let exampleText = """
        Before: "So um like the meeting is at 3pm you know on Tuesday"
        After:    "The meeting is at 3pm on Tuesday"
        """
        exampleLabel.stringValue = exampleText
        exampleLabel.font = .systemFont(ofSize: 11)
        exampleLabel.textColor = .secondaryLabelColor
        exampleLabel.maximumNumberOfLines = 3
        exampleCard.addRow(exampleLabel)
        addSubview(exampleCard)

        let pad: CGFloat = 20
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            enabledCheckbox.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
            enabledCheckbox.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            modelCard.topAnchor.constraint(equalTo: enabledCheckbox.bottomAnchor, constant: 14),
            modelCard.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            modelCard.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            buttonRow.topAnchor.constraint(equalTo: modelCard.bottomAnchor, constant: 12),
            buttonRow.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            progressContainer.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: 8),
            progressContainer.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressContainer.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            progressBar.topAnchor.constraint(equalTo: progressContainer.topAnchor),
            progressBar.leadingAnchor.constraint(equalTo: progressContainer.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 18),

            progressLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 2),
            progressLabel.leadingAnchor.constraint(equalTo: progressContainer.leadingAnchor),
            progressLabel.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor),

            // Prompt card absorbs the leftover vertical space.
            promptCard.topAnchor.constraint(equalTo: progressContainer.bottomAnchor, constant: 14),
            promptCard.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            promptCard.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            promptScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),

            exampleCard.topAnchor.constraint(equalTo: promptCard.bottomAnchor, constant: 12),
            exampleCard.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            exampleCard.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            exampleCard.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
        ])
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
            setProgressVisible(true)
        } else {
            setProgressVisible(false)
            
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
    
    /// Shows/hides the download progress strip *and* collapses its height, so
    /// an idle pane has no dead space between the model card and the prompt.
    private func setProgressVisible(_ visible: Bool) {
        progressContainer.isHidden = !visible
        progressHeight.constant = visible ? 38 : 0
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
        alert.messageText = "Delete Post Processing Model?"
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
