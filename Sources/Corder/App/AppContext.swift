import Foundation
import GRDB

final class AppContext {
    static let shared = AppContext()
    private init() {}

    private(set) lazy var dbq: DatabaseQueue = {
        do { return try Database.openShared() }
        catch { fatalError("Failed to open DB: \(error)") }
    }()

    private(set) lazy var repo: MeetingRepository = MeetingRepository(dbq: dbq)
    let server = LocalServer()
}
