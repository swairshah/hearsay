import AppKit
import UniformTypeIdentifiers

/// Right-hand side of the Meetings pane: one meeting's header, toolbar and
/// transcript (as a timeline, a readable document, or per-speaker stats).
final class MeetingDetailView: NSView, NSSearchFieldDelegate, NSTextFieldDelegate {

    enum Mode: Int {
        case transcript
        case reader
        case speakers
    }

    var onDelete: ((UUID) -> Void)?
    var onStopRecording: (() -> Void)?
    var onRedetectSpeakers: ((UUID) -> Void)?

    private(set) var meetingID: UUID?
    private var document: MeetingDocument?
    private var mode: Mode = .transcript
    private var showOriginal = false
    private var query = ""
    private var matchIDs: [UUID] = []
    private var matchIndex = 0
    private var liveTimer: Timer?

    // Header
    private let titleField = NSTextField(string: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let livePill = AdaptiveBackgroundView(color: NSColor.systemRed.withAlphaComponent(0.13), cornerRadius: 11)
    private let liveDot = AdaptiveBackgroundView(color: .systemRed, cornerRadius: 3.5)
    private let liveLabel = NSTextField(labelWithString: "")
    private let micMeter = LevelMeterView(title: "You")
    private let callMeter = LevelMeterView(title: "Call")
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)

    // Toolbar
    private let modeControl = NSSegmentedControl(labels: ["Transcript", "Reader", "Speakers"], trackingMode: .selectOne, target: nil, action: nil)
    private let searchField = NSSearchField()
    private let matchLabel = NSTextField(labelWithString: "")
    private let previousMatchButton = NSButton()
    private let nextMatchButton = NSButton()
    private let copyButton = NSButton()
    private let shareButton = NSButton()
    private let processButton = NSButton()
    private let moreButton = NSButton()
    private let toolbarLine = Theme.makeHairline()

    // Processing banner
    private let processingBar = AdaptiveBackgroundView(color: Theme.wash(0.04))
    private let processingSpinner = NSProgressIndicator()
    private let processingLabel = NSTextField(labelWithString: "")
    private let processingCancel = NSButton(title: "Cancel", target: nil, action: nil)
    private var isProcessing = false

