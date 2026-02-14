import AppKit

/// The visual content of the recording indicator pill.
/// Minimal design: waveform when recording, waveform + dots when transcribing.
final class RecordingIndicator: NSView {
    
    enum State {
        case recording
        case transcribing
        case done
        case error(String)
    }
    
    private(set) var state: State = .recording
    
    // UI Elements
    private let waveformView = WaveformView()
    private let dotsView = AnimatedDotsView()
    
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
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.95).cgColor
        layer?.cornerRadius = bounds.height / 2
        
        addSubview(waveformView)
        addSubview(dotsView)
        
        dotsView.isHidden = true
    }
    
    override func layout() {
        super.layout()
        
        layer?.cornerRadius = bounds.height / 2
        
        let waveformWidth: CGFloat = 40
        let dotsWidth: CGFloat = 36
        let contentHeight: CGFloat = 20
        
        switch state {
        case .recording, .done, .error:
            // Center waveform
            waveformView.frame = NSRect(
                x: (bounds.width - waveformWidth) / 2,
                y: (bounds.height - contentHeight) / 2,
                width: waveformWidth,
                height: contentHeight
            )
            waveformView.isHidden = false
            dotsView.isHidden = true
            
        case .transcribing:
            // Just show dots centered (hide waveform)
            waveformView.isHidden = true
            dotsView.frame = NSRect(
                x: (bounds.width - dotsWidth) / 2,
                y: (bounds.height - contentHeight) / 2,
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
    
    var level: Float = 0 {
        didSet {
            if isAnimating {
                updateBars()
            }
        }
    }
    
    var isAnimating = true
    
    private var bars: [CALayer] = []
    private let barCount = 7
    private var previousLevels: [Float] = []
    
    override init(frame frameRect: NSRect) {
        previousLevels = Array(repeating: 0.3, count: barCount)
        super.init(frame: frameRect)
        setupBars()
    }
    
    required init?(coder: NSCoder) {
        previousLevels = Array(repeating: 0.3, count: barCount)
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
            // Set all bars to medium height
            previousLevels = Array(repeating: 0.4, count: barCount)
            updateBars()
        }
    }
    
    override func layout() {
        super.layout()
        updateBars()
    }
    
    private func updateBars() {
        let barWidth: CGFloat = 3
        let spacing: CGFloat = 5
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        let startX = (bounds.width - totalWidth) / 2
        let maxHeight = bounds.height - 4
        let minHeight: CGFloat = 6
        
        if isAnimating {
            // Shift previous levels and add new one with some variation
            previousLevels.removeFirst()
            let jitteredLevel = level + Float.random(in: -0.15...0.15)
            previousLevels.append(max(0.1, min(1, jitteredLevel)))
        }
        
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        
        for (index, bar) in bars.enumerated() {
            let barLevel = previousLevels[index]
            let height = minHeight + CGFloat(barLevel) * (maxHeight - minHeight)
            
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
