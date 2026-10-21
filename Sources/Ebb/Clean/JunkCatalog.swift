import AppKit

enum Safety: Int, Comparable, CaseIterable {
    /// Regenerated automatically; nothing is lost.
    case safe
    /// Rebuildable, but costs time or bandwidth to get back. Worth a look first.
    case review
    /// May contain data you care about. Never pre-selected.
    case careful

    static func < (a: Safety, b: Safety) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        case .careful: "Careful"
        }
    }
}

/// One path to move to the Trash, with its measured size so progress and undo stay accurate.
struct TrashTarget: Hashable {
    let path: String
    let size: Int64
}

enum CleanAction: Hashable {
    /// Move these paths to the Trash (undoable).
    case trash([TrashTarget])
    /// Run a tool's own cleanup command through a login shell (not undoable).
    case command(String)
    /// Ask Finder to empty the Trash.
    case emptyTrash

    var isUndoable: Bool { if case .trash = self { true } else { false } }
}

struct JunkItem: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let explanation: String
    let size: Int64
    let safety: Safety
    let action: CleanAction
    let isPreselected: Bool
    var revealPath: String?
}

struct JunkGroup: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let items: [JunkItem]
    var total: Int64 { items.reduce(0) { $0 + $1.size } }
}

/// Knows where developer tools and apps keep rebuildable data, and how each should be cleaned.
///
/// Folders are always handled whole or through the tool's own command: deciding file by file
/// from modification dates is how cleaners break apps.
struct JunkCatalog {
    let result: ScanResult
    /// Receives the folder being measured, so the UI never looks stuck during this phase.
    var progress = ScanProgress()
    private let home = NSHomeDirectory()
    private let fm = FileManager.default

    func groups() -> [JunkGroup] {
        // Anything under 1 MB isn't worth a row (except the Trash, which is cleaned as a whole).
        [packageCaches(), docker(), xcode(), editors(), projects(), appCaches(), leftovers()]
            .map { JunkGroup(id: $0.id, title: $0.title, symbol: $0.symbol,
                             items: $0.items.filter { $0.size >= 1 << 20 || $0.action == .emptyTrash }) }
            .filter { !$0.items.isEmpty }
    }

    // MARK: - Groups

