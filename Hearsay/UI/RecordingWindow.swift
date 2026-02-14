import AppKit

/// Floating borderless window that displays the recording indicator.
/// Appears near the bottom center of the active screen.
final class RecordingWindow: NSPanel {
    
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
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        
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
        positionOnScreen(width: Constants.indicatorWidth)
        
        // Ensure window is visible and on top
        alphaValue = 0
        orderFrontRegardless()
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Constants.indicatorFadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }
    
    func fadeOut(completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Constants.indicatorFadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
            completion?()
        })
    }
}
