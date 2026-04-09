import AppKit

final class CleanupPromptEditorController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private var window: NSWindow?
    private let textView = NSTextView()

    func show() {
        if let window {
            textView.string = CleanupSettings.prompt
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 620))

        let titleLabel = NSTextField(labelWithString: "Cleanup Prompt")
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        contentView.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "Edit the instruction prompt used by the local cleanup model.")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        contentView.addSubview(subtitleLabel)

        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true

        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.delegate = self
        textView.string = CleanupSettings.prompt
        scroll.documentView = textView
        contentView.addSubview(scroll)

        let resetButton = NSButton(title: "Reset to Default", target: self, action: #selector(resetPrompt))
        resetButton.bezelStyle = .rounded
        contentView.addSubview(resetButton)

        let doneButton = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        contentView.addSubview(doneButton)

        // Manual frames
        let pad: CGFloat = 16
        titleLabel.frame = NSRect(x: pad, y: contentView.bounds.height - 34, width: contentView.bounds.width - pad * 2, height: 22)
        subtitleLabel.frame = NSRect(x: pad, y: contentView.bounds.height - 56, width: contentView.bounds.width - pad * 2, height: 18)
        scroll.frame = NSRect(x: pad, y: 56, width: contentView.bounds.width - pad * 2, height: contentView.bounds.height - 122)
        resetButton.frame = NSRect(x: pad, y: 16, width: 140, height: 28)
        doneButton.frame = NSRect(x: contentView.bounds.width - pad - 80, y: 16, width: 80, height: 28)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Edit Cleanup Prompt"
        window.minSize = NSSize(width: 620, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = contentView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    @objc private func resetPrompt() {
        CleanupSettings.resetPrompt()
        textView.string = CleanupSettings.prompt
    }

    @objc private func closeWindow() {
        savePrompt()
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        savePrompt()
    }

    func textDidChange(_ notification: Notification) {
        savePrompt()
    }

    private func savePrompt() {
        CleanupSettings.prompt = textView.string
    }
}
