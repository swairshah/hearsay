import AppKit

/// Settings pane for the custom vocabulary (`vocabulary.json`, also edited by `hearsay vocab`).
final class VocabularyPaneView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    private let titleLabel = NSTextField(labelWithString: "Vocabulary")
    private let subtitleLabel = NSTextField(wrappingLabelWithString:
        "Names and terms Hearsay should spell right. Anything listed under Sounds like is corrected automatically, and the LLM passes get the exact spellings.")
    private let searchField = NSSearchField()
    private let addButton = NSButton(title: "Add Term…", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let card = CardSectionView(title: nil, spacing: 0)
    private let scrollView = NSScrollView()
    private let tableView = VocabularyTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")

    private var vocabulary = Vocabulary()
    private var rows: [VocabularyTerm] = []

    private enum Column: String, CaseIterable {
        case term, aliases, note

        var title: String {
            switch self {
            case .term: return "Term"
            case .aliases: return "Sounds like"
            case .note: return "Note"
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(vocabularyChanged), name: .vocabularyChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        Theme.styleHeading(titleLabel, subtitleLabel)
        subtitleLabel.preferredMaxLayoutWidth = 520

        searchField.placeholderString = "Search terms"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)

        for (button, action) in [(addButton, #selector(addTapped)), (editButton, #selector(editTapped)), (removeButton, #selector(removeTapped))] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.target = self
            button.action = action
        }
        addButton.keyEquivalent = ""
        let toolbar = NSStackView(views: [searchField, NSView(), editButton, removeButton, addButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        searchField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.resizingMask = .userResizingMask
            switch column {
            case .term: tableColumn.width = 170
            case .aliases: tableColumn.width = 220
            case .note: tableColumn.width = 180
            }
            tableView.addTableColumn(tableColumn)
        }
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 26
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked)
        tableView.onDelete = { [weak self] in self?.removeTapped() }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        card.stack.distribution = .fill
        card.addRow(scrollView)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingMiddle
        footerLabel.stringValue = "Also editable from Terminal: hearsay vocab add \"HumanLayer\" --alias \"human lair\""

        for view in [titleLabel, subtitleLabel, toolbar, card, emptyLabel, footerLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        let pad: CGFloat = 20
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            toolbar.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
            toolbar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            card.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            card.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),

            emptyLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: card.widthAnchor, constant: -40),

            footerLabel.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 8),
            footerLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor, constant: 2),
            footerLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            footerLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
        ])
    }

    // MARK: - Data

    func refresh() {
        vocabulary = VocabularyStore.shared.current
        reloadRows()
    }

    @objc private func vocabularyChanged() {
        refresh()
    }

    private func reloadRows() {
        let selectedIDs = Set(tableView.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
        rows = vocabulary.search(searchField.stringValue)
        tableView.reloadData()
        let reselect = IndexSet(rows.indices.filter { selectedIDs.contains(rows[$0].id) })
        tableView.selectRowIndexes(reselect, byExtendingSelection: false)

        if vocabulary.terms.isEmpty {
            emptyLabel.stringValue = "No terms yet. Add names, products and jargon your meetings use."
        } else if rows.isEmpty {
            emptyLabel.stringValue = "No terms match “\(searchField.stringValue)”."
        }
        emptyLabel.isHidden = !rows.isEmpty
        updateButtons()
    }

    private func updateButtons() {
        editButton.isEnabled = tableView.selectedRowIndexes.count == 1
        removeButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }

    private func persist(_ change: (inout Vocabulary) throws -> Void) {
        var updated = VocabularyStore.shared.current
        do {
            try change(&updated)
            try VocabularyStore.shared.save(updated)
        } catch {
            showError(error.localizedDescription)
        }
        refresh()
    }

    // MARK: - Actions

    @objc private func searchChanged() {
        reloadRows()
    }

    func controlTextDidChange(_ obj: Notification) {
        reloadRows()
    }

    @objc private func addTapped() {
        presentEditor(for: nil)
    }

    @objc private func editTapped() {
        guard tableView.selectedRowIndexes.count == 1, let row = tableView.selectedRowIndexes.first else { return }
        presentEditor(for: rows[row])
    }

    @objc private func tableDoubleClicked() {
        let row = tableView.clickedRow
        guard rows.indices.contains(row) else { return }
        presentEditor(for: rows[row])
    }

    @objc private func removeTapped() {
        let ids = tableView.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }
        guard !ids.isEmpty else { return }
        persist { vocabulary in
            ids.forEach { vocabulary.remove(id: $0) }
        }
    }

    private func presentEditor(for term: VocabularyTerm?) {
        guard let window else { return }
        let editor = VocabularyTermEditor(term: term)
        let alert = NSAlert()
        alert.messageText = term == nil ? "Add Term" : "Edit Term"
        alert.informativeText = "Separate several “sounds like” spellings with commas."
        alert.accessoryView = editor
        alert.addButton(withTitle: term == nil ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = editor.termField
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.persist { vocabulary in
                if var existing = term {
                    existing.text = editor.termText
                    existing.aliases = editor.aliases
                    existing.setNote(editor.note)
                    try vocabulary.update(existing)
                } else {
                    try vocabulary.add(editor.termText, aliases: editor.aliases, note: editor.note)
                }
            }
        }
    }

    private func showError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't save the vocabulary"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, let column = Column(rawValue: identifier.rawValue) else { return nil }
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeCell(identifier)
        let term = rows[row]
        switch column {
        case .term:
            cell.textField?.stringValue = term.text
            cell.textField?.font = .systemFont(ofSize: 12.5, weight: .medium)
            cell.textField?.textColor = .labelColor
        case .aliases:
            cell.textField?.stringValue = term.aliases.joined(separator: ", ")
            cell.textField?.font = .systemFont(ofSize: 12)
            cell.textField?.textColor = .secondaryLabelColor
        case .note:
            cell.textField?.stringValue = term.note ?? ""
            cell.textField?.font = .systemFont(ofSize: 12)
            cell.textField?.textColor = .tertiaryLabelColor
        }
        cell.toolTip = ([term.text] + term.aliases + [term.note].compactMap { $0 }).joined(separator: "\n")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// Delete / Forward Delete removes the selected terms.
private final class VocabularyTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Term / Sounds like / Note fields for the add and edit sheet.
private final class VocabularyTermEditor: NSView {
    let termField = NSTextField()
    private let aliasesField = NSTextField()
    private let noteField = NSTextField()

    var termText: String { termField.stringValue }
    var aliases: [String] { aliasesField.stringValue.split(separator: ",").map(String.init) }
    var note: String? { noteField.stringValue }

    init(term: VocabularyTerm?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 96))
        termField.placeholderString = "HumanLayer"
        aliasesField.placeholderString = "human lair, humanlair"
        noteField.placeholderString = "Optional, e.g. Dexter's company"
        termField.stringValue = term?.text ?? ""
        aliasesField.stringValue = term?.aliases.joined(separator: ", ") ?? ""
        noteField.stringValue = term?.note ?? ""

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Term"), termField],
            [NSTextField(labelWithString: "Sounds like"), aliasesField],
            [NSTextField(labelWithString: "Note"), noteField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
            termField.widthAnchor.constraint(equalToConstant: 250),
        ])
        termField.nextKeyView = aliasesField
        aliasesField.nextKeyView = noteField
    }

    required init?(coder: NSCoder) { fatalError() }
}
