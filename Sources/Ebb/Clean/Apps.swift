import AppKit

/// An installed app, its size, when it was last opened, and what it left in ~/Library.
struct InstalledApp: Identifiable {
    struct Leftover: Identifiable, Hashable {
        let path: String
        let size: Int64
        /// Which ~/Library folder it lives in, e.g. "Caches".
        let kind: String
        var id: String { path }
    }

    let path: String
    let name: String
    let bundleID: String?
    let version: String?
    let size: Int64
    let lastUsed: Date?
    let isAppStore: Bool
    let leftovers: [Leftover]

    var id: String { path }
    var leftoversSize: Int64 { leftovers.reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { size + leftoversSize }

    /// Not opened for 90 days, or never recorded as opened.
    var isUnused: Bool { (lastUsed ?? .distantPast) < Date().addingTimeInterval(-90 * 86_400) }

    var isRunning: Bool {
        guard let bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

/// Data in ~/Library named after an app that is no longer installed.
struct OrphanedLeftover: Identifiable {
    let bundleID: String
    let items: [InstalledApp.Leftover]
    var id: String { bundleID }
    var size: Int64 { items.reduce(0) { $0 + $1.size } }
    var lastModified: Date
}

enum AppInventory {
    /// The ~/Library folders where apps keep their data, and how each names it.
    private static let leftoverFolders: [(folder: String, kind: String)] = [
        ("Application Support", "Application Support"), ("Caches", "Caches"), ("Preferences", "Preferences"),
        ("Saved Application State", "Saved state"), ("Logs", "Logs"), ("HTTPStorages", "Web storage"),
        ("WebKit", "Web storage"), ("Application Scripts", "Scripts"), ("Containers", "Sandbox container"),
        ("LaunchAgents", "Launch agent"),
    ]

    static func loadApps(protected: ProtectedLocations) -> [InstalledApp] {
        let roots = ["/Applications", NSHomeDirectory() + "/Applications"]
        var bundles: [String] = []
        for root in roots {
            for name in Scanner.listDirectory(root) {
                let path = root + "/" + name
                if name.hasSuffix(".app") {
                    bundles.append(path)
                } else if Scanner.lstatInfo(path)?.isDirectory == true {
                    // One level of folders, e.g. /Applications/Utilities or a vendor folder.
                    bundles += Scanner.listDirectory(path).filter { $0.hasSuffix(".app") }.map { path + "/" + $0 }
                }
            }
        }

        let results = AppResults(count: bundles.count)
        DispatchQueue.concurrentPerform(iterations: bundles.count) { index in
            results[index] = describe(bundles[index], protected: protected)
        }
        return results.all.compactMap { $0 }
            .filter { !($0.bundleID ?? "").hasPrefix("com.apple.") && $0.bundleID != Bundle.main.bundleIdentifier }
            .sorted { $0.totalSize > $1.totalSize }
    }

    private static func describe(_ path: String, protected: ProtectedLocations) -> InstalledApp? {
        let bundle = Bundle(path: path)
        let info = bundle?.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let bundleID = bundle?.bundleIdentifier
        let lastUsed = NSMetadataItem(url: URL(fileURLWithPath: path))?
            .value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date
        return InstalledApp(
            path: path, name: name, bundleID: bundleID,
            version: info["CFBundleShortVersionString"] as? String,
            size: Scanner.measure(path), lastUsed: lastUsed,
            isAppStore: Scanner.exists(path + "/Contents/_MASReceipt"),
            leftovers: bundleID.map { leftovers(bundleID: $0, appName: name, protected: protected) } ?? [])
    }

    /// Everything in ~/Library named after the app's bundle ID (or, for support files, its name).
    static func leftovers(bundleID: String, appName: String, protected: ProtectedLocations) -> [InstalledApp.Leftover] {
        let library = NSHomeDirectory() + "/Library/"
        var found: [InstalledApp.Leftover] = []
        for (folder, kind) in leftoverFolders {
            let base = library + folder
            guard !protected.covers(base) else { continue }
            var candidates = [base + "/" + bundleID]
            switch folder {
            case "Preferences": candidates = [base + "/\(bundleID).plist"]
            case "Saved Application State": candidates = [base + "/\(bundleID).savedState"]
            case "HTTPStorages": candidates += [base + "/\(bundleID).binarycookies"]
            case "Application Support", "Caches", "Logs": candidates += [base + "/" + appName]
            case "LaunchAgents":
                candidates = Scanner.listDirectory(base).filter { $0.hasPrefix(bundleID) && $0.hasSuffix(".plist") }.map { base + "/" + $0 }
            default: break
            }
            for path in candidates where Scanner.exists(path) {
                found.append(InstalledApp.Leftover(path: path, size: Scanner.measure(path, protected: protected), kind: kind))
            }
        }
        return found
    }

    /// Folders and preference files named like a bundle ID whose app isn't installed anymore.
    /// Conservative: ignores Apple's own, anything touched in the last 30 days, and IDs that
    /// belong to an installed app's helpers.
    static func orphans(installed: [InstalledApp], protected: ProtectedLocations) -> [OrphanedLeftover] {
        let library = NSHomeDirectory() + "/Library/"
        let installedIDs = Set(installed.compactMap(\.bundleID))
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        var byID: [String: (items: [InstalledApp.Leftover], modified: Date)] = [:]

        for (folder, kind) in leftoverFolders where folder != "LaunchAgents" {
            let base = library + folder
            guard !protected.covers(base) else { continue }
            for name in Scanner.listDirectory(base) {
                var id = name
                for suffix in [".plist", ".savedState", ".binarycookies"] where id.hasSuffix(suffix) {
                    id = String(id.dropLast(suffix.count))
                }
                guard looksLikeBundleID(id), !id.lowercased().hasPrefix("com.apple."),
                      !installedIDs.contains(where: { id.hasPrefix($0) || $0.hasPrefix(id) }),
                      NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) == nil else { continue }
                let path = base + "/" + name
                guard let info = Scanner.lstatInfo(path), info.modified < cutoff else { continue }
                let item = InstalledApp.Leftover(path: path, size: Scanner.measure(path, protected: protected), kind: kind)
                let previous = byID[id] ?? ([], .distantPast)
                byID[id] = (previous.items + [item], max(previous.modified, info.modified))
            }
        }
        return byID.map { OrphanedLeftover(bundleID: $0.key, items: $0.value.items, lastModified: $0.value.modified) }
            .filter { $0.size >= 100_000 }
            .sorted { $0.size > $1.size }
    }

    /// Reverse-DNS with at least three parts, e.g. com.example.App.
    private static func looksLikeBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".")
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }
}

