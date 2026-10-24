import AppKit

/// The "Meetings" pane: record button, a calendar of recorded days, the
/// meetings on the selected day (or search results across all meetings), and
/// the selected meeting's transcript.
final class MeetingsPaneView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    /// Start/stop requests go through AppDelegate (permissions, error UI).
    var onToggleRecording: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Meetings")
    private let subtitleLabel = NSTextField(labelWithString: "Calls and meetings, transcribed on this Mac.")
    private let recordButton = NSButton(title: "Record Meeting", target: nil, action: nil)
    private let settingsButton = NSButton()

    private let sidebar = NSView()
    private let globalSearch = NSSearchField()
    private let calendarView = MeetingCalendarView()
    private let listHeader = NSTextField(labelWithString: "")
    private let listScroll = NSScrollView()
    private let listTable = NSTableView()
    private let listEmptyLabel = NSTextField(wrappingLabelWithString: "")
    private let divider = Theme.makeHairline(vertical: true)
    private let headerLine = Theme.makeHairline()
    let detailView = MeetingDetailView(frame: .zero)

    private enum ListItem {
        case meeting(MeetingSummary)
        case result(MeetingStore.SearchResult)

        var summary: MeetingSummary {
            switch self {
            case .meeting(let summary): return summary
            case .result(let result): return result.summary
            }
        }
    }

    private var items: [ListItem] = []
    private var selectedDay = Calendar.current.startOfDay(for: Date())
    private var selectedMeetingID: UUID?
    private var searchQuery = ""
    private var recordTimer: Timer?
    private var settingsPopover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHeader()
        setupSidebar()
        addSubview(divider)
        addSubview(headerLine)
        addSubview(detailView)

        detailView.onDelete = { [weak self] id in
            MeetingStore.shared.delete(id: id)
            self?.selectedMeetingID = nil
            self?.reloadList()
        }
        detailView.onStopRecording = { [weak self] in self?.onToggleRecording?() }

        MeetingStore.shared.addChangeObserver { [weak self] ids in
            self?.storeChanged(ids)
        }
        MeetingRecorder.shared.addObserver { [weak self] event in
            self?.recorderEvent(event)
        }

        // Open on the most recent meeting's day.
        if let latest = MeetingStore.shared.mostRecent {
            selectedDay = Calendar.current.startOfDay(for: latest.startedAt)
            selectedMeetingID = latest.id
        }
        calendarView.select(day: selectedDay)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupHeader() {
        Theme.styleHeading(titleLabel, subtitleLabel)
        addSubview(titleLabel)
        addSubview(subtitleLabel)

        recordButton.bezelStyle = .rounded
        recordButton.controlSize = .large
        recordButton.imagePosition = .imageLeading
        recordButton.target = self
        recordButton.action = #selector(recordClicked)
        addSubview(recordButton)

        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Meeting settings")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        settingsButton.bezelStyle = .texturedRounded
        settingsButton.showsBorderOnlyWhileMouseInside = true
        settingsButton.toolTip = "Meeting recording settings"
        settingsButton.target = self
        settingsButton.action = #selector(showSettings)
        addSubview(settingsButton)
    }

    private func setupSidebar() {
        addSubview(sidebar)

        globalSearch.placeholderString = "Search all meetings"
        globalSearch.sendsSearchStringImmediately = false
        globalSearch.sendsWholeSearchString = false
        globalSearch.delegate = self
        globalSearch.target = self
        globalSearch.action = #selector(globalSearchChanged)
        sidebar.addSubview(globalSearch)

        calendarView.onSelectDay = { [weak self] day in
            guard let self else { return }
            self.selectedDay = day
            if !self.searchQuery.isEmpty {
                self.globalSearch.stringValue = ""
                self.searchQuery = ""
            }
            self.reloadList(selectFirst: true)
        }
        sidebar.addSubview(calendarView)

        listHeader.font = Theme.Font.sectionHeader
        listHeader.textColor = .tertiaryLabelColor
        sidebar.addSubview(listHeader)

        listTable.headerView = nil
        listTable.backgroundColor = .clear
        listTable.rowHeight = 62
        listTable.intercellSpacing = NSSize(width: 0, height: 2)
        listTable.style = .plain
        listTable.selectionHighlightStyle = .regular
        listTable.dataSource = self
        listTable.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("meeting"))
        column.resizingMask = .autoresizingMask
        listTable.addTableColumn(column)
        listTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        listScroll.documentView = listTable
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        sidebar.addSubview(listScroll)

        listEmptyLabel.font = .systemFont(ofSize: 12)
        listEmptyLabel.textColor = .tertiaryLabelColor
        listEmptyLabel.alignment = .center
        sidebar.addSubview(listEmptyLabel)
    }

    // MARK: - Refresh

    func refresh() {
        calendarView.setMeetingCounts(MeetingStore.shared.meetingCountsByDay())
        updateRecordButton()
        reloadList()
    }

    private func reloadList(selectFirst: Bool = false) {
        if let query = MeetingSearch.normalizedQuery(searchQuery) {
            let results = MeetingStore.shared.search(query)
            items = results.map { .result($0) }
            listHeader.stringValue = "\(results.count) RESULT\(results.count == 1 ? "" : "S")"
            listEmptyLabel.stringValue = "No meetings mention \u{201C}\(query)\u{201D}."
        } else {
            items = MeetingStore.shared.summaries(onDayOf: selectedDay).map { .meeting($0) }
            let formatter = DateFormatter()
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .full
            listHeader.stringValue = formatter.string(from: selectedDay).uppercased()
            listEmptyLabel.stringValue = MeetingStore.shared.summaries.isEmpty
                ? "No meetings yet.\nClick Record Meeting when a call starts. Hearsay transcribes your mic and the call audio locally."
                : "No meetings on this day."
        }
        listEmptyLabel.isHidden = !items.isEmpty
        listTable.reloadData()

        if selectFirst {
            selectedMeetingID = items.first?.summary.id
        }
        if let id = selectedMeetingID, let row = items.firstIndex(where: { $0.summary.id == id }) {
            listTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            listTable.scrollRowToVisible(row)
        } else {
            listTable.deselectAll(nil)
        }
        detailView.show(meetingID: selectedMeetingID, query: searchQuery.isEmpty ? nil : searchQuery)
        needsLayout = true
    }

    private func storeChanged(_ ids: Set<UUID>) {
        calendarView.setMeetingCounts(MeetingStore.shared.meetingCountsByDay())
        // Keep the list's selection; just refresh labels.
        if let query = MeetingSearch.normalizedQuery(searchQuery) {
            items = MeetingStore.shared.search(query).map { .result($0) }
        } else {
            items = MeetingStore.shared.summaries(onDayOf: selectedDay).map { .meeting($0) }
        }
        listEmptyLabel.isHidden = !items.isEmpty
        listTable.reloadData()
        if let id = selectedMeetingID, let row = items.firstIndex(where: { $0.summary.id == id }) {
            listTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        if let selectedMeetingID, ids.isEmpty || ids.contains(selectedMeetingID) {
            detailView.reload()
        }
    }

    private func recorderEvent(_ event: MeetingRecorderEvent) {
        switch event {
        case .started(let id):
            reveal(meetingID: id)
        case .liveUpdated:
            detailView.liveStateChanged()
        case .stopping, .finished:
            updateRecordButton()
            detailView.reload()
        default:
            break
        }
        updateRecordButton()
    }

    /// Select a meeting (and its day), e.g. when recording starts.
    func reveal(meetingID: UUID, query: String? = nil) {
        guard let summary = MeetingStore.shared.summaries.first(where: { $0.id == meetingID }) else { return }
        if query == nil, !searchQuery.isEmpty {
            searchQuery = ""
            globalSearch.stringValue = ""
        }
        selectedDay = Calendar.current.startOfDay(for: summary.startedAt)
        selectedMeetingID = meetingID
        calendarView.select(day: selectedDay)
        calendarView.setMeetingCounts(MeetingStore.shared.meetingCountsByDay())
        reloadList()
        if let query { detailView.show(meetingID: meetingID, query: query) }
    }

    // MARK: - Record button

    private func updateRecordButton() {
        let recorder = MeetingRecorder.shared
        if let live = recorder.live {
            if live.phase == .recording {
                recordButton.title = "Stop  " + MeetingTranscriptFormatter.timestamp(live.elapsed)
                recordButton.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)
                recordButton.bezelColor = .systemRed
                recordButton.contentTintColor = .systemRed
                recordButton.isEnabled = true
            } else {
                recordButton.title = "Finishing…"
                recordButton.image = nil
                recordButton.bezelColor = nil
                recordButton.isEnabled = false
            }
            if recordTimer == nil {
                let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    self?.updateRecordButton()
                }
                RunLoop.main.add(timer, forMode: .common)
                recordTimer = timer
            }
        } else {
            recordTimer?.invalidate()
            recordTimer = nil
            recordButton.title = "Record Meeting"
            recordButton.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
            recordButton.bezelColor = nil
            recordButton.contentTintColor = .systemRed
            recordButton.isEnabled = true
        }
        needsLayout = true
    }

    @objc private func recordClicked() {
        onToggleRecording?()
    }

    // MARK: - Settings popover

    @objc private func showSettings() {
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = NSViewController()
        controller.view = MeetingSettingsView()
        popover.contentViewController = controller
        popover.show(relativeTo: settingsButton.bounds, of: settingsButton, preferredEdge: .maxY)
        settingsPopover = popover
    }

    // MARK: - Search

    @objc private func globalSearchChanged() {
        searchQuery = globalSearch.stringValue
        reloadList(selectFirst: true)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === globalSearch else { return }
        // Search after a short pause instead of on every keystroke.
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(globalSearchChanged), object: nil)
        perform(#selector(globalSearchChanged), with: nil, afterDelay: 0.25)
    }

    func focusGlobalSearch() {
        window?.makeFirstResponder(globalSearch)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "f" {
            detailView.focusSearch()
            return true
        }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "f" {
            focusGlobalSearch()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - List

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: MeetingListCell.identifier, owner: nil) as? MeetingListCell) ?? MeetingListCell()
        let item = items[row]
        switch item {
        case .meeting(let summary):
            cell.configure(summary: summary, showDate: false, snippet: nil, isLive: MeetingRecorder.shared.currentMeetingID == summary.id)
        case .result(let result):
            cell.configure(summary: result.summary, showDate: true, snippet: result.snippet, isLive: MeetingRecorder.shared.currentMeetingID == result.summary.id)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = listTable.selectedRow
        guard row >= 0, row < items.count else { return }
        let id = items[row].summary.id
        guard id != selectedMeetingID else { return }
        selectedMeetingID = id
        detailView.show(meetingID: id, query: searchQuery.isEmpty ? nil : searchQuery)
    }

    // MARK: - Layout

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let padding: CGFloat = 20
        let sidebarWidth: CGFloat = 268

        titleLabel.frame = NSRect(x: padding, y: 0, width: 300, height: 26)
        subtitleLabel.frame = NSRect(x: padding, y: 28, width: 360, height: 16)

        recordButton.sizeToFit()
        let recordWidth = max(150, recordButton.frame.width + 16)
        recordButton.frame = NSRect(x: bounds.width - padding - recordWidth, y: 4, width: recordWidth, height: 32)
        settingsButton.frame = NSRect(x: recordButton.frame.minX - 40, y: 7, width: 32, height: 26)

        let top: CGFloat = 58
        headerLine.frame = NSRect(x: 0, y: top - 1, width: bounds.width, height: 1)
        sidebar.frame = NSRect(x: 0, y: top, width: sidebarWidth, height: bounds.height - top)
        divider.frame = NSRect(x: sidebarWidth, y: top, width: 1, height: bounds.height - top)
        detailView.frame = NSRect(x: sidebarWidth + 1, y: top, width: bounds.width - sidebarWidth - 1, height: bounds.height - top)

        // Sidebar is unflipped; lay out top-down from its height.
        let inner = sidebar.bounds.width - 28
        var y = sidebar.bounds.height - 14
        y -= 24
        globalSearch.frame = NSRect(x: 14, y: y, width: inner, height: 24)
        y -= 10 + MeetingCalendarView.preferredHeight
        calendarView.frame = NSRect(x: 14, y: y, width: inner, height: MeetingCalendarView.preferredHeight)
        y -= 26
        listHeader.frame = NSRect(x: 16, y: y, width: inner, height: 16)
        y -= 6
        listScroll.frame = NSRect(x: 6, y: 0, width: sidebar.bounds.width - 12, height: max(0, y))
        listEmptyLabel.preferredMaxLayoutWidth = inner - 20
        let emptyHeight = listEmptyLabel.fittingSize.height
        listEmptyLabel.frame = NSRect(x: 24, y: max(0, y - emptyHeight - 30), width: inner - 20, height: emptyHeight)
    }
}

