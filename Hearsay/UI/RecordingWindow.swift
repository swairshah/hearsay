import AppKit
import os.log

private let logger = Logger(subsystem: "com.swair.hearsay", category: "window")

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
        
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        
        // Start hidden
        alphaValue = 0
    }
    
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    
    // MARK: - Positioning
    
    func positionOnScreen(width: CGFloat? = nil) {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
        guard let screen = targetScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        
        let screenFrame = screen.visibleFrame
        let newWidth = width ?? frame.size.width
        
        // Center horizontally, position near bottom
        let x = screenFrame.midX - newWidth / 2
        let y = screenFrame.minY + Constants.indicatorBottomMargin
        
        let newFrame = NSRect(x: x, y: y, width: newWidth, height: Constants.indicatorHeight)
        setFrame(newFrame, display: true, animate: alphaValue > 0)
    }
    
    // MARK: - Animation
    
    func fadeIn() {
        // Increment generation to cancel any pending fadeOut completion
        animationGeneration += 1
        let currentGeneration = animationGeneration
        
        logger.debug("fadeIn called (generation \(currentGeneration))")
        
        positionOnScreen(width: Constants.indicatorWidth)
        
        // Cancel any ongoing animations
        animator().alphaValue = alphaValue
        
        // Ensure window is visible and on top
        orderFrontRegardless()
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Constants.indicatorFadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }
    
    func fadeOut(completion: (() -> Void)? = nil) {
        // Capture current generation to check in completion handler
        let currentGeneration = animationGeneration
        
        logger.debug("fadeOut called (generation \(currentGeneration))")
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Constants.indicatorFadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            
            // Only order out if no new fadeIn was called during animation
            if self.animationGeneration == currentGeneration {
                logger.debug("fadeOut completing - ordering out (generation \(currentGeneration))")
                self.orderOut(nil)
            } else {
                logger.debug("fadeOut cancelled - generation changed from \(currentGeneration) to \(self.animationGeneration)")
            }
            completion?()
        })
    }
}