    private func packageCaches() -> JunkGroup {
        var items: [JunkItem] = []
        func cache(_ id: String, _ title: String, _ paths: [String], why: String, safety: Safety = .safe) {
            let found = targets(paths.map(expand))
            let size = found.reduce(0) { $0 + $1.size }
            guard size > 0 else { return }
            items.append(JunkItem(id: id, title: title, detail: found.map { abbreviate($0.path) }.joined(separator: ", "),
                                  explanation: why, size: size, safety: safety, action: .trash(found),
                                  isPreselected: safety == .safe, revealPath: found.first?.path))
        }
        cache("npm", "npm cache", ["~/.npm/_cacache", "~/.npm/_npx", "~/.npm/_logs"],
              why: "Packages npm downloaded before. npm fetches them again on the next install.")
        cache("yarn", "Yarn cache", ["~/Library/Caches/Yarn", "~/.yarn/berry/cache"],
              why: "Yarn's offline package cache. It refills on the next install.")
        cache("bun", "Bun cache", ["~/.bun/install/cache"], why: "Bun's package cache. It refills on the next install.")
        cache("pip", "pip cache", ["~/Library/Caches/pip", "~/.cache/pip"],
              why: "Wheels and downloads pip keeps around. Installed packages are not affected.")
        cache("uv", "uv cache", ["~/.cache/uv"], why: "uv's package cache. Existing virtualenvs keep working.")
        cache("homebrew", "Homebrew downloads", ["~/Library/Caches/Homebrew"],
              why: "Bottles and installers Homebrew already installed. Installed software is not affected.")
        cache("gradle", "Gradle caches", ["~/.gradle/caches"], why: "Dependencies and build outputs Gradle downloads again when needed.")
        cache("cargo", "Cargo registry", ["~/.cargo/registry/cache", "~/.cargo/registry/src"],
              why: "Crate downloads Cargo fetches again when a project builds.")
        cache("cocoapods", "CocoaPods cache", ["~/Library/Caches/CocoaPods"], why: "Pod downloads. `pod install` fetches them again.")
        cache("huggingface", "Hugging Face models", ["~/.cache/huggingface"],
              why: "AI models downloaded by Python libraries. Safe to remove, but big models take a long time to download again.",
              safety: .review)

        for base in condaInstalls() {
            let pkgs = base + "/pkgs"
            let size = sizeOf(pkgs)
            guard size > 0 else { continue }
            items.append(JunkItem(id: "conda:" + base, title: "Conda package cache", detail: abbreviate(pkgs),
                                  explanation: "Package tarballs and unused package versions. Runs `conda clean --all`, which keeps every environment working.",
                                  size: size, safety: .safe, action: .command("'\(base)/bin/conda' clean --all --yes"),
                                  isPreselected: true, revealPath: pkgs))
        }
        if let pnpm = ["~/Library/pnpm/store", "~/.local/share/pnpm/store"].map(expand).first(where: Scanner.exists) {
            let size = sizeOf(pnpm)
            if size > 0 {
                items.append(JunkItem(id: "pnpm", title: "pnpm store", detail: abbreviate(pnpm),
                                      explanation: "Runs `pnpm store prune`, which removes only packages no project references.",
                                      size: size, safety: .safe, action: .command("pnpm store prune"), isPreselected: false, revealPath: pnpm))
            }
        }
        let goCache = expand("~/go/pkg/mod")
        if Scanner.exists(goCache), sizeOf(goCache) > 0 {
            items.append(JunkItem(id: "go", title: "Go module cache", detail: abbreviate(goCache),
                                  explanation: "Runs `go clean -modcache`. Go downloads modules again on the next build.",
                                  size: sizeOf(goCache), safety: .safe, action: .command("go clean -modcache"), isPreselected: true, revealPath: goCache))
        }
        return JunkGroup(id: "packages", title: "Package manager caches", symbol: "shippingbox", items: items.sorted { $0.size > $1.size })
    }

    private func docker() -> JunkGroup {
        let image = expand("~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        guard !result.protected.covers(image), Scanner.exists(image) else {
            return JunkGroup(id: "docker", title: "Docker", symbol: "cube.box", items: [])
        }
        let item = JunkItem(id: "docker", title: "Unused Docker data", detail: "Docker Desktop disk image: \(abbreviate(image))",
                            explanation: "Runs `docker system prune -f`: removes stopped containers, unused networks, dangling images and build cache. Volumes and images in use are kept. Docker Desktop must be running, and it gives the space back to macOS shortly after.",
                            size: sizeOf(image), safety: .careful, action: .command("docker system prune -f"),
                            isPreselected: false, revealPath: image)
        return JunkGroup(id: "docker", title: "Docker", symbol: "cube.box", items: [item])
    }

    private func xcode() -> JunkGroup {
        var items: [JunkItem] = []
        func folder(_ id: String, _ title: String, _ path: String, safety: Safety, why: String) {
            let full = expand(path)
            let size = sizeOf(full)
            guard size > 0 else { return }
            items.append(JunkItem(id: id, title: title, detail: abbreviate(full), explanation: why, size: size,
                                  safety: safety, action: .trash([TrashTarget(path: full, size: size)]),
                                  isPreselected: safety == .safe, revealPath: full))
        }
        folder("deriveddata", "Xcode DerivedData", "~/Library/Developer/Xcode/DerivedData", safety: .safe,
               why: "Build products and indexes. Xcode rebuilds them; the next build is slower.")
        folder("simcaches", "Simulator caches", "~/Library/Developer/CoreSimulator/Caches", safety: .safe,
               why: "Caches the iOS Simulator recreates on launch.")
        folder("devicesupport", "iOS device support", "~/Library/Developer/Xcode/iOS DeviceSupport", safety: .review,
               why: "Debug symbols for devices you've connected. Xcode copies them again when you plug a device in.")
        folder("archives", "Xcode archives", "~/Library/Developer/Xcode/Archives", safety: .review,
               why: "Builds you archived for distribution. Keep the ones you may need to re-symbolicate crash logs.")
        let devices = expand("~/Library/Developer/CoreSimulator/Devices")
        if Scanner.exists(devices), Scanner.exists("/Applications/Xcode.app") {
            items.append(JunkItem(id: "simulators", title: "Unavailable simulators", detail: abbreviate(devices),
                                  explanation: "Runs `xcrun simctl delete unavailable`: removes simulators for runtimes that are no longer installed. Size shown is all simulators.",
                                  size: sizeOf(devices), safety: .safe, action: .command("xcrun simctl delete unavailable"),
                                  isPreselected: false, revealPath: devices))
        }
        return JunkGroup(id: "xcode", title: "Xcode & simulators", symbol: "hammer", items: items.sorted { $0.size > $1.size })
    }

