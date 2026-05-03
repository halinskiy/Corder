import AppKit
import AVFoundation
import ScreenCaptureKit

enum PermissionStatus {
    case granted
    case denied
    case notDetermined
}

enum PermissionsChecker {
    /// Triggers the TCC prompt on first use; returns whether we have access.
    static func checkScreenRecording() async -> PermissionStatus {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return .granted
        } catch {
            return .denied
        }
    }

    /// Reads the current TCC microphone status WITHOUT calling requestAccess.
    /// We deliberately avoid AVCaptureDevice.requestAccess(for: .audio) — for
    /// some bundle/sign configurations it silently returns false without ever
    /// surfacing a TCC prompt, which then writes a permanent .denied entry.
    /// Instead we let AVAudioEngine.start() in CaptureEngine produce the
    /// authentic prompt the first time we actually try to capture audio.
    static func checkMicrophone() -> PermissionStatus {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        NSLog("Corder: mic authorizationStatus = \(status.rawValue)")
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
