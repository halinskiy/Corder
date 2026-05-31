import Foundation

/// Observable model that drives `UpdateView`. The Sparkle driver
/// pushes phase / progress changes into this object; SwiftUI
/// re-renders. Single source of truth so the view doesn't talk to
/// Sparkle directly.
@MainActor
final class UpdateState: ObservableObject {
    @Published var phase: UpdatePhase = .available
    @Published var versionString: String = ""
    @Published var releaseNotes: String? = nil
    @Published var progress: Double = 0
    @Published var expectedBytes: UInt64 = 0
    @Published var receivedBytes: UInt64 = 0

    var versionTitle: String {
        versionString.isEmpty ? "Update available" : "Version \(versionString)"
    }

    var primaryLabel: String {
        switch phase {
        case .available:        return "Update"
        case .downloading:      return "Downloading…"
        case .extracting:       return "Preparing…"
        case .readyToInstall:   return "Install and relaunch"
        case .installing:       return "Installing…"
        case .installed:        return "Done"
        case .error:            return "Retry"
        case .upToDate:         return "OK"
        }
    }

    var primaryEnabled: Bool {
        switch phase {
        case .available, .readyToInstall, .error, .installed, .upToDate: return true
        case .downloading, .extracting, .installing:                     return false
        }
    }

    var phaseStatusLine: String? {
        switch phase {
        case .available:
            return "Tap Update to download and install."
        case .downloading:
            if expectedBytes > 0 {
                let mb = Double(expectedBytes) / 1_048_576.0
                return String(format: "Downloading %.1f MB", mb)
            }
            return "Downloading the update"
        case .extracting:
            return "Unpacking the update"
        case .readyToInstall:
            return "Ready to install. We'll relaunch Corder."
        case .installing:
            return "Installing. Don't quit yet."
        case .installed:
            return "Update installed."
        case .error(let message):
            return message
        case .upToDate:
            return "You are on the latest version."
        }
    }
}

enum UpdatePhase: Equatable {
    case available
    case downloading
    case extracting
    case readyToInstall
    case installing
    case installed
    case error(String)
    case upToDate

    var showsProgress: Bool {
        switch self {
        case .downloading, .extracting: return true
        default: return false
        }
    }
}
