import Foundation
import AppKit

/// Polls the Corder Worker's `/news` feed and posts a macOS banner
/// the first time an unseen news item appears. Tap on the banner
/// opens the item's `cta_url` (if present) in the default browser.
///
/// State: a Set of seen item ids stored in UserDefaults. On the very
/// first run we seed it with whatever the feed currently contains so
/// the user doesn't get pelted with retroactive "new" banners for
/// every announcement the maintainer ever shipped.
@MainActor
enum NewsPoller {
    private static let endpoint = URL(string: "https://corder-api.empqwork.workers.dev/news")!
    private static let kSeenKey = "Corder.news.seenIds"
    private static let kSeededKey = "Corder.news.seeded"
    /// Shared by native banners and the loopback frontend endpoint.
    private static let interval: TimeInterval = 6 * 3600
    private static var cachedFeed: [[String: Any]] = []
    private static var fetchedAt: Date = .distantPast
    private static var inFlight: Task<[[String: Any]]?, Never>?

    static func feed() async -> [[String: Any]] {
        await feedIfAvailable() ?? []
    }

    static func feedIfAvailable(load: @escaping () async -> [[String: Any]]? = loadFeed) async -> [[String: Any]]? {
        guard NetworkPolicy.allows(.news) else { return nil }
        if let inFlight {
            let items = await inFlight.value
            return NetworkPolicy.allows(.news) ? items : nil
        }
        if Date().timeIntervalSince(fetchedAt) < interval { return cachedFeed }
        let task = Task { await load() }
        inFlight = task
        let items = await task.value
        inFlight = nil
        guard NetworkPolicy.allows(.news), let items else { return nil }
        fetchedAt = Date()
        cachedFeed = items
        return cachedFeed
    }

    private static func loadFeed() async -> [[String: Any]]? {
        var req = URLRequest(url: endpoint)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 10
        guard let (data, resp) = try? await NetworkPolicy.data(for: req, channel: .news),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { return nil }
        return items
    }

    private static var timer: Timer?

    static func start() {
        timer?.invalidate()
        Task { await tick() }
        let t = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            Task { @MainActor in await tick() }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private static func tick() async {
        guard let items = await fetch() else { return }
        let seenIds = Set(UserDefaults.standard.stringArray(forKey: kSeenKey) ?? [])
        let seeded = UserDefaults.standard.bool(forKey: kSeededKey)
        let currentIds = items.compactMap { $0.id }

        // First-ever poll: mark everything as seen, no banners, we
        // don't want a fresh install to surface every old announcement.
        guard seeded else {
            UserDefaults.standard.set(currentIds, forKey: kSeenKey)
            UserDefaults.standard.set(true, forKey: kSeededKey)
            FileLogger.log("NewsPoller: seeded \(currentIds.count) ids, banners armed for future items")
            return
        }

        let fresh = items.filter { !seenIds.contains($0.id) }
        guard !fresh.isEmpty else { return }
        for item in fresh {
            let body = item.body?.trimmingCharacters(in: .whitespacesAndNewlines)
            NotificationsService.post(
                title: item.title,
                body: (body?.isEmpty == false) ? body! : "Open Corder to read more.",
                action: item.ctaURL.flatMap { .openURL($0) } ?? .openLibrary
            )
            FileLogger.log("NewsPoller: posted banner for new item \(item.id)")
        }
        // Re-write seen set with the full current feed (drops stale
        // entries that the maintainer has rotated out, and adds the
        // fresh ones we just announced).
        UserDefaults.standard.set(currentIds, forKey: kSeenKey)
    }

    private static func fetch() async -> [NewsItem]? {
        guard let arr = await feedIfAvailable() else { return nil }
        return arr.compactMap { dict in
            guard let id = dict["id"] as? String, !id.isEmpty,
                  let title = dict["title"] as? String, !title.isEmpty else { return nil }
            let body = dict["body"] as? String
            let cta = (dict["cta_url"] as? String).flatMap { URL(string: $0) }
            return NewsItem(id: id, title: title, body: body, ctaURL: cta)
        }
    }
}

struct NewsItem {
    let id: String
    let title: String
    let body: String?
    let ctaURL: URL?
}
