import Foundation
import GRDB

enum Database {
    static func openShared() throws -> DatabaseQueue {
        try AppPaths.ensureExists()
        let dbq = try DatabaseQueue(path: AppPaths.databaseURL.path)
        try Migrations.register().migrate(dbq)
        return dbq
    }
}
