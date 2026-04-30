import Foundation
import Combine
import GRDB

@MainActor
final class AppContext: ObservableObject {
    static let shared = AppContext()
    private init() {}

    private(set) lazy var dbq: DatabaseQueue = {
        do { return try Database.openShared() }
        catch { fatalError("Failed to open DB: \(error)") }
    }()

    private(set) lazy var repo: MeetingRepository = MeetingRepository(dbq: dbq)
    let server = LocalServer()
    let capture = CaptureEngine()

    @Published var recordingState: RecordingState = .idle

    // Persisted source preference (Full screen vs last picked window stays remembered).
    @Published var sourceMode: SourceMode = SourceMode(
        rawValue: UserDefaults.standard.string(forKey: "Corder.sourceMode") ?? "full"
    ) ?? .full {
        didSet { UserDefaults.standard.set(sourceMode.rawValue, forKey: "Corder.sourceMode") }
    }
}

enum SourceMode: String {
    case full   // full screen
    case window // pick a window each time
}

enum RecordingState: Equatable {
    case idle
    case recording(meetingId: String, startedAt: Date)
    case stopping
}
