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
        // CGRequestScreenCaptureAccess triggers the system permission dialog (macOS 10.15+)
        CGRequestScreenCaptureAccess()
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
