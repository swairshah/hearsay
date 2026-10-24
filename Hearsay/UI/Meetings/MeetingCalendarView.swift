import AppKit

/// Speaker colours: "You" first, then the call ("Others"), then diarized speakers.
enum MeetingSpeakerPalette {
    private static let colors: [NSColor] = [
        .controlAccentColor,
        .systemGray,
        .systemOrange,
        .systemTeal,
        .systemPink,
        .systemIndigo,
        .systemGreen,
        .systemBrown,
    ]

    static func color(for index: Int) -> NSColor {
        colors[((index % colors.count) + colors.count) % colors.count]
    }

    static func color(for speaker: MeetingSpeaker?) -> NSColor {
        color(for: speaker?.colorIndex ?? 1)
    }
}

/// A compact month calendar, shaded like a contribution heatmap: the more
/// meetings on a day, the deeper its square. Clicking a day selects it.
final class MeetingCalendarView: NSView {

    var onSelectDay: ((Date) -> Void)?

    private(set) var selectedDay: Date
    private var displayedMonth: Date
    private var meetingCounts: [Date: Int] = [:]
    private let calendar = Calendar.current

    private let monthLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let todayButton = NSButton(title: "Today", target: nil, action: nil)

    private var hoveredDay: Date?
    private var trackingAreaRef: NSTrackingArea?

    private let headerHeight: CGFloat = 30
    private let weekdayHeight: CGFloat = 20
    private let cellHeight: CGFloat = 28

    static let preferredHeight: CGFloat = 30 + 20 + 28 * 6 + 6

    override var isFlipped: Bool { true }

    init() {
        let today = Calendar.current.startOfDay(for: Date())
        selectedDay = today
        displayedMonth = Self.firstOfMonth(today, calendar: .current)
        super.init(frame: .zero)

        monthLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        monthLabel.textColor = .labelColor
        addSubview(monthLabel)

        for (button, symbol, action) in [
            (previousButton, "chevron.left", #selector(showPreviousMonth)),
            (nextButton, "chevron.right", #selector(showNextMonth)),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.action = action
            addSubview(button)
        }
        previousButton.toolTip = "Previous month"
        nextButton.toolTip = "Next month"

        todayButton.bezelStyle = .inline
        todayButton.controlSize = .small
        todayButton.font = .systemFont(ofSize: 11, weight: .medium)
        todayButton.target = self
        todayButton.action = #selector(goToToday)
        addSubview(todayButton)

        updateMonthLabel()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public

    func setMeetingCounts(_ counts: [Date: Int]) {
        meetingCounts = counts
        needsDisplay = true
    }

    func select(day: Date, notify: Bool = false) {
        selectedDay = calendar.startOfDay(for: day)
        let month = Self.firstOfMonth(selectedDay, calendar: calendar)
        if month != displayedMonth {
            displayedMonth = month
            updateMonthLabel()
        }
        needsDisplay = true
        if notify { onSelectDay?(selectedDay) }
    }

    // MARK: - Layout & drawing

    override func layout() {
        super.layout()
        monthLabel.sizeToFit()
        monthLabel.frame.origin = NSPoint(x: 4, y: (headerHeight - monthLabel.frame.height) / 2)

        let buttonSize: CGFloat = 22
        nextButton.frame = NSRect(x: bounds.width - buttonSize, y: (headerHeight - buttonSize) / 2, width: buttonSize, height: buttonSize)
        todayButton.sizeToFit()
        todayButton.frame.origin = NSPoint(
            x: nextButton.frame.minX - todayButton.frame.width - 2,
            y: (headerHeight - todayButton.frame.height) / 2
        )
        previousButton.frame = NSRect(x: todayButton.frame.minX - buttonSize - 2, y: (headerHeight - buttonSize) / 2, width: buttonSize, height: buttonSize)
    }

    private var cellWidth: CGFloat { bounds.width / 7 }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let weekdayAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        for column in 0..<7 {
            let symbol = symbols[(column + calendar.firstWeekday - 1) % 7]
            let size = symbol.size(withAttributes: weekdayAttributes)
            let x = CGFloat(column) * cellWidth + (cellWidth - size.width) / 2
            symbol.draw(at: NSPoint(x: x, y: headerHeight + (weekdayHeight - size.height) / 2), withAttributes: weekdayAttributes)
        }

        let today = calendar.startOfDay(for: Date())
        for (index, day) in visibleDays().enumerated() {
            let rect = cellRect(at: index)
            let inMonth = calendar.isDate(day, equalTo: displayedMonth, toGranularity: .month)
            let isSelected = day == selectedDay
            let isToday = day == today
            let count = meetingCounts[day] ?? 0

            let squareSize: CGFloat = 24
            let square = NSRect(x: rect.midX - squareSize / 2, y: rect.minY + 2, width: squareSize, height: squareSize)
            let shape = NSBezierPath(roundedRect: square, xRadius: 5, yRadius: 5)
            let level = Self.heatLevel(for: count)
            if level > 0 {
                let alpha = Self.heatAlphas[level] * (inMonth ? 1 : 0.4)
                NSColor.controlAccentColor.withAlphaComponent(alpha).setFill()
                shape.fill()
            } else if day == hoveredDay {
                Theme.wash(Theme.Wash.cardHover).setFill()
                shape.fill()
            }
            if isSelected {
                let ring = NSBezierPath(roundedRect: square.insetBy(dx: -1.5, dy: -1.5), xRadius: 6.5, yRadius: 6.5)
                ring.lineWidth = 2
                NSColor.controlAccentColor.setStroke()
                ring.stroke()
            } else if level > 0 && day == hoveredDay {
                NSColor.controlAccentColor.withAlphaComponent(0.5).setStroke()
                shape.lineWidth = 1
                shape.stroke()
            }

            let textColor: NSColor
            if !inMonth {
                textColor = .quaternaryLabelColor
            } else if level >= 3 {
                textColor = .white
            } else if isToday {
                textColor = .controlAccentColor
            } else {
                textColor = count > 0 ? .labelColor : .secondaryLabelColor
            }
            let font = NSFont.monospacedDigitSystemFont(
                ofSize: 11.5,
                weight: (isToday || count > 0) && inMonth ? .semibold : .regular
            )
            let text = "\(calendar.component(.day, from: day))"
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: square.midX - size.width / 2, y: square.midY - size.height / 2), withAttributes: attributes)
        }
    }

