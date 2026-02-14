import AppKit

/// Window for viewing and managing transcription history.
final class HistoryWindowController: NSWindowController {
    
    private var tableView: NSTableView!
    private var items: [TranscriptionItem] = []
    
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Transcription History"
        window.center()
        window.isReleasedWhenClosed = false
        
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
        
        // Create scroll view with table
        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        
        tableView = NSTableView(frame: scrollView.bounds)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 60
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        
        // Text column
        let textColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        textColumn.title = "Transcription"
        textColumn.width = 350
        textColumn.minWidth = 200
        textColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(textColumn)
        
        // Time column
        let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
        timeColumn.title = "Time"
        timeColumn.width = 120
        timeColumn.minWidth = 80
        tableView.addTableColumn(timeColumn)
        
        scrollView.documentView = tableView
        
        // Buttons at bottom
        let buttonBar = NSView(frame: NSRect(x: 0, y: 0, width: window.contentView!.bounds.width, height: 40))
        buttonBar.autoresizingMask = [.width, .minYMargin]
        
        let copyButton = NSButton(title: "Copy Selected", target: self, action: #selector(copySelected(_:)))
        copyButton.frame = NSRect(x: 10, y: 8, width: 100, height: 24)
        buttonBar.addSubview(copyButton)
        
        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteSelected(_:)))
        deleteButton.frame = NSRect(x: 120, y: 8, width: 80, height: 24)
        buttonBar.addSubview(deleteButton)
        
        let clearButton = NSButton(title: "Clear All", target: self, action: #selector(clearAll(_:)))
        clearButton.frame = NSRect(x: window.contentView!.bounds.width - 90, y: 8, width: 80, height: 24)
        clearButton.autoresizingMask = [.minXMargin]
        buttonBar.addSubview(clearButton)
        
        // Layout
        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        
        scrollView.frame = NSRect(
            x: 0, y: 40,
            width: contentView.bounds.width,
            height: contentView.bounds.height - 40
        )
        buttonBar.frame = NSRect(
            x: 0, y: 0,
            width: contentView.bounds.width,
            height: 40
        )
        
        contentView.addSubview(scrollView)
        contentView.addSubview(buttonBar)
        
        window.contentView = contentView
    }
    
    private func loadHistory() {
        items = HistoryStore.shared.getAll()
        tableView?.reloadData()
    }
    
    // MARK: - Actions
    
    @objc private func copySelected(_ sender: Any) {
        let row = tableView.selectedRow
        guard row >= 0 && row < items.count else { return }
        
        let item = items[row]
        TextInserter.copyToClipboard(item.text)
        
        // Brief visual feedback
        window?.title = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.window?.title = "Transcription History"
        }
    }
    
    @objc private func deleteSelected(_ sender: Any) {
        let row = tableView.selectedRow
        guard row >= 0 && row < items.count else { return }
        
        HistoryStore.shared.delete(at: row)
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

// MARK: - Table View Data Source & Delegate

extension HistoryWindowController: NSTableViewDataSource, NSTableViewDelegate {
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let item = items[row]
        
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("cell")
        
        var cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
        if cell == nil {
            cell = NSTextField(labelWithString: "")
            cell?.identifier = identifier
            cell?.lineBreakMode = .byTruncatingTail
            cell?.maximumNumberOfLines = 2
        }
        
        if tableColumn?.identifier.rawValue == "text" {
            cell?.stringValue = item.text
            cell?.toolTip = item.text
        } else if tableColumn?.identifier.rawValue == "time" {
            cell?.stringValue = item.formattedTime
            cell?.font = .systemFont(ofSize: 11)
            cell?.textColor = .secondaryLabelColor
        }
        
        return cell
    }
    
    func tableViewSelectionDidChange(_ notification: Notification) {
        // Could enable/disable buttons based on selection
    }
    
    // Double-click to copy
    func tableView(_ tableView: NSTableView, shouldSelect row: Int) -> Bool {
        true
    }
}
