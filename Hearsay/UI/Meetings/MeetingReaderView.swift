import AppKit

/// Document-style reading view: one paragraph per speaker turn, freely
/// selectable, with search matches highlighted.
final class MeetingReaderView: NSView {

    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 26, height: 20)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        textView.frame.size.width = scrollView.contentSize.width
    }

    func show(document: MeetingDocument, original: Bool, query: String) {
        let output = NSMutableAttributedString()
        let body = NSMutableParagraphStyle()
        body.lineSpacing = 4
        body.paragraphSpacing = 14
        let header = NSMutableParagraphStyle()
        header.paragraphSpacingBefore = 4
        header.paragraphSpacing = 3

        let turns = MeetingTranscriptFormatter.turns(for: document, original: original)
        if turns.isEmpty {
            output.append(NSAttributedString(string: "Nothing transcribed yet.", attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }

        for turn in turns {
            let color = MeetingSpeakerPalette.color(for: document.speaker(id: turn.speakerID))
            output.append(NSAttributedString(string: turn.speakerName, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                .foregroundColor: color.blended(withFraction: 0.25, of: .labelColor) ?? color,
                .paragraphStyle: header,
            ]))
            output.append(NSAttributedString(string: "  " + MeetingTranscriptFormatter.timestamp(turn.start) + "\n", attributes: [
                .font: Theme.Font.metaDigits,
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: header,
            ]))

            let paragraph = NSMutableAttributedString(string: turn.text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 14.5),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: body,
            ])
            for range in MeetingSearch.ranges(of: query, in: turn.text) {
                paragraph.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.4), range: NSRange(range, in: turn.text))
            }
            output.append(paragraph)
        }

        textView.textStorage?.setAttributedString(output)
    }

    func scrollToFirstMatch(_ query: String) {
        guard !query.isEmpty, let storage = textView.textStorage else { return }
        let range = (storage.string as NSString).range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
        if range.location != NSNotFound {
            textView.scrollRangeToVisible(range)
            textView.showFindIndicator(for: range)
        }
    }
}

/// Who spoke, for how long — plus renaming and merging speakers (diarization
/// sometimes splits one person into two).
final class MeetingSpeakersView: NSView, NSTextFieldDelegate {

    var onRename: ((String, String) -> Void)?
    var onMerge: ((String, String) -> Void)?