// MARK: - List cell

private final class MeetingListCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("MeetingListCell")

    private let timeLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let liveBadge = NSTextField(labelWithString: "● LIVE")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        timeLabel.font = Theme.Font.metaDigits
        timeLabel.textColor = .secondaryLabelColor
        addSubview(timeLabel)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        addSubview(detailLabel)

        liveBadge.font = .systemFont(ofSize: 9.5, weight: .bold)
        liveBadge.textColor = .systemRed
        addSubview(liveBadge)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(summary: MeetingSummary, showDate: Bool, snippet: String?, isLive: Bool) {
        let time = DateFormatter()
        if showDate {
            time.setLocalizedDateFormatFromTemplate("MMM d, h:mm a")
        } else {
            time.timeStyle = .short
        }
        var timeText = time.string(from: summary.startedAt)
        if !showDate, let end = summary.endedAt {
            let endFormatter = DateFormatter()
            endFormatter.timeStyle = .short
            timeText += " – " + endFormatter.string(from: end)
        }
        timeLabel.stringValue = timeText
        titleLabel.stringValue = summary.title

        if let snippet {
            detailLabel.stringValue = snippet
        } else {
            var parts: [String] = []
            if !isLive { parts.append(MeetingTranscriptFormatter.durationText(summary.durationSeconds)) }
            if !summary.speakerNames.isEmpty { parts.append(summary.speakerNames.prefix(3).joined(separator: ", ") + (summary.speakerNames.count > 3 ? " +\(summary.speakerNames.count - 3)" : "")) }
            if summary.status == .interrupted { parts.append("interrupted") }
            if parts.isEmpty { parts.append("No speech yet") }
            detailLabel.stringValue = parts.joined(separator: " · ")
        }
        liveBadge.isHidden = !isLive
        toolTip = summary.preview.isEmpty ? nil : summary.preview
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let x: CGFloat = 10
        let width = bounds.width - x * 2
        liveBadge.sizeToFit()
        liveBadge.frame.origin = NSPoint(x: bounds.width - x - liveBadge.frame.width, y: bounds.height - 22)
        timeLabel.frame = NSRect(x: x, y: bounds.height - 22, width: width - (liveBadge.isHidden ? 0 : liveBadge.frame.width + 6), height: 15)
        titleLabel.frame = NSRect(x: x, y: bounds.height - 40, width: width, height: 18)
        detailLabel.frame = NSRect(x: x, y: bounds.height - 56, width: width, height: 15)
    }
}