    // Content
    private let transcriptView = MeetingTranscriptView(frame: .zero)
    private let readerView = MeetingReaderView(frame: .zero)
    private let speakersView = MeetingSpeakersView(frame: .zero)
    private let jumpButton = NSButton(title: "Jump to live", target: nil, action: nil)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let bannerLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHeader()
        setupToolbar()
        setupProcessingBar()
        setupContent()
        showEmpty("Select a meeting to read its transcript.")
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        liveTimer?.invalidate()
    }

    // MARK: - Setup

    private func setupHeader() {
        titleField.font = .systemFont(ofSize: 18, weight: .bold)
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.usesSingleLineMode = true
        titleField.placeholderString = "Untitled meeting"
        titleField.toolTip = "Click to rename"
        titleField.delegate = self
        titleField.target = self
        titleField.action = #selector(commitTitle)
        addSubview(titleField)

        metaLabel.font = .systemFont(ofSize: 12)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        addSubview(metaLabel)

        addSubview(livePill)
        livePill.addSubview(liveDot)
        liveLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        liveLabel.textColor = .systemRed
        livePill.addSubview(liveLabel)
        addSubview(micMeter)
        addSubview(callMeter)

        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .regular
        stopButton.bezelColor = .systemRed
        stopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        stopButton.imagePosition = .imageLeading
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        addSubview(stopButton)
    }

    private func setupToolbar() {
        modeControl.selectedSegment = 0
        modeControl.segmentStyle = .rounded
        modeControl.controlSize = .regular
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        addSubview(modeControl)

        searchField.placeholderString = "Search transcript"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)
        addSubview(searchField)

        matchLabel.font = Theme.Font.metaDigits
        matchLabel.textColor = .secondaryLabelColor
        matchLabel.alignment = .right
        addSubview(matchLabel)

        configureIconButton(previousMatchButton, symbol: "chevron.up", tip: "Previous match (⇧↩)", action: #selector(previousMatch))
        configureIconButton(nextMatchButton, symbol: "chevron.down", tip: "Next match (↩)", action: #selector(nextMatch))
        configureIconButton(copyButton, symbol: "doc.on.doc", tip: "Copy transcript", action: #selector(copyTranscript))
        configureIconButton(shareButton, symbol: "square.and.arrow.up", tip: "Share or export Markdown", action: #selector(showShareMenu))
        configureIconButton(processButton, symbol: "wand.and.stars", tip: "Clean up the transcript", action: #selector(showProcessMenu))
        configureIconButton(moreButton, symbol: "ellipsis.circle", tip: "More", action: #selector(showMoreMenu))

        addSubview(toolbarLine)
    }

    private func configureIconButton(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.showsBorderOnlyWhileMouseInside = true
        button.toolTip = tip
        button.target = self
        button.action = action
        addSubview(button)
    }

    private func setupProcessingBar() {
        addSubview(processingBar)
        processingSpinner.style = .spinning
        processingSpinner.controlSize = .small
        processingBar.addSubview(processingSpinner)
        processingLabel.font = .systemFont(ofSize: 12)
        processingLabel.textColor = .secondaryLabelColor
        processingBar.addSubview(processingLabel)
        processingCancel.bezelStyle = .inline
        processingCancel.controlSize = .small
        processingCancel.target = self
        processingCancel.action = #selector(cancelProcessing)
        processingBar.addSubview(processingCancel)
        processingBar.isHidden = true
    }

    private func setupContent() {
        addSubview(transcriptView)
        addSubview(readerView)
        addSubview(speakersView)
        readerView.isHidden = true
        speakersView.isHidden = true

        transcriptView.onEditSegment = { [weak self] id in self?.editSegment(id) }
        transcriptView.onShowMenu = { [weak self] id, menu in self?.populateSegmentMenu(menu, segmentID: id) }
        transcriptView.onFollowChanged = { [weak self] following in
            guard let self else { return }
            self.jumpButton.isHidden = following || self.document?.isLive != true || self.mode != .transcript
        }

        speakersView.onRename = { [weak self] speakerID, name in self?.renameSpeaker(speakerID, to: name) }
        speakersView.onMerge = { [weak self] from, into in self?.mergeSpeaker(from, into: into) }

        jumpButton.bezelStyle = .rounded
        jumpButton.controlSize = .small
        jumpButton.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)
        jumpButton.imagePosition = .imageLeading
        jumpButton.target = self
        jumpButton.action = #selector(jumpToLive)
        jumpButton.isHidden = true
        addSubview(jumpButton)

        bannerLabel.font = .systemFont(ofSize: 11.5)
        bannerLabel.textColor = .secondaryLabelColor
        bannerLabel.isHidden = true
        addSubview(bannerLabel)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        addSubview(emptyLabel)
    }

    // MARK: - Public

    func show(meetingID: UUID?, query initialQuery: String? = nil) {
        let changed = meetingID != self.meetingID
        self.meetingID = meetingID
        if changed {
            showOriginal = false
            matchIndex = 0
            query = initialQuery ?? ""
            searchField.stringValue = query
            window?.makeFirstResponder(nil)
        } else if let initialQuery {
            query = initialQuery
            searchField.stringValue = initialQuery
        }
        reload(scrollToBottom: changed)
        if changed, !query.isEmpty {
            DispatchQueue.main.async { self.focusCurrentMatch() }
        }
    }

    /// Re-read the meeting from the store (it changed) and redraw.
    func reload(scrollToBottom: Bool = false) {
        guard let meetingID, let document = MeetingStore.shared.document(id: meetingID) else {
            self.document = nil
            showEmpty(meetingID == nil ? "Select a meeting to read its transcript." : "This meeting is no longer available.")
            return
        }
        self.document = document
        emptyLabel.isHidden = true
        setChromeHidden(false)

        if titleField.currentEditor() == nil {
            titleField.stringValue = document.title
        }
        updateMeta()
        updateLiveChrome()
        updateBanner()
        recomputeMatches()

        switch mode {
        case .transcript:
            transcriptView.setRows(buildRows(document), query: query, currentMatch: currentMatchID,
                                   scrollToBottom: scrollToBottom && document.isLive, follow: document.isLive)
            jumpButton.isHidden = transcriptView.isFollowingLive || !document.isLive
        case .reader:
            readerView.show(document: document, original: showOriginal, query: query)
        case .speakers:
            speakersView.show(document: document, speakerDetection: liveSpeakerDetection)
        }
        needsLayout = true
    }

    /// Live levels/partials changed — cheaper than a full reload when nothing else did.
    func liveStateChanged() {
        guard document?.isLive == true || MeetingRecorder.shared.currentMeetingID == meetingID else { return }
        updateLiveChrome()
        if mode == .transcript, let document {
            transcriptView.setRows(buildRows(document), query: query, currentMatch: currentMatchID,
                                   scrollToBottom: false, follow: document.isLive)
        }
    }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    // MARK: - Rows

    private func buildRows(_ document: MeetingDocument) -> [MeetingTranscriptRow] {
        var rows: [MeetingTranscriptRow] = []
        var previous: MeetingSegment?
        for segment in document.visibleSegments.sorted(by: { $0.start < $1.start }) {
            let text = showOriginal ? segment.originalText : segment.text
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let speaker = document.speaker(id: segment.speakerID)
            let header = previous == nil
                || previous?.speakerID != segment.speakerID
                || segment.start - (previous?.end ?? 0) > MeetingTranscriptFormatter.turnMergeGap
            rows.append(MeetingTranscriptRow(
                kind: .segment(segment),
                speakerName: speaker?.name ?? segment.speakerID,
                speakerColor: MeetingSpeakerPalette.color(for: speaker),
                showsHeader: header,
                start: segment.start,
                text: text,
                isModified: !showOriginal && (segment.text != segment.originalText || segment.edited == true)
            ))
            previous = segment
        }

        if let live = MeetingRecorder.shared.live, live.meetingID == document.id {
            let partials = live.partials.sorted { $0.value.start < $1.value.start }
            for (channel, partial) in partials {
                let speaker = channel == .microphone ? document.speaker(id: MeetingSpeaker.meID) : document.speaker(id: MeetingSpeaker.themID)
                rows.append(MeetingTranscriptRow(
                    kind: .partial(channel: channel, text: partial.text, start: partial.start),
                    speakerName: channel == .microphone ? (speaker?.name ?? "You") : "Speaking…",
                    speakerColor: MeetingSpeakerPalette.color(for: speaker),
                    showsHeader: true,
                    start: partial.start,
                    text: partial.text,
                    isModified: false
                ))
            }
        }
        return rows
    }

    // MARK: - Header

    private var liveSpeakerDetection: MeetingLiveState.SpeakerDetection? {
        guard let live = MeetingRecorder.shared.live, live.meetingID == meetingID else { return nil }
        return live.speakerDetection
    }

    private func updateMeta() {
        guard let document else { return }
        let day = DateFormatter()
        day.doesRelativeDateFormatting = true
        day.dateStyle = .medium
        day.timeStyle = .none
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short

        var parts = [day.string(from: document.startedAt)]
        if let end = document.endedAt {
            parts.append("\(time.string(from: document.startedAt)) – \(time.string(from: end))")
            parts.append(MeetingTranscriptFormatter.durationText(document.duration()))
        } else {
            parts.append("Started \(time.string(from: document.startedAt))")
        }
        let speakers = document.activeSpeakers.count
        if speakers > 0 { parts.append("\(speakers) speaker\(speakers == 1 ? "" : "s")") }
        if let source = document.source { parts.append(source) }
        switch document.status {
        case .processing: parts.append("Finishing…")
        case .interrupted: parts.append("Interrupted")
        default: break
        }
        metaLabel.stringValue = parts.joined(separator: "  ·  ")
    }

    private func updateLiveChrome() {
        let live = MeetingRecorder.shared.live
        let isThisLive = live != nil && live?.meetingID == meetingID && document?.isLive == true
        let isFinishing = live?.meetingID == meetingID && live?.phase == .finishing

        // Start/stop lives in the pane header; here we only show status.
        stopButton.isHidden = true
        for view in [livePill, micMeter, callMeter] as [NSView] {
            view.isHidden = !isThisLive && !(isFinishing && view === livePill)
        }

        if let live, isThisLive {
            liveLabel.stringValue = "REC  " + MeetingTranscriptFormatter.timestamp(live.elapsed)
            micMeter.level = live.micLevel
            micMeter.isActive = live.micSpeaking
            callMeter.level = live.systemLevel
            callMeter.isActive = live.systemSpeaking
            callMeter.isHidden = !live.systemAudioAvailable
            if liveTimer == nil {
                let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    self?.updateLiveChrome()
                }
                RunLoop.main.add(timer, forMode: .common)
                liveTimer = timer
            }
        } else {
            if isFinishing { liveLabel.stringValue = "Finishing…" }
            liveTimer?.invalidate()
            liveTimer = nil
        }
        needsLayout = true
    }

    private func updateBanner() {
        var messages: [String] = []
        if let live = MeetingRecorder.shared.live, live.meetingID == meetingID, live.phase == .recording {
            if !live.systemAudioAvailable {
                messages.append("Call audio isn't being captured (needs macOS 14.2 and System Audio Recording permission). Only your microphone is transcribed.")
            }
            if case .loading = live.speakerDetection {
                messages.append("Loading speaker detection… call audio is labelled \u{201C}Others\u{201D} until it's ready.")
            }
        } else if document?.status == .interrupted {
            messages.append("Recording was interrupted (Hearsay quit or crashed). Everything transcribed up to that point was kept.")
        }
        if showOriginal {
            messages.append("Showing the original speech-to-text output. Edits and clean-up passes are hidden, not lost.")
        }
        bannerLabel.stringValue = messages.joined(separator: "  ")
        bannerLabel.isHidden = messages.isEmpty
    }

    @objc private func commitTitle() {
        guard let meetingID else { return }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            titleField.stringValue = document?.title ?? ""
            return
        }
        guard title != document?.title else { return }
        MeetingStore.shared.modify(id: meetingID) { $0.title = title }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === titleField {
            commitTitle()
        }
    }

    @objc private func stopClicked() {
        onStopRecording?()
    }

    // MARK: - Modes & search

    @objc private func modeChanged() {
        mode = Mode(rawValue: modeControl.selectedSegment) ?? .transcript
        transcriptView.isHidden = mode != .transcript
        readerView.isHidden = mode != .reader
        speakersView.isHidden = mode != .speakers
        let searchable = mode != .speakers
        searchField.isEnabled = searchable
        reload()
        if mode == .reader { readerView.scrollToFirstMatch(query) }
    }

    func setMode(_ mode: Mode) {
        modeControl.selectedSegment = mode.rawValue
        modeChanged()
    }

    @objc private func searchChanged() {
        query = searchField.stringValue
        matchIndex = 0
        reload()
        focusCurrentMatch()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                previousMatch()
            } else {
                nextMatch()
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            searchField.stringValue = ""
            searchChanged()
            return true
        }
        return false
    }

    private var currentMatchID: UUID? {
        matchIDs.isEmpty ? nil : matchIDs[min(matchIndex, matchIDs.count - 1)]
    }

    private func recomputeMatches() {
        guard let document, MeetingSearch.normalizedQuery(query) != nil else {
            matchIDs = []
            matchLabel.stringValue = ""
            previousMatchButton.isEnabled = false
            nextMatchButton.isEnabled = false
            return
        }
        matchIDs = MeetingSearch.hits(in: document, query: query, original: showOriginal).map(\.segmentID)
        if matchIndex >= matchIDs.count { matchIndex = 0 }
        matchLabel.stringValue = matchIDs.isEmpty ? "No matches" : "\(matchIndex + 1) of \(matchIDs.count)"
        previousMatchButton.isEnabled = matchIDs.count > 1
        nextMatchButton.isEnabled = matchIDs.count > 1
    }

    @objc private func nextMatch() {
        guard !matchIDs.isEmpty else { return }
        matchIndex = (matchIndex + 1) % matchIDs.count
        reload()
        focusCurrentMatch()
    }

    @objc private func previousMatch() {
        guard !matchIDs.isEmpty else { return }
        matchIndex = (matchIndex - 1 + matchIDs.count) % matchIDs.count
        reload()
        focusCurrentMatch()
    }

    private func focusCurrentMatch() {
        if mode == .reader {
            readerView.scrollToFirstMatch(query)
        } else if let id = currentMatchID {
            transcriptView.scrollTo(segmentID: id)
        }
    }

    @objc private func jumpToLive() {
        transcriptView.scrollToEnd()
        jumpButton.isHidden = true
    }

    // MARK: - Copy & share

    @objc private func copyTranscript() {
        guard let document else { return }
        let text = MeetingTranscriptFormatter.plainText(for: document, original: showOriginal)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flashCopied(copyButton)
    }

    private func flashCopied(_ button: NSButton) {
        let original = button.image
        button.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        button.contentTintColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            button.image = original
            button.contentTintColor = nil
        }
    }

    private func markdown() -> String? {
        guard let document else { return nil }
        return MeetingTranscriptFormatter.markdown(for: document, original: showOriginal)
    }

    /// Writes the Markdown to a temp file with a friendly name (for sharing).
    private func markdownFileForSharing() -> URL? {
        guard let document, let markdown = markdown() else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HearsayShare", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(MeetingTranscriptFormatter.exportFileName(for: document))
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    @objc private func showShareMenu() {
        let menu = NSMenu()
        menu.addItem(item("Share Markdown…", symbol: "square.and.arrow.up", action: #selector(shareMarkdown)))
        menu.addItem(item("Export Markdown…", symbol: "arrow.down.doc", action: #selector(exportMarkdown)))
        menu.addItem(item("Copy as Markdown", symbol: "doc.richtext", action: #selector(copyMarkdown)))
        menu.addItem(.separator())
        menu.addItem(item("Show in Finder", symbol: "folder", action: #selector(revealInFinder)))
        menu.addItem(item("Copy CLI Command", symbol: "terminal", action: #selector(copyCLICommand)))
        popUp(menu, from: shareButton)
    }

    @objc private func shareMarkdown() {
        guard let url = markdownFileForSharing() else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: shareButton.bounds, of: shareButton, preferredEdge: .minY)
    }

    @objc private func exportMarkdown() {
        guard let document, let markdown = markdown(), let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MeetingTranscriptFormatter.exportFileName(for: document)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @objc private func copyMarkdown() {
        guard let markdown = markdown() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        flashCopied(shareButton)
    }

    @objc private func revealInFinder() {
        guard let meetingID else { return }
        NSWorkspace.shared.activateFileViewerSelecting([MeetingPaths.markdownURL(for: meetingID)])
    }

    @objc private func copyCLICommand() {
        guard let document else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("hearsay meetings show \(document.shortID)", forType: .string)
        flashCopied(shareButton)
    }

    // MARK: - Post-processing

    @objc private func showProcessMenu() {
        guard let meetingID else { return }
        let processor = MeetingPostProcessor.shared
        let menu = NSMenu()
        let busy = isProcessing || isBeingRecorded

        let cleanup = item("Clean Up Filler Words", symbol: "sparkles", action: #selector(runCleanupPass))
        cleanup.isEnabled = !busy
        cleanup.toolTip = "Applies your Cleanup rules and Replacements to every utterance."
        menu.addItem(cleanup)

        let llm = item("Polish with Local LLM…", symbol: "wand.and.stars", action: #selector(runLLMPass))
        llm.isEnabled = !busy && processor.isLLMAvailable
        llm.toolTip = processor.isLLMAvailable
            ? "Rewrites each utterance with the on-device post-processing model."
            : "Download a model in Post Processing to enable this."
        menu.addItem(llm)

        menu.addItem(.separator())
        let undo = item("Undo Last Pass", symbol: "arrow.uturn.backward", action: #selector(undoPass))
        undo.isEnabled = !busy && processor.canUndo(meetingID)
        menu.addItem(undo)

        let revert = item("Restore Original Transcript", symbol: "clock.arrow.circlepath", action: #selector(revertAll))
        revert.isEnabled = !busy && (document?.hasProcessedText == true || document?.segments.contains { $0.edited == true } == true)
        menu.addItem(revert)

        menu.addItem(.separator())
        let original = item("Show Original Text", symbol: nil, action: #selector(toggleOriginal))
        original.state = showOriginal ? .on : .off
        menu.addItem(original)

        if let passes = document?.processingPasses, let last = passes.last {
            menu.addItem(.separator())
            let formatter = RelativeDateTimeFormatter()
            let label: String
            switch last.kind {
            case .cleanup: label = "Clean-up"
            case .llm: label = "LLM polish"
            case .revert: label = "Restore"
            }
            let info = NSMenuItem(title: "Last: \(label), \(formatter.localizedString(for: last.date, relativeTo: Date()))", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        popUp(menu, from: processButton)
    }

    @objc private func runCleanupPass() {
        run(.cleanup, label: "Cleaning up filler words…")
    }

    @objc private func runLLMPass() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Polish with Local LLM"
        alert.informativeText = "Each utterance is rewritten on this Mac using the prompt below. Your hand edits are kept, and you can undo the pass or restore the original at any time."
        alert.addButton(withTitle: "Polish")
        alert.addButton(withTitle: "Cancel")

        let editor = PromptEditorAccessory(prompt: MeetingPostProcessor.llmPrompt)
        alert.accessoryView = editor
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let prompt = editor.prompt
            MeetingPostProcessor.llmPrompt = prompt
            self?.run(.llm(prompt: prompt), label: "Polishing with the local LLM…")
        }
    }

    private func run(_ pass: MeetingPostProcessor.Pass, label: String) {
        guard let meetingID else { return }
        setProcessing(true, label: label)
        MeetingPostProcessor.shared.run(pass, on: meetingID, progress: { [weak self] done, total in
            guard total > 0 else { return }
            self?.processingLabel.stringValue = "\(label)  \(done) of \(total)"
        }, completion: { [weak self] result in
            guard let self else { return }
            self.setProcessing(false, label: "")
            switch result {
            case .success(let changed):
                self.showToast(changed == 0 ? "Nothing needed changing" : "Updated \(changed) utterance\(changed == 1 ? "" : "s"). Undo is in the wand menu.")
            case .failure(let error):
                self.showToast(error.localizedDescription)
            }
            self.reload()
        })
    }

    @objc private func cancelProcessing() {
        MeetingPostProcessor.shared.cancel()
        processingLabel.stringValue = "Stopping…"
    }

    @objc private func undoPass() {
        guard let meetingID else { return }
        MeetingPostProcessor.shared.undoLastPass(meetingID)
        reload()
    }

    @objc private func revertAll() {
        guard let meetingID, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Restore the original transcript?"
        alert.informativeText = "Every utterance goes back to the speech model's output, including ones you edited by hand. You can undo this once."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MeetingPostProcessor.shared.revertToOriginal(meetingID)
            self?.reload()
        }
    }

    @objc private func toggleOriginal() {
        showOriginal.toggle()
        reload()
    }

    private func setProcessing(_ processing: Bool, label: String) {
        isProcessing = processing
        processingBar.isHidden = !processing
        processingLabel.stringValue = label
        if processing {
            processingSpinner.startAnimation(nil)
        } else {
            processingSpinner.stopAnimation(nil)
        }
        needsLayout = true
    }

    // MARK: - More menu

    @objc private func showMoreMenu() {
        let menu = NSMenu()
        let canRedetect = document?.audio?.system != nil && MeetingDiarizer.isSupported && !isBeingRecorded
        let redetect = item("Re-detect Speakers", symbol: "person.2.wave.2", action: #selector(redetectSpeakers))
        redetect.isEnabled = canRedetect && !isProcessing
        redetect.toolTip = canRedetect ? "Run speaker detection again over the saved call audio." : "Needs saved call audio."
        menu.addItem(redetect)
        menu.addItem(.separator())
        let delete = item("Delete Meeting…", symbol: "trash", action: #selector(deleteMeeting))
        delete.isEnabled = !isBeingRecorded
        delete.toolTip = isBeingRecorded ? "Wait until recording has finished." : nil
        menu.addItem(delete)
        popUp(menu, from: moreButton)
    }

    @objc private func redetectSpeakers() {
        guard let meetingID else { return }
        setProcessing(true, label: "Detecting speakers…")
        MeetingSpeakerTools.redetectSpeakers(meetingID: meetingID) { [weak self] result in
            self?.setProcessing(false, label: "")
            switch result {
            case .success(let count):
                self?.showToast("Found \(count) speaker\(count == 1 ? "" : "s") on the call.")
            case .failure(let error):
                self?.showToast(error.localizedDescription)
            }
            self?.reload()
        }
    }

    @objc private func deleteMeeting() {
        guard let meetingID, let document, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(document.title)\u{201D}?"
        alert.informativeText = "The transcript and its audio are removed from this Mac. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.onDelete?(meetingID)
        }
    }

    // MARK: - Segment actions

    private func populateSegmentMenu(_ menu: NSMenu, segmentID: UUID) {
        guard let document, let segment = document.segments.first(where: { $0.id == segmentID }) else { return }

        menu.addItem(closureItem("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(segment.text, forType: .string)
        })
        menu.addItem(closureItem("Copy with Speaker and Time") {
            let line = "[\(MeetingTranscriptFormatter.timestamp(segment.start))] \(document.speakerName(for: segment)): \(segment.text)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(line, forType: .string)
        })
        menu.addItem(closureItem("Edit Text…") { [weak self] in self?.editSegment(segmentID) })
        menu.addItem(.separator())

        let speakerItem = NSMenuItem(title: "Speaker", action: nil, keyEquivalent: "")
        let speakerMenu = NSMenu()
        for speaker in document.speakers where speaker.id != MeetingSpeaker.themID || segment.speakerID == MeetingSpeaker.themID {
            let entry = closureItem(speaker.name) { [weak self] in self?.assignSpeaker(speaker.id, to: segmentID) }
            entry.state = speaker.id == segment.speakerID ? .on : .off
            speakerMenu.addItem(entry)
        }
        speakerMenu.addItem(.separator())
        speakerMenu.addItem(closureItem("New Speaker…") { [weak self] in self?.createSpeaker(for: segmentID) })
        speakerItem.submenu = speakerMenu
        menu.addItem(speakerItem)

        let name = document.speakerName(for: segment)
        menu.addItem(closureItem("Rename \u{201C}\(name)\u{201D}…") { [weak self] in
            self?.promptRename(speakerID: segment.speakerID, current: name)
        })
        menu.addItem(.separator())

        let restore = closureItem("Restore Original Text") { [weak self] in
            guard let self, let meetingID = self.meetingID else { return }
            MeetingStore.shared.modify(id: meetingID) { doc in
                guard let index = doc.segments.firstIndex(where: { $0.id == segmentID }) else { return }
                doc.segments[index].text = doc.segments[index].originalText
                doc.segments[index].edited = nil
            }
        }
        restore.isEnabled = segment.text != segment.originalText
        menu.addItem(restore)
        menu.addItem(closureItem("Remove from Transcript") { [weak self] in
            guard let meetingID = self?.meetingID else { return }
            MeetingStore.shared.modify(id: meetingID) { doc in
                guard let index = doc.segments.firstIndex(where: { $0.id == segmentID }) else { return }
                doc.segments[index].suppressed = true
            }
        })
    }

    private func editSegment(_ segmentID: UUID) {
        guard let document, let segment = document.segments.first(where: { $0.id == segmentID }), let window else { return }
        let alert = NSAlert()
        alert.messageText = "Edit \(document.speakerName(for: segment)) at \(MeetingTranscriptFormatter.timestamp(segment.start))"
        alert.informativeText = segment.text == segment.originalText
            ? "Fix what the speech model misheard."
            : "Original: \u{201C}\(segment.originalText)\u{201D}"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let editor = PromptEditorAccessory(prompt: segment.text, height: 120, showsReset: false)
        alert.accessoryView = editor
        alert.window.initialFirstResponder = editor.textView
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let meetingID = self?.meetingID else { return }
            let text = editor.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            MeetingStore.shared.modify(id: meetingID) { doc in
                guard let index = doc.segments.firstIndex(where: { $0.id == segmentID }) else { return }
                doc.segments[index].text = text.isEmpty ? doc.segments[index].originalText : text
                doc.segments[index].edited = text.isEmpty ? nil : true
            }
        }
    }

    private func assignSpeaker(_ speakerID: String, to segmentID: UUID) {
        guard let meetingID else { return }
        MeetingStore.shared.modify(id: meetingID) { doc in
            guard let index = doc.segments.firstIndex(where: { $0.id == segmentID }) else { return }
            doc.segments[index].speakerID = speakerID
            doc.segments[index].manualSpeaker = true
        }
    }

    private func createSpeaker(for segmentID: UUID) {
        promptForName(title: "New speaker", current: "") { [weak self] name in
            guard let meetingID = self?.meetingID else { return }
            MeetingStore.shared.modify(id: meetingID) { doc in
                let id = "p\(UUID().uuidString.prefix(6).lowercased())"
                let colorIndex = (doc.speakers.map(\.colorIndex).max() ?? 1) + 1
                doc.speakers.append(MeetingSpeaker(id: id, name: name, kind: .remote, colorIndex: colorIndex))
                if let index = doc.segments.firstIndex(where: { $0.id == segmentID }) {
                    doc.segments[index].speakerID = id
                    doc.segments[index].manualSpeaker = true
                }
            }
        }
    }

    private func promptRename(speakerID: String, current: String) {
        promptForName(title: "Rename speaker", current: current) { [weak self] name in
            self?.renameSpeaker(speakerID, to: name)
        }
    }

    private func renameSpeaker(_ speakerID: String, to name: String) {
        guard let meetingID else { return }
        MeetingStore.shared.modify(id: meetingID) { doc in
            guard let index = doc.speakers.firstIndex(where: { $0.id == speakerID }) else { return }
            doc.speakers[index].name = name
        }
    }

    private func mergeSpeaker(_ source: String, into target: String) {
        guard let meetingID else { return }
        MeetingStore.shared.modify(id: meetingID) { doc in
            for index in doc.segments.indices where doc.segments[index].speakerID == source {
                doc.segments[index].speakerID = target
                doc.segments[index].manualSpeaker = true
            }
        }
    }

    private func promptForName(title: String, current: String, completion: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            completion(name)
        }
    }

    // MARK: - Helpers

    /// Recording or still finishing: the recorder is writing this meeting.
    private var isBeingRecorded: Bool {
        meetingID != nil && MeetingRecorder.shared.currentMeetingID == meetingID
    }

    private func item(_ title: String, symbol: String?, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    private func closureItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: action)
        return item
    }

    private func popUp(_ menu: NSMenu, from button: NSButton) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func showToast(_ message: String) {
        let toast = ToastView(message: message)
        addSubview(toast)
        let size = toast.fittingSize
        toast.frame = NSRect(x: (bounds.width - size.width) / 2, y: 18, width: size.width, height: size.height)
        toast.present()
    }

    private func showEmpty(_ message: String) {
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
        setChromeHidden(true)
        liveTimer?.invalidate()
        liveTimer = nil
        needsLayout = true
    }

    private func setChromeHidden(_ hidden: Bool) {
        let chrome: [NSView] = [titleField, metaLabel, modeControl, searchField, matchLabel, previousMatchButton,
                                nextMatchButton, copyButton, shareButton, processButton, moreButton, toolbarLine,
                                transcriptView, readerView, speakersView]
        for view in chrome {
            if hidden {
                view.isHidden = true
            } else if view === transcriptView {
                view.isHidden = mode != .transcript
            } else if view === readerView {
                view.isHidden = mode != .reader
            } else if view === speakersView {
                view.isHidden = mode != .speakers
            } else {
                view.isHidden = false
            }
        }
        if hidden {
            for view in [livePill, micMeter, callMeter, stopButton, jumpButton, bannerLabel, processingBar] as [NSView] {
                view.isHidden = true
            }
        }
    }

    // MARK: - Layout

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let padding: CGFloat = 22
        let width = bounds.width
        var y: CGFloat = 12

        // Live controls sit to the right of the title.
        var rightEdge = width - padding
        if !micMeter.isHidden {
            callMeter.frame = NSRect(x: rightEdge - 46, y: y + 4, width: 46, height: 20)
            if !callMeter.isHidden { rightEdge = callMeter.frame.minX - 6 }
            micMeter.frame = NSRect(x: rightEdge - 46, y: y + 4, width: 46, height: 20)
            rightEdge = micMeter.frame.minX - 10
        }
        if !livePill.isHidden {
            liveLabel.sizeToFit()
            let pillWidth = liveLabel.frame.width + 28
            livePill.frame = NSRect(x: rightEdge - pillWidth, y: y + 3, width: pillWidth, height: 22)
            liveDot.frame = NSRect(x: 9, y: 7.5, width: 7, height: 7)
            liveLabel.frame.origin = NSPoint(x: 20, y: (22 - liveLabel.frame.height) / 2)
            rightEdge = livePill.frame.minX - 10
        }

        titleField.frame = NSRect(x: padding - 2, y: y, width: max(80, rightEdge - padding), height: 28)
        y += 30
        metaLabel.frame = NSRect(x: padding, y: y, width: width - padding * 2, height: 16)
        y += 26

        // Toolbar: [mode]  [search][n of m][↑][↓]  ……  [copy][share][wand][…]
        modeControl.sizeToFit()
        modeControl.frame.origin = NSPoint(x: padding, y: y)
        let iconSize = NSSize(width: 30, height: 26)
        var x = width - padding
        for button in [moreButton, processButton, shareButton, copyButton] {
            x -= iconSize.width
            button.frame = NSRect(origin: NSPoint(x: x, y: y - 1), size: iconSize)
            x -= 2
        }
        x -= 10
        let navWidth: CGFloat = 22
        nextMatchButton.frame = NSRect(x: x - navWidth, y: y, width: navWidth, height: 24)
        previousMatchButton.frame = NSRect(x: nextMatchButton.frame.minX - navWidth, y: y, width: navWidth, height: 24)
        matchLabel.sizeToFit()
        let matchWidth = matchLabel.stringValue.isEmpty ? 0 : matchLabel.frame.width + 6
        matchLabel.frame = NSRect(x: previousMatchButton.frame.minX - matchWidth, y: y + 4, width: matchWidth, height: 16)
        let searchMaxX = matchLabel.frame.minX - 4
        let searchMinX = modeControl.frame.maxX + 14
        let searchWidth = min(240, max(110, searchMaxX - searchMinX))
        searchField.frame = NSRect(x: searchMaxX - searchWidth, y: y, width: searchWidth, height: 24)
        y += 34

        toolbarLine.frame = NSRect(x: 0, y: y, width: width, height: 1)
        y += 1

        if !processingBar.isHidden {
            processingBar.frame = NSRect(x: 0, y: y, width: width, height: 32)
            processingSpinner.frame = NSRect(x: padding, y: 8, width: 16, height: 16)
            processingCancel.sizeToFit()
            processingCancel.frame.origin = NSPoint(x: width - padding - processingCancel.frame.width, y: (32 - processingCancel.frame.height) / 2)
            processingLabel.frame = NSRect(x: padding + 24, y: 8, width: processingCancel.frame.minX - padding - 32, height: 16)
            y += 32
        }

        if !bannerLabel.isHidden {
            bannerLabel.preferredMaxLayoutWidth = width - padding * 2
            let height = bannerLabel.fittingSize.height
            bannerLabel.frame = NSRect(x: padding, y: y + 8, width: width - padding * 2, height: height)
            y += height + 12
        }

        let contentFrame = NSRect(x: 0, y: y, width: width, height: max(0, bounds.height - y))
        transcriptView.frame = contentFrame
        readerView.frame = contentFrame
        speakersView.frame = contentFrame

        jumpButton.sizeToFit()
        jumpButton.frame.size.width += 12
        jumpButton.frame.origin = NSPoint(x: (width - jumpButton.frame.width) / 2, y: bounds.height - jumpButton.frame.height - 16)

        emptyLabel.preferredMaxLayoutWidth = min(360, width - 40)
        let emptySize = emptyLabel.fittingSize
        emptyLabel.frame = NSRect(x: (width - emptySize.width) / 2, y: bounds.height / 2 - emptySize.height / 2 - 20, width: emptySize.width, height: emptySize.height)
    }
}

// MARK: - Small views

/// Five-bar input level meter with a caption ("You", "Call").
final class LevelMeterView: NSView {
    var level: Float = 0 { didSet { needsDisplay = true } }
    var isActive = false { didSet { needsDisplay = true } }
    private let title: String

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        toolTip = "\(title) input level"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: isActive ? NSColor.labelColor : NSColor.tertiaryLabelColor,
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: 0, y: (bounds.height - size.height) / 2), withAttributes: attributes)

        // RMS → 0…1 over roughly -50…-10 dBFS.
        let db = 20 * log10(max(level, 0.000_01))
        let normalized = CGFloat(max(0, min(1, (db + 50) / 40)))
        let bars = 5
        let barWidth: CGFloat = 3
        let gap: CGFloat = 2
        let startX = bounds.width - CGFloat(bars) * (barWidth + gap) + gap
        for index in 0..<bars {
            let threshold = CGFloat(index + 1) / CGFloat(bars)
            let height = 4 + CGFloat(index) * 2.5
            let rect = NSRect(x: startX + CGFloat(index) * (barWidth + gap), y: (bounds.height - height) / 2, width: barWidth, height: height)
            let lit = normalized >= threshold - 0.1
            (lit ? (isActive ? NSColor.systemGreen : NSColor.secondaryLabelColor) : Theme.wash(0.12)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
    }
}

/// Multi-line text editor used as an NSAlert accessory (LLM prompt, segment text).
final class PromptEditorAccessory: NSView {
    let textView = NSTextView()
    private let defaultPrompt: String?

    var prompt: String { textView.string }

    init(prompt: String, height: CGFloat = 200, showsReset: Bool = true) {
        defaultPrompt = showsReset ? MeetingPostProcessor.defaultLLMPrompt : nil
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: height + (showsReset ? 28 : 0)))

        let scroll = NSScrollView(frame: NSRect(x: 0, y: showsReset ? 28 : 0, width: 460, height: height))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.frame = NSRect(x: 0, y: 0, width: 440, height: height)
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 12.5)
        textView.string = prompt
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.allowsUndo = true
        scroll.documentView = textView
        addSubview(scroll)

        if showsReset {
            let reset = NSButton(title: "Reset to Default", target: self, action: #selector(resetPrompt))
            reset.bezelStyle = .inline
            reset.controlSize = .small
            reset.sizeToFit()
            reset.frame.origin = NSPoint(x: 0, y: 2)
            addSubview(reset)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func resetPrompt() {
        if let defaultPrompt { textView.string = defaultPrompt }
    }
}

/// Menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// Brief confirmation that fades out by itself.
final class ToastView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(message: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        label.stringValue = message
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        let size = label.fittingSize
        return NSSize(width: min(size.width + 28, 520), height: size.height + 14)
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 14, dy: 7)
    }

    func present() {
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; self?.animator().alphaValue = 0 }) {
                self?.removeFromSuperview()
            }
        }
    }
}
