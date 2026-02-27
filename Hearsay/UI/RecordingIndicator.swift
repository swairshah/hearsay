import AppKit

/// The visual content of the recording indicator pill.
/// Minimal design: waveform when recording, waveform + dots when transcribing.
/// Screenshot count lines appear outside the pill to the right.
final class RecordingIndicator: NSView {
    
    enum State {
        case recording
        case transcribing
        case done
        case error(String)
    }
    
    private(set) var state: State = .recording
    
    /// Number of screenshots/figures captured in current session
    var figureCount: Int = 0 {
        didSet {
            figureCountView.count = figureCount
            needsLayout = true
        }
    }
    
    /// Whether to show figure count (enabled during toggle recording)
    var showFigureCount: Bool = false {
        didSet {
            figureCountView.isHidden = !showFigureCount
            needsLayout = true
        }
    }
    
    // UI Elements
    private let pillBackground = CALayer()
    private let waveformView = WaveformView()
    private let dotsView = AnimatedDotsView()
    private let figureCountView = FigureCountView()
    private let checkmarkView = CheckmarkView()
    
    // Audio level (0-1)
    var audioLevel: Float = 0 {
        didSet {
            waveformView.level = audioLevel
        }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }
    
    // MARK: - Setup
    
    private func setupUI() {
        wantsLayer = true
        // Main view is transparent - pill background is a sublayer
        layer?.backgroundColor = NSColor.clear.cgColor
        
        // Pill background (only covers the waveform/dots area)
        pillBackground.backgroundColor = NSColor(white: 0.1, alpha: 0.95).cgColor
        layer?.addSublayer(pillBackground)
        
        addSubview(waveformView)
        addSubview(dotsView)
        addSubview(figureCountView)
        addSubview(checkmarkView)
        
        dotsView.isHidden = true
        figureCountView.isHidden = true
        checkmarkView.isHidden = true
    }
    
    /// Calculate ideal width based on current state
    var idealWidth: CGFloat {
        let pillWidth = Constants.indicatorWidth
        let figureCountWidth = figureCountView.idealWidth
        let spacing: CGFloat = 8
        
        if case .recording = state, showFigureCount && figureCount > 0 {
            return pillWidth + spacing + figureCountWidth
        }
        return pillWidth
    }
    
    override func layout() {
        super.layout()
        
        let pillWidth = Constants.indicatorWidth
        let pillHeight = bounds.height
        let waveformWidth: CGFloat = 40
        let dotsWidth: CGFloat = 36
        let contentHeight: CGFloat = 20
        let figureCountWidth = figureCountView.idealWidth
        let spacing: CGFloat = 8
        
        let isRecording: Bool
        if case .recording = state {
            isRecording = true
        } else {
            isRecording = false
        }
        
        // Position pill background (always on the left)
        pillBackground.frame = NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight)
        pillBackground.cornerRadius = pillHeight / 2
        
        let checkmarkSize: CGFloat = 18
        
        switch state {
        case .recording, .error:
            // Center waveform inside the pill
            waveformView.frame = NSRect(
                x: (pillWidth - waveformWidth) / 2,
                y: (pillHeight - contentHeight) / 2,
                width: waveformWidth,
                height: contentHeight
            )
            waveformView.isHidden = false
            dotsView.isHidden = true
            checkmarkView.isHidden = true
            
            // Position figure count outside the pill (to the right)
            if showFigureCount && isRecording && figureCount > 0 {
                figureCountView.frame = NSRect(
                    x: pillWidth + spacing,
                    y: (pillHeight - contentHeight) / 2,
                    width: figureCountWidth,
                    height: contentHeight
                )
                figureCountView.isHidden = false
            } else {
                figureCountView.isHidden = true
            }
            
        case .done:
            // Show green checkmark centered inside the pill
            waveformView.isHidden = true
            dotsView.isHidden = true
            figureCountView.isHidden = true
            checkmarkView.frame = NSRect(
                x: (pillWidth - checkmarkSize) / 2,
                y: (pillHeight - checkmarkSize) / 2,
                width: checkmarkSize,
                height: checkmarkSize
            )
            checkmarkView.isHidden = false
            
        case .transcribing:
            // Just show dots centered inside the pill
            waveformView.isHidden = true
            figureCountView.isHidden = true
            checkmarkView.isHidden = true
            dotsView.frame = NSRect(
                x: (pillWidth - dotsWidth) / 2,
                y: (pillHeight - contentHeight) / 2,
                width: dotsWidth,
                height: contentHeight
            )
            dotsView.isHidden = false
        }
    }
    
    // MARK: - State Management
    
    func setState(_ newState: State) {
        state = newState
        
        switch state {
        case .recording:
            waveformView.isAnimating = true
            waveformView.setStatic(false)
            dotsView.stopAnimating()
            
        case .transcribing:
            waveformView.isAnimating = false
            waveformView.setStatic(true)
            dotsView.startAnimating()
            
        case .done:
            waveformView.isAnimating = false
            dotsView.stopAnimating()
            
        case .error:
            waveformView.isAnimating = false
            dotsView.stopAnimating()
        }
        
        needsLayout = true
    }
}