/// Results written from `concurrentPerform` by index.
private final class AppResults: @unchecked Sendable {
    private var storage: [InstalledApp?]
    private let lock = NSLock()
    init(count: Int) { storage = Array(repeating: nil, count: count) }
    subscript(index: Int) -> InstalledApp? {
        get { lock.lock(); defer { lock.unlock() }; return storage[index] }
        set { lock.lock(); storage[index] = newValue; lock.unlock() }
    }
    var all: [InstalledApp?] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Loads the app list off the main thread and turns choices into cleanup items.
@Observable @MainActor
final class AppsModel {
    enum State { case idle, loading, ready }

    private(set) var state: State = .idle
    private(set) var apps: [InstalledApp] = []
    private(set) var orphans: [OrphanedLeftover] = []
    var selectedOrphans: Set<String> = []

    var unusedApps: [InstalledApp] { apps.filter(\.isUnused) }

    func load(protected: ProtectedLocations) {
        if case .loading = state { return }
        state = .loading
        Task {
            let (apps, orphans) = await Task.detached(priority: .utility) {
                let apps = AppInventory.loadApps(protected: protected)
                return (apps, AppInventory.orphans(installed: apps, protected: protected))
            }.value
            self.apps = apps
            self.orphans = orphans
            selectedOrphans.formIntersection(Set(orphans.map(\.id)))
            state = .ready
        }
    }

    /// Uninstalling moves the app and its leftovers to the Trash, so it can be undone.
    func uninstallItem(_ app: InstalledApp) -> JunkItem {
        let targets = [TrashTarget(path: app.path, size: app.size)] + app.leftovers.map { TrashTarget(path: $0.path, size: $0.size) }
        return JunkItem(id: "app:" + app.path, title: "Uninstall \(app.name)",
                        detail: "App and \(app.leftovers.count) related item\(app.leftovers.count == 1 ? "" : "s")",
                        explanation: "Moves the app and the data it keeps in ~/Library to the Trash.",
                        size: app.totalSize, safety: .review, action: .trash(targets), isPreselected: false,
                        revealPath: app.path)
    }

    func orphanItems() -> [JunkItem] {
        orphans.filter { selectedOrphans.contains($0.id) }.map(orphanItem)
    }

    func orphanItem(_ orphan: OrphanedLeftover) -> JunkItem {
        JunkItem(id: "orphan:" + orphan.bundleID, title: orphan.bundleID,
                 detail: orphan.items.map(\.kind).joined(separator: ", "),
                 explanation: "No installed app uses this ID. It's usually left behind by an app you deleted.",
                 size: orphan.size, safety: .review,
                 action: .trash(orphan.items.map { TrashTarget(path: $0.path, size: $0.size) }), isPreselected: false,
                 revealPath: orphan.items.first?.path)
    }
}