    private func editors() -> JunkGroup {
        let cacheFolders = ["CachedData", "CachedExtensionVSIXs", "Cache", "Code Cache", "GPUCache", "CachedProfilesData", "logs"]
        var items: [JunkItem] = []
        for app in ["Cursor", "Code", "Code - Insiders", "Windsurf", "VSCodium"] {
            let base = expand("~/Library/Application Support/\(app)")
            let paths = targets(cacheFolders.map { base + "/" + $0 })
            let size = paths.reduce(0) { $0 + $1.size }
            guard size > 0 else { continue }
            let name = app == "Code" ? "VS Code" : app
            items.append(JunkItem(id: "editor:" + app, title: "\(name) caches", detail: abbreviate(base),
                                  explanation: "Compiled extension code, GPU and web caches, and logs. \(name) recreates them; quit it before cleaning. Your settings, extensions and workspaces are untouched.",
                                  size: size, safety: .safe, action: .trash(paths), isPreselected: true, revealPath: base))
        }
        let jetbrains = expand("~/Library/Caches/JetBrains")
        if let target = targets([jetbrains]).first {
            items.append(JunkItem(id: "jetbrains", title: "JetBrains IDE caches", detail: abbreviate(jetbrains),
                                  explanation: "Indexes and caches for IntelliJ-based IDEs. They are rebuilt on the next project open.",
                                  size: target.size, safety: .safe, action: .trash([target]), isPreselected: true, revealPath: jetbrains))
        }
        return JunkGroup(id: "editors", title: "Code editors", symbol: "chevron.left.forwardslash.chevron.right", items: items.sorted { $0.size > $1.size })
    }

    private func projects() -> JunkGroup {
        let now = Date()
        let items = result.artifacts.map { artifact -> JunkItem in
            let idleDays = Int(now.timeIntervalSince(artifact.lastActivity) / 86_400)
            let recent = idleDays < 7
            let activity = recent ? "Active this week" : "Last activity \(artifact.lastActivity.formatted(.relative(presentation: .named)))"
            return JunkItem(id: "artifact:" + artifact.path,
                            title: "\(artifact.projectName) · \(artifact.kind.rawValue)",
                            detail: "\(abbreviate(artifact.projectPath)) · \(activity)",
                            explanation: "Rebuild it any time with `\(artifact.kind.restoreHint)`. Projects untouched for a month are pre-selected; ones you worked on this week are never pre-selected.",
                            size: artifact.size, safety: .review, action: .trash([TrashTarget(path: artifact.path, size: artifact.size)]),
                            isPreselected: idleDays > 30, revealPath: artifact.path)
        }
        return JunkGroup(id: "projects", title: "Project build folders", symbol: "folder.badge.gearshape", items: items)
    }

