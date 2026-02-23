import AppKit

/// Window for viewing and managing transcription history.
final class HistoryWindowController: NSWindowController {
    
    private var scrollView: NSScrollView!
    private var stackView: NSStackView!
    private var items: [TranscriptionItem] = []
    private var selectedIndex: Int? = nil
    private var cardViews: [HistoryCardView] = []
    
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Transcription History"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 300)
        
        self.init(window: window)
        setupUI()
        loadHistory()
        
        // Listen for changes
        HistoryStore.shared.onHistoryChanged = { [weak self] in
            self?.loadHistory()
        }
    }
    
    private func setupUI() {
        guard let window = window else { return }
        
        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        
        // Stack view for cards
        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 1
        stackView.translatesAutoresizingMaskIntoConstraints = false
        
        // Wrapper to pin stack to top
        let wrapperView = NSView()
        wrapperView.translatesAutoresizingMaskIntoConstraints = false
        wrapperView.addSubview(stackView)
        
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: wrapperView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: wrapperView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: wrapperView.trailingAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: wrapperView.bottomAnchor)
        ])
        
        // Scroll view
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = wrapperView
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.drawsBackground = true
        
        contentView.addSubview(scrollView)
        
        // Separator line
        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        contentView.addSubview(separator)
        
        // Button bar
        let buttonBar = NSView()
        buttonBar.translatesAutoresizingMaskIntoConstraints = false
        buttonBar.wantsLayer = true
        
        let clearButton = NSButton(title: "Clear All", target: self, action: #selector(clearAll(_:)))
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.bezelStyle = .rounded
        
        let copyButton = NSButton(title: "Copy Selected", target: self, action: #selector(copySelected(_:)))
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.bezelStyle = .rounded
        
        buttonBar.addSubview(clearButton)
        buttonBar.addSubview(copyButton)
        contentView.addSubview(buttonBar)
        
        NSLayoutConstraint.activate([
            // Scroll view
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),
            
            // Separator
            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: buttonBar.topAnchor),
            
            // Button bar
            buttonBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            buttonBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            buttonBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            buttonBar.heightAnchor.constraint(equalToConstant: 52),
            
            // Buttons
            clearButton.leadingAnchor.constraint(equalTo: buttonBar.leadingAnchor, constant: 16),
            clearButton.centerYAnchor.constraint(equalTo: buttonBar.centerYAnchor),
            
            copyButton.leadingAnchor.constraint(equalTo: clearButton.trailingAnchor, constant: 12),
            copyButton.centerYAnchor.constraint(equalTo: buttonBar.centerYAnchor),
            
            // Wrapper sizing
            wrapperView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
        
        window.contentView = contentView
    }
    
    private func loadHistory() {
        items = HistoryStore.shared.getAll()
        rebuildCards()
    }
    
    private func rebuildCards() {
        // Clear existing
        for card in cardViews {
            card.removeFromSuperview()
        }
        cardViews.removeAll()
        selectedIndex = nil
        
        if items.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "No transcriptions yet")
            emptyLabel.textColor = .tertiaryLabelColor
            emptyLabel.font = .systemFont(ofSize: 14)
            emptyLabel.alignment = .center
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            
            let emptyCard = HistoryCardView(frame: .zero)
            emptyCard.translatesAutoresizingMaskIntoConstraints = false
            emptyCard.addSubview(emptyLabel)
            
            NSLayoutConstraint.activate([
                emptyLabel.centerXAnchor.constraint(equalTo: emptyCard.centerXAnchor),
                emptyLabel.centerYAnchor.constraint(equalTo: emptyCard.centerYAnchor),
                emptyCard.heightAnchor.constraint(equalToConstant: 80)
            ])
            
            stackView.addArrangedSubview(emptyCard)
            emptyCard.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            cardViews.append(emptyCard)
            return
        }
        
        for (index, item) in items.enumerated() {
            let card = HistoryCardView(frame: .zero)
            card.translatesAutoresizingMaskIntoConstraints = false
            card.configure(with: item, isEven: index % 2 == 0)
            card.index = index
            
            let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(cardClicked(_:)))
            card.addGestureRecognizer(clickGesture)
            
            let doubleClickGesture = NSClickGestureRecognizer(target: self, action: #selector(cardDoubleClicked(_:)))
            doubleClickGesture.numberOfClicksRequired = 2
            card.addGestureRecognizer(doubleClickGesture)
            
            stackView.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            cardViews.append(card)
        }
    }
    
    @objc private func cardClicked(_ gesture: NSClickGestureRecognizer) {
        guard let card = gesture.view as? HistoryCardView else { return }
        selectCard(at: card.index)
    }
    
    @objc private func cardDoubleClicked(_ gesture: NSClickGestureRecognizer) {
        guard let card = gesture.view as? HistoryCardView else { return }
        selectCard(at: card.index)
        copySelected(gesture)
    }
    
    private func selectCard(at index: Int) {
        // Deselect previous
        if let prev = selectedIndex, prev < cardViews.count {
            cardViews[prev].setSelected(false)
        }
        
        // Select new
        selectedIndex = index
        if index < cardViews.count {
            cardViews[index].setSelected(true)
        }
    }
    
    // MARK: - Actions
    
    @objc private func copySelected(_ sender: Any) {
        guard let index = selectedIndex, index < items.count else {
            // Flash window title if nothing selected
            window?.title = "Select an item first"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.window?.title = "Transcription History"
            }
            return
        }
        
        let item = items[index]
        TextInserter.copyToClipboard(item.text)
        
        // Visual feedback
        window?.title = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.window?.title = "Transcription History"
        }
    }
    
    @objc private func clearAll(_ sender: Any) {
        let alert = NSAlert()
        alert.messageText = "Clear All History?"
        alert.informativeText = "This will delete all transcription history. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            HistoryStore.shared.clear()
        }
    }
    
    func showWindow() {
        loadHistory()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - History Card View

private class HistoryCardView: NSView {
    
    var index: Int = 0
    
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let figuresBadge = NSTextField(labelWithString: "")
    private var isSelectedState = false
    private var isEvenRow = false
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        wantsLayer = true
        
        // Text label
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = .systemFont(ofSize: 13)
        textLabel.textColor = .labelColor
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 3
        textLabel.cell?.truncatesLastVisibleLine = true
        textLabel.isSelectable = false
        addSubview(textLabel)
        
        // Time label
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = .systemFont(ofSize: 11)
        timeLabel.textColor = .tertiaryLabelColor
        addSubview(timeLabel)
        
        // Figures badge (shows if screenshots attached)
        figuresBadge.translatesAutoresizingMaskIntoConstraints = false
        figuresBadge.font = .systemFont(ofSize: 10, weight: .medium)
        figuresBadge.textColor = .secondaryLabelColor
        figuresBadge.isHidden = true
        addSubview(figuresBadge)
        
        NSLayoutConstraint.activate([
            // Text
            textLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            
            // Time - bottom left
            timeLabel.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: 6),
            timeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            timeLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            
            // Figures badge - bottom right
            figuresBadge.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),
            figuresBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
        ])
    }
    
    func configure(with item: TranscriptionItem, isEven: Bool) {
        self.isEvenRow = isEven
        
        // Clean up display text - remove figure paths, keep just [Figure N] references
        let displayText = cleanDisplayText(item.text)
        textLabel.stringValue = displayText
        textLabel.toolTip = item.text  // Full text on hover
        
        timeLabel.stringValue = item.formattedTime
        
        // Count figures
        let figureCount = countFigures(in: item.text)
        if figureCount > 0 {
            figuresBadge.stringValue = "📎 \(figureCount) figure\(figureCount == 1 ? "" : "s")"
            figuresBadge.isHidden = false
        } else {
            figuresBadge.isHidden = true
        }
        
        updateBackground()
    }
    
    private func cleanDisplayText(_ text: String) -> String {
        // Remove the figure paths section at the end
        // Pattern: "\n\nFigure 1: /path...\nFigure 2: /path..."
        var result = text
        
        // Find where figure paths start and remove them
        if let range = result.range(of: "\n\nFigure 1:", options: .literal) {
            result = String(result[..<range.lowerBound])
        } else if let range = result.range(of: "\nFigure 1:", options: .literal) {
            result = String(result[..<range.lowerBound])
        }
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func countFigures(in text: String) -> Int {
        // Count [Figure N] references
        var count = 0
        var searchText = text
        while let range = searchText.range(of: "[Figure ", options: .literal) {
            count += 1
            searchText = String(searchText[range.upperBound...])
        }
        return count
    }
    
    func setSelected(_ selected: Bool) {
        isSelectedState = selected
        updateBackground()
    }
    
    private func updateBackground() {
        if isSelectedState {
            layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
            textLabel.textColor = .white
            timeLabel.textColor = NSColor.white.withAlphaComponent(0.7)
            figuresBadge.textColor = NSColor.white.withAlphaComponent(0.7)
        } else {
            let bgColor: NSColor = isEvenRow 
                ? .controlBackgroundColor 
                : .controlBackgroundColor.withAlphaComponent(0.5)
            layer?.backgroundColor = bgColor.cgColor
            textLabel.textColor = .labelColor
            timeLabel.textColor = .tertiaryLabelColor
            figuresBadge.textColor = .secondaryLabelColor
        }
    }
    
    override func updateLayer() {
        updateBackground()
    }
}
