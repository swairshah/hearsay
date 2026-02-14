import AppKit
import Carbon.HIToolbox
import os.log

private let insertLogger = Logger(subsystem: "com.swair.hearsay", category: "insert")

/// Inserts text at the current cursor position using Accessibility APIs
/// or clipboard + paste as fallback.
final class TextInserter {
    
    enum InsertionMethod {
        case accessibility  // Direct text insertion via AX API
        case clipboard      // Copy to clipboard + simulate Cmd+V
    }
    
    /// Insert text at the current cursor position
    static func insert(_ text: String) {
        insertLogger.info("Inserting text: \(text.prefix(50))...")
        
        // Always copy to clipboard first
        copyToClipboard(text)
        
        // Skip accessibility - just simulate paste (more reliable)
        simulatePaste()
    }
    
    /// Just copy text to clipboard without pasting
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        insertLogger.info("Copied to clipboard")
    }
    
    // MARK: - Clipboard + Paste
    
    private static func simulatePaste() {
        // Delay to ensure clipboard is ready and focus is restored
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            insertLogger.info("Simulating Cmd+V...")
            
            // Create Cmd+V key event
            let source = CGEventSource(stateID: .combinedSessionState)
            
            // Key down
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true) {
                keyDown.flags = .maskCommand
                keyDown.post(tap: .cgAnnotatedSessionEventTap)
            }
            
            // Small delay between down and up
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                let source = CGEventSource(stateID: .combinedSessionState)
                
                // Key up
                if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) {
                    keyUp.flags = .maskCommand
                    keyUp.post(tap: .cgAnnotatedSessionEventTap)
                }
                
                insertLogger.info("Paste simulated")
            }
        }
    }
}
