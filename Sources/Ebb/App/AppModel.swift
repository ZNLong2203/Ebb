import AppKit

@Observable @MainActor
final class AppModel {
    enum Section: String, Hashable, CaseIterable {
        case overview, junk, docker, apps, duplicates, largeFiles, diskMap, system
    }

    enum Phase: Equatable { case welcome, scanning, ready }

    var phase: Phase = .welcome
    var section: Section? = .overview
    private(set) var scanRoot = NSHomeDirectory()
    private(set) var result: ScanResult?
    private(set) var groups: [JunkGroup] = []
    var selection: Set<String> = []
    private(set) var progress = ScanProgress.Snapshot()
    /// When the file count last moved; a scan stuck behind a privacy prompt stops moving.
    private(set) var lastProgressChange = Date()
    private(set) var disk = DiskInfo.current()
    private(set) var hasFullDiskAccess = Permissions.hasFullDiskAccess
    /// Folder the disk map is zoomed into.
    var mapFocus: ScanNode?
    /// The cleanup sheet: confirm → cleaning → done, all in one sheet so it never flickers between dialogs.
    var cleanFlow: CleanFlow?
    let docker = DockerModel()
    let apps = AppsModel()
    let duplicates = DuplicatesModel()
    let system = SystemModel()
    let dockerInstalled = DockerModel.isInstalled
    let cleaner = Cleaner()

    @ObservationIgnored private var activeProgress: ScanProgress?
    @ObservationIgnored private var pollTimer: Timer?