    /// Per-app folders in ~/Library/Caches that no other rule already covers.
    private func appCaches() -> JunkGroup {
        let root = expand("~/Library/Caches")
        let claimed: Set<String> = ["Homebrew", "pip", "Yarn", "CocoaPods", "JetBrains"]
        var entries: [(name: String, path: String, size: Int64)] = []
        // Apple's own caches are macOS's business (several are privacy-protected, too), so leave them alone.
        for name in Scanner.listDirectory(root) where !claimed.contains(name) && !name.hasPrefix("com.apple.") {
            let path = root + "/" + name
            let size = sizeOf(path)
            if size >= 1 << 20 { entries.append((name, path, size)) }
        }
        entries.sort { $0.size > $1.size }
        var items = entries.prefix(15).map { entry in
            JunkItem(id: "cache:" + entry.path, title: appName(forCacheFolder: entry.name), detail: abbreviate(entry.path),
                     explanation: "Data the app keeps to work faster. Apps rebuild their caches; quit the app first so it doesn't hold on to it.",
                     size: entry.size, safety: .review, action: .trash([TrashTarget(path: entry.path, size: entry.size)]),
                     isPreselected: false, revealPath: entry.path)
        }
        let rest = entries.dropFirst(15)
        if !rest.isEmpty {
            items.append(JunkItem(id: "cache:rest", title: "\(rest.count) smaller app caches", detail: abbreviate(root),
                                  explanation: "Everything else in ~/Library/Caches. Apps rebuild these as needed.",
                                  size: rest.reduce(0) { $0 + $1.size }, safety: .review,
                                  action: .trash(rest.map { TrashTarget(path: $0.path, size: $0.size) }),
                                  isPreselected: false, revealPath: root))
        }
        return JunkGroup(id: "caches", title: "App caches", symbol: "internaldrive", items: items)
    }

    private func leftovers() -> JunkGroup {
        var items: [JunkItem] = []
        let logs = expand("~/Library/Logs")
        let logChildren = targets(Scanner.listDirectory(logs).map { logs + "/" + $0 })
        let logSize = logChildren.reduce(0) { $0 + $1.size }
        if logSize >= 1 << 20 {
            items.append(JunkItem(id: "logs", title: "Logs and crash reports", detail: abbreviate(logs),
                                  explanation: "Diagnostic logs apps write over time. Nothing needs them unless you're debugging a crash.",
                                  size: logSize, safety: .safe, action: .trash(logChildren), isPreselected: true, revealPath: logs))
        }
        let backups = expand("~/Library/Application Support/MobileSync/Backup")
        let backupSize = sizeOf(backups)
        if backupSize > 0 {
            items.append(JunkItem(id: "iosbackups", title: "iPhone & iPad backups", detail: abbreviate(backups),
                                  explanation: "Local device backups made by Finder. Delete only ones you also have in iCloud or no longer need.",
                                  size: backupSize, safety: .careful, action: .trash([TrashTarget(path: backups, size: backupSize)]),
                                  isPreselected: false, revealPath: backups))
        }
        let trash = expand("~/.Trash")
        let trashSize = sizeOf(trash)
        if trashSize > 0 {
            items.append(JunkItem(id: "trash", title: "Trash", detail: "Files you already deleted",
                                  explanation: "Empties the Trash through Finder. This is permanent.",
                                  size: trashSize, safety: .safe, action: .emptyTrash, isPreselected: false, revealPath: nil))
        }
        return JunkGroup(id: "leftovers", title: "Logs, backups & Trash", symbol: "tray.full", items: items)
    }

    // MARK: - Helpers

    private func condaInstalls() -> [String] {
        ["~/anaconda3", "~/miniconda3", "~/miniforge3", "~/mambaforge", "/opt/anaconda3", "/opt/miniconda3",
         "/opt/homebrew/anaconda3", "/opt/homebrew/Caskroom/miniconda/base", "/opt/homebrew/Caskroom/miniforge/base"]
            .map(expand)
            .filter { Scanner.exists($0 + "/bin/conda") }
    }

    /// Existing paths with their sizes; empty ones are dropped.
    private func targets(_ paths: [String]) -> [TrashTarget] {
        paths.filter { !result.protected.covers($0) && Scanner.exists($0) }
            .map { TrashTarget(path: $0, size: sizeOf($0)) }
            .filter { $0.size > 0 }
    }

    /// Uses the scan tree when it covers the path, otherwise measures the folder directly.
    private func sizeOf(_ path: String) -> Int64 {
        if let node = result.root.node(atPath: path), node.isDirectory == false || !node.children.isEmpty || node.size >= Scanner.pruneBelow {
            return node.size
        }
        guard !result.protected.covers(path), Scanner.exists(path) else { return 0 }
        return Scanner.measure(path, progress: progress, protected: result.protected)
    }

    private func appName(forCacheFolder name: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name),
           let bundle = Bundle(url: url),
           let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return display
        }
        return name
    }

    private func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
    private func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}
