import AppKit

/// A small notification-style card in the top-right corner with up to two
/// actions. Used for "call detected — record?", silence reminders, and
/// "call ended — stop?". Never steals focus from the call.
final class MeetingPromptPanel {

    struct Prompt {
        enum Tone {
            case neutral
            case recording
            case success
        }

        var symbol: String
        var tone: Tone
        var title: String
        var message: String
        var primaryTitle: String
        var secondaryTitle: String?
        /// Hide by itself after this long (nil = stay until answered).
        var timeout: TimeInterval?
        var onPrimary: () -> Void
        var onSecondary: (() -> Void)?
        /// Closed with ✕ or timed out.
        var onDismiss: (() -> Void)?
    }

    static let shared = MeetingPromptPanel()

    private var panel: NSPanel?
    private var current: Prompt?
    private var dismissWork: DispatchWorkItem?

    func show(_ prompt: Prompt) {
        close(notify: false)
        current = prompt

        let width: CGFloat = 348
        let content = PromptContentView(prompt: prompt) { [weak self] action in
            self?.handle(action)
        }
        let height = content.fittingHeight(width: width)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true

        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        panel.contentView = content

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - width - 16, y: visible.maxY - height - 12))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.smooth
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        if let timeout = prompt.timeout {
            let work = DispatchWorkItem { [weak self] in self?.close(notify: true) }
            dismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    /// Hide the card without running any action.
    func dismiss() {
        close(notify: false)
    }

    var isShowing: Bool { panel != nil }

    private enum Action {
        case primary
        case secondary
        case close
    }

    private func handle(_ action: Action) {
        guard let prompt = current else { return }
        close(notify: false)
        switch action {
        case .primary: prompt.onPrimary()
        case .secondary: prompt.onSecondary?()
        case .close: prompt.onDismiss?()
        }
    }

    private func close(notify: Bool) {
        dismissWork?.cancel()
        dismissWork = nil
        let prompt = current
        current = nil
        if let panel {
            self.panel = nil
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Theme.Motion.hover
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        }
        if notify { prompt?.onDismiss?() }
    }

    // MARK: - Content

    private final class PromptContentView: NSView {
        private let background = NSVisualEffectView()
        private let iconBackground: AdaptiveBackgroundView
        private let iconView = NSImageView()
        private let titleLabel = NSTextField(labelWithString: "")
        private let messageLabel = NSTextField(wrappingLabelWithString: "")
        private let primaryButton = NSButton(title: "", target: nil, action: nil)
        private let secondaryButton = NSButton(title: "", target: nil, action: nil)
        private let closeButton = NSButton()
        private let onAction: (Action) -> Void

        init(prompt: Prompt, onAction: @escaping (Action) -> Void) {
            self.onAction = onAction
            let tint: NSColor
            switch prompt.tone {
            case .neutral: tint = .controlAccentColor
            case .recording: tint = .systemRed
            case .success: tint = .systemGreen
            }
            iconBackground = AdaptiveBackgroundView(color: tint.withAlphaComponent(0.15), cornerRadius: 15)
            super.init(frame: .zero)

            background.material = .popover
            background.blendingMode = .behindWindow
            background.state = .active
            background.wantsLayer = true
            background.layer?.cornerRadius = 14
            background.layer?.cornerCurve = .continuous
            background.layer?.masksToBounds = true
            background.layer?.borderWidth = 1
            background.layer?.borderColor = NSColor.separatorColor.cgColor
            addSubview(background)

            addSubview(iconBackground)
            iconView.image = NSImage(systemSymbolName: prompt.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
            iconView.contentTintColor = tint
            addSubview(iconView)

            titleLabel.stringValue = prompt.title
            titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            titleLabel.lineBreakMode = .byTruncatingTail
            addSubview(titleLabel)

            messageLabel.stringValue = prompt.message
            messageLabel.font = .systemFont(ofSize: 12)
            messageLabel.textColor = .secondaryLabelColor
            messageLabel.maximumNumberOfLines = 3
            addSubview(messageLabel)

            primaryButton.title = prompt.primaryTitle
            primaryButton.bezelStyle = .rounded
            primaryButton.controlSize = .regular
            primaryButton.keyEquivalent = "\r"
            if prompt.tone == .recording {
                primaryButton.bezelColor = .systemRed
            }
            primaryButton.target = self
            primaryButton.action = #selector(primaryClicked)
            addSubview(primaryButton)

            if let secondary = prompt.secondaryTitle {
                secondaryButton.title = secondary
                secondaryButton.bezelStyle = .rounded
                secondaryButton.controlSize = .regular
                secondaryButton.target = self
                secondaryButton.action = #selector(secondaryClicked)
                addSubview(secondaryButton)
            }

            closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
            closeButton.isBordered = false
            closeButton.contentTintColor = .tertiaryLabelColor
            closeButton.target = self
            closeButton.action = #selector(closeClicked)
            addSubview(closeButton)
        }

        required init?(coder: NSCoder) { fatalError() }

        private let padding: CGFloat = 14
        private let iconSize: CGFloat = 30

        func fittingHeight(width: CGFloat) -> CGFloat {
            let textWidth = width - padding * 2 - iconSize - 12 - 16
            messageLabel.preferredMaxLayoutWidth = textWidth
            let messageHeight = messageLabel.stringValue.isEmpty ? 0 : messageLabel.fittingSize.height
            return padding + 18 + 3 + messageHeight + 12 + 28 + padding
        }

        override func layout() {
            super.layout()
            background.frame = bounds
            let top = bounds.height - padding
            iconBackground.frame = NSRect(x: padding, y: top - iconSize, width: iconSize, height: iconSize)
            iconView.frame = iconBackground.frame.insetBy(dx: 6, dy: 6)

            let textX = iconBackground.frame.maxX + 12
            let textWidth = bounds.width - textX - padding - 16
            titleLabel.frame = NSRect(x: textX, y: top - 18, width: textWidth, height: 18)
            messageLabel.preferredMaxLayoutWidth = textWidth
            let messageHeight = messageLabel.stringValue.isEmpty ? 0 : messageLabel.fittingSize.height
            messageLabel.frame = NSRect(x: textX, y: titleLabel.frame.minY - 3 - messageHeight, width: textWidth, height: messageHeight)
            closeButton.frame = NSRect(x: bounds.width - padding - 14, y: top - 14, width: 14, height: 14)

            primaryButton.sizeToFit()
            let buttonY = padding
            primaryButton.frame = NSRect(
                x: bounds.width - padding - max(primaryButton.frame.width, 88),
                y: buttonY,
                width: max(primaryButton.frame.width, 88),
                height: 28
            )
            if secondaryButton.superview != nil {
                secondaryButton.sizeToFit()
                let secondaryWidth = max(secondaryButton.frame.width, 80)
                secondaryButton.frame = NSRect(x: primaryButton.frame.minX - 8 - secondaryWidth, y: buttonY, width: secondaryWidth, height: 28)
            }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            effectiveAppearance.performAsCurrentDrawingAppearance {
                background.layer?.borderColor = NSColor.separatorColor.cgColor
            }
        }

        @objc private func primaryClicked() { onAction(.primary) }
        @objc private func secondaryClicked() { onAction(.secondary) }
        @objc private func closeClicked() { onAction(.close) }
    }
}