    /// Shade steps, GitHub-style: none, 1, 2–3, 4–6, 7+ meetings.
    private static let heatAlphas: [CGFloat] = [0, 0.18, 0.38, 0.62, 0.9]

    static func heatLevel(for count: Int) -> Int {
        switch count {
        case ..<1: return 0
        case 1: return 1
        case 2...3: return 2
        case 4...6: return 3
        default: return 4
        }
    }

    private func cellRect(at index: Int) -> NSRect {
        let row = index / 7
        let column = index % 7
        return NSRect(
            x: CGFloat(column) * cellWidth,
            y: headerHeight + weekdayHeight + CGFloat(row) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
    }

    /// 42 days (6 weeks) starting on the week containing the 1st.
    private func visibleDays() -> [Date] {
        let weekday = calendar.component(.weekday, from: displayedMonth)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        guard let start = calendar.date(byAdding: .day, value: -leading, to: displayedMonth) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
            .map { calendar.startOfDay(for: $0) }
    }

    private func day(at point: NSPoint) -> Date? {
        let gridTop = headerHeight + weekdayHeight
        guard point.y >= gridTop, point.y < gridTop + cellHeight * 6, point.x >= 0, point.x < bounds.width else { return nil }
        let row = Int((point.y - gridTop) / cellHeight)
        let column = Int(point.x / cellWidth)
        let days = visibleDays()
        let index = row * 7 + column
        return index < days.count ? days[index] : nil
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let day = day(at: point) else { return }
        select(day: day, notify: true)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) {
        let day = day(at: convert(event.locationInWindow, from: nil))
        if day != hoveredDay {
            hoveredDay = day
            let count = day.flatMap { meetingCounts[$0] } ?? 0
            toolTip = count == 0 ? nil : (count == 1 ? "1 meeting" : "\(count) meetings")
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredDay = nil
        needsDisplay = true
    }

    @objc private func showPreviousMonth() {
        shiftMonth(by: -1)
    }

    @objc private func showNextMonth() {
        shiftMonth(by: 1)
    }

    @objc private func goToToday() {
        select(day: Date(), notify: true)
    }

    private func shiftMonth(by delta: Int) {
        guard let month = calendar.date(byAdding: .month, value: delta, to: displayedMonth) else { return }
        displayedMonth = month
        updateMonthLabel()
        needsDisplay = true
    }

    private func updateMonthLabel() {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        monthLabel.stringValue = formatter.string(from: displayedMonth)
        needsLayout = true
    }

    private static func firstOfMonth(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }
}