// MARK: - Waveform View

private class WaveformView: NSView {

    /// Current audio level (0-1), set externally at ~20Hz
    var level: Float = 0

    var isAnimating = false {
        didSet {
            guard isAnimating != oldValue else { return }
            if isAnimating {
                startAnimationTimer()
            } else {
                stopAnimationTimer()
            }
        }
    }

    private var bars: [CALayer] = []
    private let barCount = 7

    // Per-bar smoothed heights
    private var barHeights: [Float] = []
    // Smoothed input level (fast attack, slow decay)
    private var smoothedLevel: Float = 0
    private var animationTimer: Timer?
    private var animationTime: Double = 0

    // Bar gain envelope — center bars taller, edges shorter for natural waveform shape
    private let barGains: [Float] = [0.55, 0.8, 0.95, 1.0, 0.9, 0.75, 0.5]
    // Phase offsets for subtle per-bar sinusoidal variation
    private let barPhases: [Float] = [0, 0.9, 1.8, 2.7, 3.6, 4.5, 5.4]

    override init(frame frameRect: NSRect) {
        barHeights = Array(repeating: 0.05, count: barCount)
        super.init(frame: frameRect)
        setupBars()
    }

    required init?(coder: NSCoder) {
        barHeights = Array(repeating: 0.05, count: barCount)
        super.init(coder: coder)
        setupBars()
    }

    private func setupBars() {
        wantsLayer = true

        for _ in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = 1.5
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    func setStatic(_ isStatic: Bool) {
        if isStatic {
            smoothedLevel = 0.35
            barHeights = barGains.map { 0.35 * $0 }
            renderBars()
        }
    }

    override func layout() {
        super.layout()
        renderBars()
    }

    // MARK: - Animation

    private func startAnimationTimer() {
        animationTime = 0
        smoothedLevel = 0
        barHeights = Array(repeating: 0.05, count: barCount)
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func tick() {
        animationTime += 1.0 / 60.0

        // Smooth input level: fast attack (respond to speech), slow decay (hold during pauses)
        let attack: Float = 0.35
        let decay: Float = 0.12
        if level > smoothedLevel {
            smoothedLevel += (level - smoothedLevel) * attack
        } else {
            smoothedLevel += (level - smoothedLevel) * decay
        }

        for i in 0..<barCount {
            // Target from smoothed level scaled by this bar's gain
            var target = smoothedLevel * barGains[i]

            // Subtle sinusoidal wobble — amplitude scales with level so silence is still
            let wobble = sin(Float(animationTime * 2.5) + barPhases[i]) * 0.04 * max(smoothedLevel, 0.1)
            target += wobble

            // Clamp with a low idle floor
            target = max(0.05, min(1.0, target))

            // Per-bar smoothing for fluid motion
            barHeights[i] += (target - barHeights[i]) * 0.3
        }

        renderBars()
    }

    private func renderBars() {
        let barWidth: CGFloat = 3
        let spacing: CGFloat = 5
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        let startX = (bounds.width - totalWidth) / 2
        let maxHeight = bounds.height - 4
        let minHeight: CGFloat = 4

        CATransaction.begin()
        CATransaction.setDisableActions(true) // We handle all smoothing ourselves

        for (index, bar) in bars.enumerated() {
            let barLevel = CGFloat(barHeights[index])
            let height = minHeight + barLevel * (maxHeight - minHeight)

            let x = startX + CGFloat(index) * (barWidth + spacing)
            let y = (bounds.height - height) / 2

            bar.frame = NSRect(x: x, y: y, width: barWidth, height: height)
        }

        CATransaction.commit()
    }
}

// MARK: - Animated Dots View

private class AnimatedDotsView: NSView {
    
    private var dots: [CALayer] = []
    private let dotCount = 3
    private var animationTimer: Timer?
    private var currentDot = 0
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupDots()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupDots()
    }
    
    private func setupDots() {
        wantsLayer = true
        
        for _ in 0..<dotCount {
            let dot = CALayer()
            dot.backgroundColor = NSColor(white: 0.5, alpha: 1).cgColor
            dot.cornerRadius = 4
            layer?.addSublayer(dot)
            dots.append(dot)
        }
    }
    
    override func layout() {
        super.layout()
        
        let dotSize: CGFloat = 5
        let spacing: CGFloat = 4
        let totalWidth = CGFloat(dotCount) * dotSize + CGFloat(dotCount - 1) * spacing
        let startX = (bounds.width - totalWidth) / 2
        let y = (bounds.height - dotSize) / 2
        
        for (index, dot) in dots.enumerated() {
            let x = startX + CGFloat(index) * (dotSize + spacing)
            dot.frame = NSRect(x: x, y: y, width: dotSize, height: dotSize)
            dot.cornerRadius = dotSize / 2
        }
    }
    
    func startAnimating() {
        stopAnimating()
        currentDot = 0
        
        // Set initial state - all dots dim
        for dot in dots {
            dot.backgroundColor = NSColor(white: 0.4, alpha: 1).cgColor
        }
        
        // Animate dots in sequence
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.animateNextDot()
        }
        animateNextDot()
    }
    
