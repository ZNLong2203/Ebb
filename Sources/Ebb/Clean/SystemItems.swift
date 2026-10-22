import AppKit

/// A launchd job that starts at login (agent) or at boot (daemon).
struct BackgroundItem: Identifiable {
    enum Scope: String {
        case user = "Your account"
        case allUsers = "All users"
        case system = "System daemon"
    }

    let path: String
    let label: String
    let program: String?
    let scope: Scope
    let owner: String?
    let runsAtLoad: Bool
    let keepsRunning: Bool
    /// The program it launches no longer exists, usually because its app was deleted.
    let isBroken: Bool

    var id: String { path }
    /// Only your own agents can be removed without an administrator password.
    var isRemovable: Bool { scope == .user }
}

enum BackgroundItems {
    static func load() -> [BackgroundItem] {
        let sources: [(String, BackgroundItem.Scope)] = [
            (NSHomeDirectory() + "/Library/LaunchAgents", .user),
            ("/Library/LaunchAgents", .allUsers),
            ("/Library/LaunchDaemons", .system),
        ]
        var items: [BackgroundItem] = []
        for (folder, scope) in sources {
            for name in Scanner.listDirectory(folder) where name.hasSuffix(".plist") {
                let path = folder + "/" + name
                guard let data = FileManager.default.contents(atPath: path),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { continue }
                let label = plist["Label"] as? String ?? (name as NSString).deletingPathExtension
                let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
                // Jobs registered by an app via SMAppService point inside the app and can't be checked here.
                let checkable = plist["BundleProgram"] == nil && (program?.hasPrefix("/") ?? false)
                let broken = checkable && !Scanner.exists((program! as NSString).expandingTildeInPath)
                items.append(BackgroundItem(
                    path: path, label: label, program: program, scope: scope,
                    owner: owner(label: label, program: program, plist: plist),
                    runsAtLoad: plist["RunAtLoad"] as? Bool ?? false,
                    keepsRunning: plist["KeepAlive"] != nil, isBroken: broken))
            }
        }
        return items.sorted { ($0.isBroken ? 0 : 1, $0.scope.rawValue, $0.label) < ($1.isBroken ? 0 : 1, $1.scope.rawValue, $1.label) }
    }

    /// Best guess at the app a job belongs to: its declared bundle, an app in its path, or its label.
    private static func owner(label: String, program: String?, plist: [String: Any]) -> String? {
        if let ids = plist["AssociatedBundleIdentifiers"] as? [String], let id = ids.first, let name = appName(bundleID: id) {
            return name
        }
        if let program, let range = program.range(of: ".app/") {
            return ((String(program[..<range.lowerBound]) as NSString).lastPathComponent)
        }
        var parts = label.split(separator: ".").map(String.init)
        while parts.count >= 2 {
            if let name = appName(bundleID: parts.joined(separator: ".")) { return name }
            parts.removeLast()
        }
        return nil
    }

    private static func appName(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return (url.lastPathComponent as NSString).deletingPathExtension
    }
}

/// One-click fixes that need macOS's own tools. Admin tasks show the standard password dialog.
struct MaintenanceTask: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let needsAdmin: Bool
    let command: String

    static let all: [MaintenanceTask] = [
        MaintenanceTask(id: "snapshots", title: "Thin Time Machine local snapshots",
                        detail: "Local snapshots are a big part of \"System Data\". macOS clears them when space runs out; this frees that space now. Your Time Machine backup disk isn't touched.",
                        symbol: "clock.arrow.circlepath", needsAdmin: true,
                        command: "tmutil thinlocalsnapshots / 999999999999 4"),
        MaintenanceTask(id: "dns", title: "Flush DNS cache",
                        detail: "Fixes websites that won't load after a network or DNS change.",
                        symbol: "network", needsAdmin: true,
                        command: "dscacheutil -flushcache; killall -HUP mDNSResponder"),
        MaintenanceTask(id: "launchservices", title: "Fix duplicate apps in \"Open With\"",
                        detail: "Rebuilds the Launch Services database. Finder may take a moment to show icons again.",
                        symbol: "square.stack.3d.down.right", needsAdmin: false,
                        command: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user"),
        MaintenanceTask(id: "spotlight", title: "Rebuild the Spotlight index",
                        detail: "For when Spotlight stops finding files. Your Mac will be busy re-indexing for a while afterwards.",
                        symbol: "magnifyingglass", needsAdmin: true,
                        command: "mdutil -E /"),
    ]

    /// Runs the command, asking for an administrator password through macOS when needed.
    func run() async -> (succeeded: Bool, output: String) {
        let shell = needsAdmin
            ? "osascript -e 'do shell script \"\(command.replacingOccurrences(of: "\"", with: "\\\\\""))\" with administrator privileges'"
            : command
        let (status, output) = await Cleaner.run(shell)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if status != 0, trimmed.contains("User canceled") || trimmed.contains("-128") {
            return (false, "Cancelled.")
        }
        return (status == 0, trimmed)
    }
}

@Observable @MainActor
final class SystemModel {
    private(set) var items: [BackgroundItem] = []
    private(set) var isLoaded = false
    var selection: Set<String> = []
    /// Task id → (is running, last result).
    private(set) var running: Set<String> = []
    private(set) var results: [String: (succeeded: Bool, output: String)] = [:]

    func load() {
        Task {
            items = await Task.detached { BackgroundItems.load() }.value
            selection.formIntersection(Set(items.map(\.id)))
            isLoaded = true
        }
    }

    func run(_ task: MaintenanceTask) {
        guard !running.contains(task.id) else { return }
        running.insert(task.id)
        results[task.id] = nil
        Task {
            let result = await task.run()
            results[task.id] = result
            running.remove(task.id)
        }
    }

    func cleanupItems() -> [JunkItem] {
        items.filter { selection.contains($0.id) }.compactMap(cleanupItem)
    }

    func cleanupItem(_ item: BackgroundItem) -> JunkItem? {
        guard item.isRemovable else { return nil }
        return {
            JunkItem(id: "agent:" + item.path, title: item.owner.map { "\($0) (\(item.label))" } ?? item.label,
                     detail: item.program ?? item.path,
                     explanation: item.isBroken
                        ? "Its program no longer exists, so it only fails at every login."
                        : "Stops this job from starting at login. The app itself stays installed.",
                     size: Scanner.lstatInfo(item.path)?.allocated ?? 0, safety: item.isBroken ? .safe : .review,
                     action: .launchAgent(TrashTarget(path: item.path, size: Scanner.lstatInfo(item.path)?.allocated ?? 0)),
                     isPreselected: false, revealPath: item.path)
        }()
    }
}