// MARK: - Settings

private final class MeetingSettingsView: NSView {
    private let stack = NSStackView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 300))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 340),
        ])

        let heading = NSTextField(labelWithString: "Meeting Recording")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(heading)

        stack.addArrangedSubview(minutesRow(
            label: "Ask if the meeting is over after",
            choices: MeetingSettings.silenceReminderChoices,
            current: MeetingSettings.silenceReminderMinutes,
            offTitle: "Never"
        ) { MeetingSettings.silenceReminderMinutes = $0 })

        stack.addArrangedSubview(minutesRow(
            label: "Stop by itself after",
            choices: MeetingSettings.autoStopChoices,
            current: MeetingSettings.autoStopSilenceMinutes,
            offTitle: "Never"
        ) { MeetingSettings.autoStopSilenceMinutes = $0 })

        let silenceNote = NSTextField(labelWithString: "…of silence on both your mic and the call.")
        silenceNote.font = .systemFont(ofSize: 11)
        silenceNote.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(silenceNote)

        stack.addArrangedSubview(checkbox("Offer to record when a call starts", MeetingSettings.suggestRecordingOnCalls,
                                          tip: "Zoom, Teams, Webex, FaceTime, Slack, and Google Meet in your browser.") {
            MeetingSettings.suggestRecordingOnCalls = $0
            NotificationCenter.default.post(name: .meetingSettingsChanged, object: nil)
        })
        stack.addArrangedSubview(checkbox("Tell speakers on the call apart", MeetingSettings.speakerDetection,
                                          tip: "Runs an on-device diarization model over the call audio (Apple Silicon).") {
            MeetingSettings.speakerDetection = $0
        })
        stack.addArrangedSubview(checkbox("Show words as they're spoken", MeetingSettings.livePreview,
                                          tip: "Re-transcribes the current sentence about once a second (Parakeet and Whisper models).") {
            MeetingSettings.livePreview = $0
        })
        stack.addArrangedSubview(checkbox("Hide call audio picked up by my mic", MeetingSettings.suppressEcho,
                                          tip: "When you use speakers instead of headphones, your mic hears the call. Hearsay drops those duplicate lines.") {
            MeetingSettings.suppressEcho = $0
        })
        stack.addArrangedSubview(checkbox("Keep audio recordings", MeetingSettings.keepAudio,
                                          tip: "Saves compressed audio next to each transcript, needed to re-detect speakers later.") {
            MeetingSettings.keepAudio = $0
        })

        let folder = NSButton(title: "Open Meetings Folder", target: self, action: #selector(openFolder))
        folder.bezelStyle = .inline
        folder.controlSize = .small
        stack.addArrangedSubview(folder)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func minutesRow(label: String, choices: [Int], current: Int, offTitle: String, onChange: @escaping (Int) -> Void) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        let text = NSTextField(labelWithString: label)
        text.font = .systemFont(ofSize: 12.5)
        let popup = ClosurePopUpButton(onChange: { index in onChange(choices[index]) })
        popup.controlSize = .small
        for choice in choices {
            popup.addItem(withTitle: choice == 0 ? offTitle : "\(choice) min")
        }
        popup.selectItem(at: choices.firstIndex(of: current) ?? 0)
        row.addArrangedSubview(text)
        row.addArrangedSubview(popup)
        return row
    }

    private func checkbox(_ title: String, _ value: Bool, tip: String, onChange: @escaping (Bool) -> Void) -> NSView {
        let box = ClosureCheckbox(title: title, onChange: onChange)
        box.state = value ? .on : .off
        box.toolTip = tip
        return box
    }

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: MeetingPaths.rootDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(MeetingPaths.rootDirectory)
    }
}

extension Notification.Name {
    static let meetingSettingsChanged = Notification.Name("HearsayMeetingSettingsChanged")
}

private final class ClosureCheckbox: NSButton {
    private var onChange: ((Bool) -> Void)?

    convenience init(title: String, onChange: @escaping (Bool) -> Void) {
        self.init(checkboxWithTitle: title, target: nil, action: nil)
        self.onChange = onChange
        target = self
        action = #selector(toggled)
        font = .systemFont(ofSize: 12.5)
    }

    @objc private func toggled() { onChange?(state == .on) }
}

private final class ClosurePopUpButton: NSPopUpButton {
    private var onChange: ((Int) -> Void)?

    convenience init(onChange: @escaping (Int) -> Void) {
        self.init(frame: .zero, pullsDown: false)
        self.onChange = onChange
        target = self
        action = #selector(changed)
    }

    @objc private func changed() { onChange?(indexOfSelectedItem) }
}
