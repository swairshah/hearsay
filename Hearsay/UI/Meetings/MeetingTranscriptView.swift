import AppKit

/// One row in the transcript list.
struct MeetingTranscriptRow {
    enum Kind {
        case segment(MeetingSegment)
        /// Words still being spoken (live meetings).
        case partial(channel: MeetingSegment.Channel, text: String, start: TimeInterval)
    }

    let kind: Kind
    let speakerName: String
    let speakerColor: NSColor
    /// First row of a speaker turn: draws the name + timestamp header.
    let showsHeader: Bool
    let start: TimeInterval
    let text: String
    let isModified: Bool

    var segmentID: UUID? {
        if case .segment(let segment) = kind { return segment.id }
        return nil
    }
}

/// Chat-style transcript: speaker turns with timestamps, search highlighting,
/// inline editing, and a context menu for speaker fixes.
final class MeetingTranscriptView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    var onEditSegment: ((UUID) -> Void)?
    var onShowMenu: ((UUID, NSMenu) -> Void)?
    /// Fired when the user scrolls away from / back to the bottom (live follow).
    var onFollowChanged: ((Bool) -> Void)?

    private let scrollView = NSScrollView()
    private let tableView = TranscriptTableView()
    private(set) var rows: [MeetingTranscriptRow] = []
    private var searchQuery = ""
    private var currentMatchSegmentID: UUID?
    private var heightCache: [String: CGFloat] = [:]
    private var lastLayoutWidth: CGFloat = 0
    private(set) var isFollowingLive = true

    static let horizontalPadding: CGFloat = 22
    static let textFont = NSFont.systemFont(ofSize: 13.5)
    static let headerHeight: CGFloat = 20

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.usesAutomaticRowHeights = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.target = self
        tableView.menuProvider = { [weak self] row in self?.menu(forRow: row) }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 18, right: 0)
        addSubview(scrollView)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        if abs(lastLayoutWidth - bounds.width) > 0.5 {
            lastLayoutWidth = bounds.width
            heightCache.removeAll()
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
        }
    }

    // MARK: - Data

    /// `follow`: the meeting is live, so keep the newest line in view while the
    /// user hasn't scrolled away. Saved meetings open at the top.
    func setRows(_ newRows: [MeetingTranscriptRow], query: String, currentMatch: UUID?, scrollToBottom: Bool, follow: Bool = false) {
        let wasAtBottom = isNearBottom && !rows.isEmpty
        let isNewContent = rows.first?.segmentID != newRows.first?.segmentID
        rows = newRows
        searchQuery = query
        currentMatchSegmentID = currentMatch
        tableView.reloadData()
        if scrollToBottom || (follow && isFollowingLive && wasAtBottom) {
            scrollToEnd()
        } else if isNewContent {
            tableView.scrollRowToVisible(0)
        }
    }

    func scrollToEnd() {
        guard !rows.isEmpty else { return }
        tableView.scrollRowToVisible(rows.count - 1)
        isFollowingLive = true
        onFollowChanged?(true)
    }

    func scrollTo(segmentID: UUID) {
        guard let row = rows.firstIndex(where: { $0.segmentID == segmentID }) else { return }
        let rect = tableView.rect(ofRow: row)
        let visible = scrollView.contentView.bounds
        let target = NSPoint(x: 0, y: max(0, rect.midY - visible.height / 2))
        scrollView.contentView.scroll(to: target)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    var selectedSegmentID: UUID? {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : -1
        return row >= 0 && row < rows.count ? rows[row].segmentID : nil
    }

    private var isNearBottom: Bool {
        let visible = scrollView.contentView.bounds
        return visible.maxY >= tableView.bounds.height - 40
    }

    @objc private func scrolled() {
        let following = isNearBottom
        if following != isFollowingLive {
            isFollowingLive = following
            onFollowChanged?(following)
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let item = rows[row]
        let key = "\(item.segmentID?.uuidString ?? "partial-\(row)")|\(item.showsHeader)|\(item.text.hashValue)"
        if let cached = heightCache[key] { return cached }
        let width = max(100, tableView.bounds.width - Self.horizontalPadding * 2)
        let textHeight = Self.attributedText(for: item, query: "", isCurrent: false)
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
            .height
        let height = ceil(textHeight) + (item.showsHeader ? Self.headerHeight + 14 : 4) + 4
        heightCache[key] = height
        return height
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("TranscriptRowCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? TranscriptRowCell) ?? TranscriptRowCell()
        cell.identifier = identifier
        let item = rows[row]
        let isCurrent = item.segmentID != nil && item.segmentID == currentMatchSegmentID
        cell.configure(
            row: item,
            text: Self.attributedText(for: item, query: searchQuery, isCurrent: isCurrent),
            isCurrentMatch: isCurrent
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        TranscriptRowBackground()
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count, let id = rows[row].segmentID else { return }
        onEditSegment?(id)
    }

    private func menu(forRow row: Int) -> NSMenu? {
        guard row >= 0, row < rows.count, let id = rows[row].segmentID else { return nil }
        let menu = NSMenu()
        onShowMenu?(id, menu)
        return menu.items.isEmpty ? nil : menu
    }

    // MARK: - Text

    static func attributedText(for row: MeetingTranscriptRow, query: String, isCurrent: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2.5
        paragraph.lineBreakMode = .byWordWrapping

        let isPartial: Bool
        if case .partial = row.kind { isPartial = true } else { isPartial = false }

        let font = isPartial ? NSFontManager.shared.convert(textFont, toHaveTrait: .italicFontMask) : textFont
        let text = NSMutableAttributedString(string: row.text, attributes: [
            .font: font,
            .foregroundColor: isPartial ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        if isPartial {
            text.append(NSAttributedString(string: " …", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
        }

        if !query.isEmpty {
            let highlight = isCurrent
                ? NSColor.findHighlightColor
                : NSColor.systemYellow.withAlphaComponent(0.35)
            for range in MeetingSearch.ranges(of: query, in: row.text) {
                text.addAttribute(.backgroundColor, value: highlight, range: NSRange(range, in: row.text))
                if isCurrent {
                    text.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(range, in: row.text))
                }
            }
        }
        return text
    }
}

// MARK: - Cells

private final class TranscriptTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return menuProvider?(row)
    }
}

private final class TranscriptRowBackground: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
}

private final class TranscriptRowCell: NSTableCellView {
    private let dot = AdaptiveBackgroundView(color: .systemGray, cornerRadius: 3.5)
    private let nameLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let editedBadge = NSTextField(labelWithString: "edited")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let matchBar = AdaptiveBackgroundView(color: .findHighlightColor, cornerRadius: 1.5)
    private var showsHeader = false

    init() {
        super.init(frame: .zero)
        addSubview(dot)

        nameLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        timeLabel.font = Theme.Font.metaDigits
        timeLabel.textColor = .tertiaryLabelColor
        addSubview(timeLabel)

        editedBadge.font = .systemFont(ofSize: 10, weight: .medium)
        editedBadge.textColor = .tertiaryLabelColor
        addSubview(editedBadge)

        // Not selectable, so clicks reach the table (double-click edits).
        // Reader view is the place to select arbitrary text.
        body.isSelectable = false
        body.maximumNumberOfLines = 0
        body.cell?.wraps = true
        body.cell?.isScrollable = false
        addSubview(body)

        addSubview(matchBar)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(row: MeetingTranscriptRow, text: NSAttributedString, isCurrentMatch: Bool) {
        showsHeader = row.showsHeader
        dot.backgroundColor = row.speakerColor
        nameLabel.stringValue = row.speakerName
        nameLabel.textColor = row.speakerColor.blended(withFraction: 0.25, of: .labelColor) ?? row.speakerColor
        timeLabel.stringValue = MeetingTranscriptFormatter.timestamp(row.start)
        for view in [dot, nameLabel, timeLabel] {
            view.isHidden = !row.showsHeader
        }
        editedBadge.isHidden = !(row.showsHeader && row.isModified)
        body.attributedStringValue = text
        matchBar.isHidden = !isCurrentMatch
        toolTip = row.isModified ? "Edited or post-processed. Right-click to restore the original." : nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let padding = MeetingTranscriptView.horizontalPadding
        var top = bounds.height
        if showsHeader {
            top -= 12
            dot.frame = NSRect(x: padding, y: top - 13, width: 7, height: 7)
            nameLabel.sizeToFit()
            nameLabel.frame = NSRect(x: padding + 13, y: top - 17, width: min(nameLabel.frame.width, bounds.width / 2), height: 17)
            timeLabel.sizeToFit()
            timeLabel.frame.origin = NSPoint(x: nameLabel.frame.maxX + 8, y: top - 16)
            editedBadge.sizeToFit()
            editedBadge.frame.origin = NSPoint(x: timeLabel.frame.maxX + 8, y: top - 16)
            top -= MeetingTranscriptView.headerHeight + 2
        } else {
            top -= 2
        }
        let width = bounds.width - padding * 2
        body.preferredMaxLayoutWidth = width
        body.frame = NSRect(x: padding - 2, y: 2, width: width + 4, height: max(0, top - 2))
        matchBar.frame = NSRect(x: padding - 10, y: 4, width: 3, height: max(0, top - 6))
    }
}