    func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        
        // Reset all dots to dim
        for dot in dots {
            dot.backgroundColor = NSColor(white: 0.4, alpha: 1).cgColor
        }
    }
    
    private func animateNextDot() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        
        for (index, dot) in dots.enumerated() {
            if index == currentDot {
                dot.backgroundColor = NSColor(white: 0.85, alpha: 1).cgColor
            } else {
                dot.backgroundColor = NSColor(white: 0.4, alpha: 1).cgColor
            }
        }
        
        CATransaction.commit()
        
        currentDot = (currentDot + 1) % dotCount
    }
}

// MARK: - Figure Count View

/// Displays vertical lines indicating screenshot count.
/// Appears outside the pill to the right.
/// Visual: ||| (lines for each figure captured)
private class FigureCountView: NSView {
    
    var count: Int = 0 {
        didSet {
            updateLines()
        }
    }
    
    private var lineLayers: [CALayer] = []
    private var borderLayers: [CALayer] = []
    private let maxLines = 9  // Cap visual at 9 lines
    
    private let lineWidth: CGFloat = 2
    private let lineHeight: CGFloat = 14
    private let lineSpacing: CGFloat = 4
    private let borderWidth: CGFloat = 2  // Black border thickness
    
    /// Calculate ideal width based on count
    var idealWidth: CGFloat {
        if count == 0 {
            return 0  // Nothing to show
        }
        let linesShown = min(count, maxLines)
        let totalLineWidth = lineWidth + borderWidth * 2  // Line + border on each side
        return CGFloat(linesShown) * totalLineWidth + CGFloat(linesShown - 1) * lineSpacing
    }
    
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
    }
    
    private func updateLines() {
        // Remove existing layers
        for line in lineLayers {
            line.removeFromSuperlayer()
        }
        for border in borderLayers {
            border.removeFromSuperlayer()
        }
        lineLayers.removeAll()
        borderLayers.removeAll()
        
        // Create new lines with borders
        let linesShown = min(count, maxLines)
        for _ in 0..<linesShown {
            // Black border layer (behind)
            let border = CALayer()
            border.backgroundColor = NSColor.black.cgColor
            border.cornerRadius = (lineWidth + borderWidth * 2) / 2
            layer?.addSublayer(border)
            borderLayers.append(border)
            
            // White line layer (front)
            let line = CALayer()
            line.backgroundColor = NSColor.white.cgColor
            line.cornerRadius = lineWidth / 2
            layer?.addSublayer(line)
            lineLayers.append(line)
        }
        
        needsLayout = true
    }
    
    override func layout() {
        super.layout()
        
        // Position lines centered
        let totalLineWidth = lineWidth + borderWidth * 2
        let totalLineHeight = lineHeight + borderWidth * 2
        let lineY = (bounds.height - lineHeight) / 2
        let borderY = (bounds.height - totalLineHeight) / 2
        var x: CGFloat = 0
        
        for i in 0..<lineLayers.count {
            // Position border (slightly larger, behind)
            borderLayers[i].frame = NSRect(x: x, y: borderY, width: totalLineWidth, height: totalLineHeight)
            // Position white line (centered on border)
            lineLayers[i].frame = NSRect(x: x + borderWidth, y: lineY, width: lineWidth, height: lineHeight)
            x += totalLineWidth + lineSpacing
        }
    }
}

// MARK: - Checkmark View

/// Displays a green checkmark indicating successful transcription.
private class CheckmarkView: NSView {
    
    private let shapeLayer = CAShapeLayer()
    
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
        
        shapeLayer.fillColor = NSColor.clear.cgColor
        shapeLayer.strokeColor = NSColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1).cgColor
        shapeLayer.lineWidth = 2.5
        shapeLayer.lineCap = .round
        shapeLayer.lineJoin = .round
        layer?.addSublayer(shapeLayer)
    }
    
    override func layout() {
        super.layout()
        
        // Draw checkmark path
        let path = CGMutablePath()
        let size = bounds.size
        
        // Checkmark shape: starts from left, goes down to bottom-center, then up to top-right
        let startPoint = CGPoint(x: size.width * 0.15, y: size.height * 0.5)
        let midPoint = CGPoint(x: size.width * 0.4, y: size.height * 0.25)
        let endPoint = CGPoint(x: size.width * 0.85, y: size.height * 0.75)
        
        path.move(to: startPoint)
        path.addLine(to: midPoint)
        path.addLine(to: endPoint)
        
        shapeLayer.path = path
        shapeLayer.frame = bounds
    }
}
