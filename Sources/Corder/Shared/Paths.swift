import Foundation

enum AppPaths {
    static var supportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Corder", isDirectory: true)
    }
    static var databaseURL: URL { supportRoot.appendingPathComponent("corder.db") }
    static var modelsDir: URL { supportRoot.appendingPathComponent("models", isDirectory: true) }
    static var recordingsDir: URL { supportRoot.appendingPathComponent("recordings", isDirectory: true) }

    static func ensureExists() throws {
        for url in [supportRoot, modelsDir, recordingsDir] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    static func recordingDir(for meetingId: String) -> URL {
        recordingsDir.appendingPathComponent(meetingId, isDirectory: true)
    }
}
