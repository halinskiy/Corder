import Foundation

/// Lightweight file logger. NSLog from a `LSUIElement` app launched via `open`
/// does not always reach `log show` or any visible stream, so we additionally
/// append to a stable file we can tail during debugging.
enum FileLogger {
    static let url: URL = URL(fileURLWithPath: "/tmp/corder.log")

    private static let queue = DispatchQueue(label: "com.3mpq.corder.logger")
    private static var isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func log(_ message: String, file: String = #fileID, line: Int = #line) {
        let stamp = isoFormatter.string(from: Date())
        let line = "\(stamp) \(file):\(line) \(message)\n"
        NSLog("Corder: %@", message)
        queue.async {
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                } else {
                    try? data.write(to: url)
                }
            }
        }
    }
}
