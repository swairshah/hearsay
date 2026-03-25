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

    /// Insert text at the current cursor position, copying to clipboard permanently
    static func insert(_ text: String) {
        insertLogger.info("Inserting text: \(text.prefix(50))...")
        copyToClipboard(text)
        simulatePaste()
    }

    /// Insert text at the cursor without keeping it on the clipboard.
    /// Temporarily uses the clipboard for the paste, then restores the previous contents.
    static func insertWithoutClipboard(_ text: String) {
        insertLogger.info("Inserting text (no clipboard): \(text.prefix(50))...")
        let pasteboard = NSPasteboard.general

        // Save current clipboard contents
        let previousContents = pasteboard.string(forType: .string)
        let previousChangeCount = pasteboard.changeCount

        // Temporarily set our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Paste, then restore
        simulatePaste {
            // Restore previous clipboard contents after paste completes
            // Only restore if nothing else has changed the clipboard in the meantime
            if pasteboard.changeCount == previousChangeCount + 1 {
                pasteboard.clearContents()
                if let previous = previousContents {
                    pasteboard.setString(previous, forType: .string)
                }
                insertLogger.info("Clipboard restored")
            } else {
                insertLogger.info("Clipboard changed externally, skipping restore")
            }
        }
    }

    /// Just copy text to clipboard without pasting
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        insertLogger.info("Copied to clipboard")
    }

    // MARK: - Clipboard + Paste

    private static func simulatePaste(completion: (() -> Void)? = nil) {
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

                // Give a moment for the paste to be processed before restoring clipboard
                if let completion = completion {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        completion()
                    }
                }
            }
        }
    }
}
