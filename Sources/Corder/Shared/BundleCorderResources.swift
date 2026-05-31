import Foundation

extension Bundle {
    /// Locator for `Corder_Corder.bundle` (the SwiftPM resource bundle
    /// that carries the Web frontend + bundled icons). DO NOT replace
    /// callers with `Bundle.module` — SwiftPM auto-generates
    /// `Bundle.module`'s accessor as
    ///   `Bundle.main.bundleURL.appendingPathComponent("Corder_Corder.bundle")`
    /// which for a .app bundle resolves to the .app ROOT, NOT to
    /// `Contents/Resources/`. The shipped build-app.sh puts the bundle
    /// in `Contents/Resources/` (codesign refuses anything in the .app
    /// root, so we can't keep both), so on every tester Mac `Bundle.module`
    /// fatalError'd with "could not load resource bundle: from
    /// /Applications/Corder.app/Corder_Corder.bundle". This helper checks
    /// all the realistic paths and gracefully returns nil instead of
    /// trapping the whole process.
    static let corderResources: Bundle? = {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("Corder_Corder.bundle"))
        }
        candidates.append(Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Corder_Corder.bundle"))
        candidates.append(Bundle.main.bundleURL
            .appendingPathComponent("Corder_Corder.bundle"))
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent("Corder_Corder.bundle"))
        }
        for url in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if let b = Bundle(url: url) { return b }
            }
        }
        return nil
    }()
}