    private let scrollView = NSScrollView()
    private let list = FlippedView()
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private var rowViews: [NSView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.documentView = list
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        addSubview(scrollView)

        noteLabel.font = .systemFont(ofSize: 11.5)
        noteLabel.textColor = .secondaryLabelColor
        list.addSubview(noteLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    private struct Stat {
        let speaker: MeetingSpeaker
        let seconds: TimeInterval
        let turns: Int
        let words: Int
    }

    func show(document: MeetingDocument, speakerDetection: MeetingLiveState.SpeakerDetection?) {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = []

        let turns = MeetingTranscriptFormatter.turns(for: document)
        var stats: [Stat] = document.activeSpeakers.map { speaker in
            let segments = document.visibleSegments.filter { $0.speakerID == speaker.id }
            return Stat(
                speaker: speaker,
                seconds: segments.reduce(0) { $0 + max(0, $1.end - $1.start) },
                turns: turns.filter { $0.speakerID == speaker.id }.count,
                words: segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
            )
        }
        stats.sort { $0.seconds > $1.seconds }
        let totalSeconds = max(1, stats.reduce(0) { $0 + $1.seconds })
        let others = document.activeSpeakers

        for stat in stats {
            let row = SpeakerRowView(
                speaker: stat.speaker,
                share: stat.seconds / totalSeconds,
                detail: "\(MeetingTranscriptFormatter.durationText(stat.seconds)) · \(stat.turns) turn\(stat.turns == 1 ? "" : "s") · \(stat.words) words",
                mergeTargets: others.filter { $0.id != stat.speaker.id },
                onRename: { [weak self] name in self?.onRename?(stat.speaker.id, name) },
                onMerge: { [weak self] target in self?.onMerge?(stat.speaker.id, target) }
            )
            list.addSubview(row)
            rowViews.append(row)
        }

        var notes: [String] = []
        if document.microphoneOnly == true {
            notes.append("Only your microphone was recorded, so everyone in the room shares one speaker.")
        } else {
            switch speakerDetection {
            case .loading?: notes.append("Speaker detection is loading. Call audio is labelled \u{201C}Others\u{201D} until it's ready.")
            case .unavailable(let reason)?: notes.append("Speaker detection is unavailable (\(reason)). Call audio is labelled \u{201C}Others\u{201D}.")
            default: break
            }
            notes.append("Talk time is measured from transcribed speech. If one person shows up as two speakers, merge them. Renames apply to the whole meeting.")
        }
        noteLabel.stringValue = notes.joined(separator: "\n\n")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let width = scrollView.contentSize.width
        let padding: CGFloat = 22
        var y: CGFloat = 18
        for row in rowViews {
            row.frame = NSRect(x: padding, y: y, width: width - padding * 2, height: 58)
            y += 58 + 8
        }
        noteLabel.preferredMaxLayoutWidth = width - padding * 2
        let noteHeight = noteLabel.fittingSize.height
        noteLabel.frame = NSRect(x: padding, y: y + 8, width: width - padding * 2, height: noteHeight)
        list.frame = NSRect(x: 0, y: 0, width: width, height: max(scrollView.contentSize.height, y + noteHeight + 30))
    }
}

private final class SpeakerRowView: NSView, NSTextFieldDelegate {
    private let card = Theme.makeCard()
    private let dot: AdaptiveBackgroundView
    private let nameField = NSTextField(string: "")
    private let kindLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let shareLabel = NSTextField(labelWithString: "")
    private let barTrack = AdaptiveBackgroundView(color: Theme.wash(0.08), cornerRadius: 2.5)
    private let barFill: AdaptiveBackgroundView
    private let mergeButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let share: Double
    private let onRename: (String) -> Void
    private let onMerge: (String) -> Void
    private let mergeTargets: [MeetingSpeaker]
    private let originalName: String

    override var isFlipped: Bool { true }

    init(speaker: MeetingSpeaker, share: Double, detail: String, mergeTargets: [MeetingSpeaker],
         onRename: @escaping (String) -> Void, onMerge: @escaping (String) -> Void) {
        let color = MeetingSpeakerPalette.color(for: speaker)
        self.dot = AdaptiveBackgroundView(color: color, cornerRadius: 5)
        self.barFill = AdaptiveBackgroundView(color: color.withAlphaComponent(0.85), cornerRadius: 2.5)
        self.share = share
        self.onRename = onRename
        self.onMerge = onMerge
        self.mergeTargets = mergeTargets
        self.originalName = speaker.name
        super.init(frame: .zero)

        addSubview(card)
        addSubview(dot)

        nameField.stringValue = speaker.name
        nameField.font = .systemFont(ofSize: 13, weight: .semibold)
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        nameField.placeholderString = "Name"
        nameField.toolTip = "Click to rename"
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(commitName)
        addSubview(nameField)

        kindLabel.stringValue = speaker.kind == .local ? "Microphone" : "Call audio"
        kindLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        kindLabel.textColor = .tertiaryLabelColor
        addSubview(kindLabel)

        detailLabel.stringValue = detail
        detailLabel.font = Theme.Font.metaDigits
        detailLabel.textColor = .secondaryLabelColor
        addSubview(detailLabel)

        shareLabel.stringValue = "\(Int((share * 100).rounded()))%"
        shareLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        shareLabel.alignment = .right
        addSubview(shareLabel)

        addSubview(barTrack)
        addSubview(barFill)

        mergeButton.isBordered = false
        mergeButton.controlSize = .small
        mergeButton.addItem(withTitle: "")
        mergeButton.item(at: 0)?.image = NSImage(systemSymbolName: "arrow.triangle.merge", accessibilityDescription: "Merge")
        mergeButton.toolTip = "Merge this speaker into another"
        for target in mergeTargets {
            mergeButton.addItem(withTitle: "Merge into \(target.name)")
            mergeButton.lastItem?.representedObject = target.id
        }
        mergeButton.target = self
        mergeButton.action = #selector(mergeChosen)
        mergeButton.isHidden = mergeTargets.isEmpty || speaker.kind == .local
        addSubview(mergeButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        card.frame = bounds
        dot.frame = NSRect(x: 14, y: 16, width: 10, height: 10)
        nameField.frame = NSRect(x: 30, y: 9, width: min(260, bounds.width - 200), height: 22)
        kindLabel.sizeToFit()
        let nameWidth = (nameField.stringValue as NSString).size(withAttributes: [.font: nameField.font!]).width + 10
        kindLabel.frame.origin = NSPoint(x: 30 + min(nameWidth, nameField.frame.width) + 6, y: 13)
        detailLabel.frame = NSRect(x: 32, y: 33, width: bounds.width - 200, height: 16)
        mergeButton.frame = NSRect(x: bounds.width - 40, y: 10, width: 30, height: 22)
        shareLabel.frame = NSRect(x: bounds.width - 160, y: 12, width: 110, height: 18)
        let barWidth: CGFloat = 130
        barTrack.frame = NSRect(x: bounds.width - barWidth - 14, y: 37, width: barWidth, height: 5)
        barFill.frame = NSRect(x: barTrack.frame.minX, y: 37, width: max(5, barWidth * CGFloat(share)), height: 5)
    }

    @objc private func commitName() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            nameField.stringValue = originalName
            return
        }
        if name != originalName { onRename(name) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitName()
    }

    @objc private func mergeChosen() {
        guard let target = mergeButton.selectedItem?.representedObject as? String else { return }
        onMerge(target)
    }
}
