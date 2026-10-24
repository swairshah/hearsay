import AppKit
import AVFoundation
import CoreGraphics

/// Manages permission checking and requesting for the app.
final class PermissionsManager {
    
    enum Permission {
        case microphone
        case accessibility
        case screenRecording
    }
    
    enum PermissionStatus {
        case granted
        case denied
        case notDetermined
    }
    
    // MARK: - Check Permissions
    
    static func checkMicrophone() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }
    
    static func checkAccessibility() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }
    
    /// Check screen recording permission using the official API
    static func checkScreenRecording() -> PermissionStatus {
        // CGPreflightScreenCaptureAccess returns true if permission is granted
        // This is the official way to check screen recording permission (macOS 10.15+)
        if CGPreflightScreenCaptureAccess() {
            return .granted
        }
        return .denied
    }
    
    static var allPermissionsGranted: Bool {
        checkMicrophone() == .granted && checkAccessibility() == .granted
    }
    
    // MARK: - Request Permissions
    
    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
    
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    /// Trigger screen recording permission prompt
    /// This will cause macOS to show the permission dialog if not already granted
    static func requestScreenRecording() {
        screenRecordingRequestedAt = Date()
        // CGRequestScreenCaptureAccess triggers the system permission dialog (macOS 10.15+)
        CGRequestScreenCaptureAccess()
    }

    private static var screenRecordingRequestedAt: Date?

    /// True shortly after we asked for Screen Recording and it isn't active yet.
    /// System Settings then offers "Quit & Reopen", but it only quits menu-bar
    /// (LSUIElement) apps — so we reopen ourselves on the way out.
    static var shouldRelaunchAfterQuit: Bool {
        guard let requestedAt = screenRecordingRequestedAt else { return false }
        return Date().timeIntervalSince(requestedAt) < 10 * 60 && !CGPreflightScreenCaptureAccess()
    }

    // MARK: - Relaunch

    /// Start a fresh copy of the app once this process has exited. The caller
    /// still has to terminate. (`NSWorkspace.openApplication` on our own URL
    /// just activates the running instance, so it can't be used for this.)
    static func scheduleRelaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundleURL.path
        ]
        try? task.run()
    }
    
    // MARK: - Open Settings
    
    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
    
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
