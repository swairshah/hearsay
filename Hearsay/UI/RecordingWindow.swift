import AppKit
import os.log

private let logger = Logger(subsystem: "com.swair.hearsay", category: "window")

// File logger for debugging - writes to ~/Library/Application Support/Hearsay/debug.log
private func fileLog(_ message: String) {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let logURL = appSupport.appendingPathComponent("Hearsay/debug.log")
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let entry = "[\(timestamp)] [RecordingWindow] \(message)\n"
    if let data = entry.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logURL)
        }
    }
}

/// Floating borderless window that displays the recording indicator.
/// Appears near the bottom center of the active screen.
final class RecordingWindow: NSPanel {
    
    /// Counter to track animation generations and prevent race conditions
    private var animationGeneration: Int = 0
    
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Constants.indicatorWidth, height: Constants.indicatorHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        level = .statusBar  // High level to appear above most windows including fullscreen
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .fullScreenDisallowsTiling]
        
        // Start hidden
        alphaValue = 0
    }
    
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    
    // MARK: - Positioning
    
    func positionOnScreen(width: CGFloat? = nil) {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
        guard let screen = targetScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            logger.error("positionOnScreen: No screen found!")
            return
        }
        
        let screenFrame = screen.visibleFrame
        let newWidth = width ?? frame.size.width
        
        // Center horizontally, position near bottom
        let x = screenFrame.midX - newWidth / 2
        let y = screenFrame.minY + Constants.indicatorBottomMargin
        
        let newFrame = NSRect(x: x, y: y, width: newWidth, height: Constants.indicatorHeight)
        logger.info("positionOnScreen: placing at x=\(Int(x)), y=\(Int(y)), screen=\(screen.localizedName), screenFrame=\(Int(screenFrame.minX)),\(Int(screenFrame.minY))-\(Int(screenFrame.maxX)),\(Int(screenFrame.maxY))")
        setFrame(newFrame, display: true, animate: alphaValue > 0)
    }
    
    // MARK: - Animation
    
    func fadeIn() {
        // Increment generation to cancel any pending fadeOut completion
        animationGeneration += 1
        let currentGeneration = animationGeneration
        
        print("FADEIN called gen=\(currentGeneration) alpha=\(self.alphaValue) visible=\(self.isVisible)")
        logger.info("fadeIn called (generation \(currentGeneration), current alpha: \(self.alphaValue), isVisible: \(self.isVisible))")
        
        // Detailed logging for debugging pill visibility issues
        let screenInfo = NSScreen.screens.enumerated().map { "screen\($0.offset):\($0.element.frame)" }.joined(separator: ", ")
        let contentInfo = "contentView=\(contentView != nil), hidden=\(contentView?.isHidden ?? true), needsDisplay=\(contentView?.needsDisplay ?? false)"
        fileLog("fadeIn gen=\(currentGeneration) alpha=\(self.alphaValue) frame=\(self.frame) level=\(self.level.rawValue) \(contentInfo) screens=[\(screenInfo)]")
        
        // Reset window state to fix potential corruption after long runtime
        if isVisible && alphaValue == 0 {
            // Window thinks it's visible but alpha is 0 - order out first to reset state
            orderOut(nil)
        }
        
        positionOnScreen(width: Constants.indicatorWidth)
        
        // Immediately snap alpha to a small value to ensure visibility
        // Don't use animator() here - we want instant, not animated
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            self.alphaValue = max(self.alphaValue, 0.01)
        }
        
        // Ensure window is visible and on top
        orderFrontRegardless()
        
        // Force window and content to redisplay (fixes state corruption after long runtime)
        contentView?.needsDisplay = true
        contentView?.displayIfNeeded()
        display()
        
        logger.info("fadeIn: after orderFront, alpha: \(self.alphaValue), isVisible: \(self.isVisible), level=\(self.level.rawValue), frame=\(Int(self.frame.origin.x)),\(Int(self.frame.origin.y))")
        fileLog("fadeIn after orderFront: frame=\(self.frame) visible=\(self.isVisible) onScreen=\(self.screen?.localizedName ?? "nil")")
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Constants.indicatorFadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        } completionHandler: {
            logger.info("fadeIn animation complete (generation \(currentGeneration)), alpha: \(self.alphaValue)")
        }
    }
    
    func fadeOut(completion: (() -> Void)? = nil) {
        // Capture current generation to check in completion handler
        let currentGeneration = animationGeneration
        
        logger.info("fadeOut called (generation \(currentGeneration), current alpha: \(self.alphaValue), isVisible: \(self.isVisible))")
        fileLog("fadeOut called gen=\(currentGeneration) alpha=\(self.alphaValue)")
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Constants.indicatorFadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            
            // Only order out if no new fadeIn was called during animation
            if self.animationGeneration == currentGeneration {
                logger.info("fadeOut completing - ordering out (generation \(currentGeneration))")
                self.orderOut(nil)
            } else {
                logger.info("fadeOut cancelled - generation changed from \(currentGeneration) to \(self.animationGeneration)")
            }
            completion?()
        })
    }
}