    var isScanning: Bool { phase == .scanning }
    var allItems: [JunkItem] { groups.flatMap(\.items) }
    var selectedItems: [JunkItem] { allItems.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var safeBytes: Int64 { allItems.filter { $0.safety == .safe }.reduce(0) { $0 + $1.size } }
    var reviewBytes: Int64 { allItems.filter { $0.safety != .safe }.reduce(0) { $0 + $1.size } }
    var scanRootDisplay: String { (scanRoot as NSString).abbreviatingWithTildeInPath }

    // MARK: - Scanning

    func scan(root: String? = nil) {
        guard !isScanning else { return }
        if let root { scanRoot = root }
        let keepSelection = result != nil
        phase = .scanning
        hasFullDiskAccess = Permissions.hasFullDiskAccess
        let progress = ScanProgress()
        activeProgress = progress
        self.progress = .init()
        lastProgressChange = Date()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let active = self.activeProgress else { return }
                let snapshot = active.snapshot
                guard snapshot.files != self.progress.files || snapshot.currentPath != self.progress.currentPath
                        || snapshot.stage != self.progress.stage else { return }
                self.progress = snapshot
                self.lastProgressChange = Date()
            }
        }
        let root = scanRoot
        let protected = ProtectedLocations.forCurrentUser(hasFullDiskAccess: hasFullDiskAccess)
        Task {
            let output = await Task.detached(priority: .userInitiated) { () -> (ScanResult, [JunkGroup])? in
                let result = Scanner.scan(root: root, progress: progress, protected: protected)
                guard !progress.isCancelled else { return nil }
                progress.begin(stage: "Looking for developer junk")
                return (result, JunkCatalog(result: result, progress: progress).groups())
            }.value
            pollTimer?.invalidate()
            activeProgress = nil
            disk = DiskInfo.current()
            disk.localSnapshots = await DiskInfo.countLocalSnapshots()
            guard let (result, groups) = output else {
                phase = self.result == nil ? .welcome : .ready
                return
            }
            let previous = selection
            self.result = result
            self.groups = groups
            let ids = Set(groups.flatMap(\.items).map(\.id))
            // A rescan keeps choices the user made on items that still exist; a first scan uses the defaults.
            selection = keepSelection ? previous.intersection(ids)
                : Set(groups.flatMap(\.items).filter(\.isPreselected).map(\.id))
            mapFocus = nil
            phase = .ready
            // Apps and background items don't depend on the scanned folder, but refresh them alongside.
            apps.load(protected: result.protected)
            system.load()
        }
    }

    func cancelScan() { activeProgress?.cancel() }

    func refreshPermissions() { hasFullDiskAccess = Permissions.hasFullDiskAccess }

    /// Full Disk Access granted while running may only apply after a restart.
    func relaunch() {
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: scanRoot)
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url { scan(root: url.path) }
    }

    func selectDefaults() { selection = Set(allItems.filter(\.isPreselected).map(\.id)) }
    func selectNone() { selection = [] }

    // MARK: - Cleaning

    /// Bytes free after cleaning the current selection and emptying the Trash.
    var projectedFree: Int64 { disk.free + selectedBytes + cleaner.trashedBytes }

    func requestClean(_ items: [JunkItem]) {
        guard !items.isEmpty else { return }
        cleanFlow = CleanFlow(items: items)
    }

    func confirmClean() {
        guard let flow = cleanFlow, case .confirm = flow.phase else { return }
        cleanFlow?.phase = .running
        Task {
            let started = Date()
            let report = await clean(flow.items)
            // Fast cleanups still show the progress for a moment, so it's clear something happened.
            let shown = Date().timeIntervalSince(started)
            if shown < 1.2 { try? await Task.sleep(for: .seconds(1.2 - shown)) }
            cleanFlow?.phase = .done(report)
        }
    }

    func dismissCleanFlow() {
        if case .running = cleanFlow?.phase { return }
        cleanFlow = nil
    }

    func artifactKind(for item: JunkItem) -> ProjectArtifact.Kind? {
        guard item.id.hasPrefix("artifact:") else { return nil }
        let path = String(item.id.dropFirst("artifact:".count))
        return result?.artifacts.first { $0.path == path }?.kind
    }

    func clean(_ items: [JunkItem]) async -> Cleaner.Report {
        let report = await cleaner.clean(items)
        selection.subtract(items.map(\.id))
        docker.selection.subtract(items.map(\.id))
        if items.contains(where: { $0.id.hasPrefix("docker") }) {
            await docker.refresh()
        }
        let removedDuplicates = items.filter { $0.id.hasPrefix("duplicate:") }.map { String($0.id.dropFirst("duplicate:".count)) }
            .filter { !Scanner.exists($0) }
        duplicates.forget(Set(removedDuplicates))
        system.selection.subtract(items.compactMap { $0.id.hasPrefix("agent:") ? String($0.id.dropFirst("agent:".count)) : nil })
        apps.selectedOrphans.subtract(items.compactMap { $0.id.hasPrefix("orphan:") ? String($0.id.dropFirst("orphan:".count)) : nil })
        scan()
        return report
    }

    func trash(paths: [String], sizes: [Int64]) async -> [String] {
        var failures: [String] = []
        for (path, size) in zip(paths, sizes) {
            do { try await cleaner.moveToTrash(URL(fileURLWithPath: path), size: size) }
            catch { failures.append((path as NSString).lastPathComponent) }
        }
        scan()
        return failures
    }

    func undoAll() -> [String] {
        let failures = cleaner.restoreAll()
        scan()
        return failures
    }

    func emptyTrash() async -> String? {
        let error = await cleaner.emptyTrash()
        disk = DiskInfo.current()
        return error
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    #if DEBUG
    /// Drive the UI from a shell for screenshots: distributed notification
    /// `io.github.znlong2203.ebb.debug` with object `scan:<path>` | `section:<name>` | `focus:<path>`.
    func installDebugHook() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.github.znlong2203.ebb.debug"), object: nil, queue: .main
        ) { [weak self] note in
            guard let command = note.object as? String else { return }
            MainActor.assumeIsolated { self?.runDebug(command) }
        }
    }

    private func runDebug(_ command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "scan": scan(root: arg.isEmpty ? NSHomeDirectory() : arg)
        case "section": section = Section(rawValue: arg) ?? .overview
        case "focus": mapFocus = result?.root.node(atPath: arg)
        case "demo-report":
            // Shows the celebration without touching any files.
            var report = Cleaner.Report()
            report.movedToTrash = Int64(arg) ?? 14_800_000_000
            cleanFlow = CleanFlow(items: [], phase: .done(report))
        case "confirm":
            requestClean(selectedItems)
        case "clean-prefix":
            // Cleans only items whose id starts with the argument, e.g. one test project's artifacts.
            let pool = allItems + (docker.snapshot.map { docker.items(in: $0) } ?? [])
                + apps.apps.map(apps.uninstallItem) + apps.orphans.map(apps.orphanItem)
                + system.items.compactMap(system.cleanupItem) + duplicates.groups.flatMap { $0.files.map(duplicates.item) }
            requestClean(pool.filter { $0.id.hasPrefix(arg) })
            confirmClean()
        case "find-duplicates":
            duplicates.search(result?.duplicateCandidates ?? [])
            section = .duplicates
        case "docker-demo":
            docker.loadDemo(DockerSnapshot.demo)
            section = .docker
        case "undo-all":
            _ = undoAll()
        default: break
        }
    }
    #endif

    // MARK: - Large files

    /// Why a file shouldn't be trashed from the Large Files list, if it shouldn't.
    func protection(for path: String) -> String? {
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/Library/") {
            return "App data inside ~/Library. Remove it from the app that owns it, or through Developer Junk."
        }
        if path.hasPrefix("/System/") || path.hasPrefix("/Library/") || path.hasPrefix("/Applications/") {
            return "Part of macOS or an installed app."
        }
        return nil
    }
}
