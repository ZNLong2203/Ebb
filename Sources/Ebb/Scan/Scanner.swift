import Darwin
import Foundation
import os

/// A big file worth listing on its own.
struct LargeFile: Identifiable, Hashable {
    let path: String
    let size: Int64
    let modified: Date
    let accessed: Date
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { (path as NSString).lastPathComponent }
}

/// A rebuildable build/dependency folder inside a project (node_modules, target, .venv…).
struct ProjectArtifact: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case nodeModules = "node_modules"
        case rustTarget = "Rust target"
        case swiftBuild = "SwiftPM .build"
        case cocoaPods = "CocoaPods Pods"
        case pythonVenv = "Python virtualenv"
        case nextCache = "Next.js .next"
        case gradleProject = "Gradle .gradle"

        /// How to bring it back after deleting it.
        var restoreHint: String {
            switch self {
            case .nodeModules: "npm install"
            case .rustTarget: "cargo build"
            case .swiftBuild: "swift build"
            case .cocoaPods: "pod install"
            case .pythonVenv: "python -m venv + pip install"
            case .nextCache: "next build"
            case .gradleProject: "gradle build"
            }
        }
    }

    let kind: Kind
    let path: String
    let size: Int64
    /// The folder containing the artifact.
    let projectPath: String
    /// Best guess at when the project was last worked on.
    let lastActivity: Date
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var projectName: String { (projectPath as NSString).lastPathComponent }
}

/// A user file big enough to be worth checking for duplicates.
struct FileCandidate: Hashable {
    let path: String
    /// Logical size (bytes of content), which identical copies share.
    let size: Int64
    let modified: Date
    let inode: UInt64
}

struct ScanResult {
    let root: ScanNode
    let largeFiles: [LargeFile]
    let artifacts: [ProjectArtifact]
    let fileCount: Int
    let unreadableCount: Int
    /// Protected folders left out because Ebb has no Full Disk Access.
    let skipped: [String]
    let protected: ProtectedLocations
    /// Files ≥ 1 MB outside app data, build folders and bundles, for the duplicate finder.
    let duplicateCandidates: [FileCandidate]
    let duration: TimeInterval
    let finishedAt: Date
}

/// Live counters the UI polls while a scan runs.
final class ScanProgress: @unchecked Sendable {
    struct Snapshot {
        var files = 0
        var bytes: Int64 = 0
        var currentPath = ""
        var stage = "Scanning"
    }

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    var snapshot: Snapshot { state.withLock { $0 } }
    var isCancelled: Bool { cancelled.withLock { $0 } }
    func cancel() { cancelled.withLock { $0 = true } }

    func begin(stage: String) { state.withLock { $0.stage = stage } }
    func show(path: String) { state.withLock { $0.currentPath = path } }

    func add(files: Int, bytes: Int64, path: String) {
        state.withLock {
            $0.files += files
            $0.bytes += bytes
            $0.currentPath = path
        }
    }
}

/// Walks a folder with `fts(3)`, which is several times faster than FileManager's enumerator,
/// splitting the tree into second-level work units scanned in parallel.
enum Scanner {
    /// Files at least this big become their own nodes (drawn in the disk map).
    static let fileNodeThreshold: Int64 = 4 << 20
    /// Directories smaller than this forget their children after being measured.
    static let pruneBelow: Int64 = 8 << 20
    /// Files at least this big are listed under "Large files".
    static let largeFileThreshold: Int64 = 100_000_000

    static func scan(root: String, progress: ScanProgress, protected allProtected: ProtectedLocations = .none) -> ScanResult {
        let started = Date()
        let protected = allProtected.within(root)
        let rootNode = ScanNode(name: root, isDirectory: true, modified: Date())

        var largeFiles: [LargeFile] = []
        var candidates: [FileCandidate] = []
        var fileCount = 0
        func addLooseFile(_ path: String, _ info: Info, to parent: ScanNode) {
            if info.isRegularFile, info.logicalSize >= duplicateThreshold, !pathIsExcludedFromDuplicates(path) {
                candidates.append(FileCandidate(path: path, size: info.logicalSize, modified: info.modified, inode: info.inode))
            }
            parent.size += info.allocated
            parent.fileCount += 1
            fileCount += 1
            if info.allocated >= fileNodeThreshold {
                let node = ScanNode(name: (path as NSString).lastPathComponent, isDirectory: false, modified: info.modified)
                node.size = info.allocated
                node.fileCount = 1
                parent.addChild(node)
            }
            if info.allocated >= largeFileThreshold {
                largeFiles.append(LargeFile(path: path, size: info.allocated, modified: info.modified, accessed: info.accessed))
            }
        }

        var level1: [ScanNode] = []
        var skipped: [String] = []
        for child in listDirectory(root) {
            let path = join(root, child)
            guard let info = lstatInfo(path) else { continue }
            if info.isDirectory {
                let node = ScanNode(name: child, isDirectory: true, modified: info.modified)
                node.size = info.allocated
                rootNode.addChild(node)
                if protected.isProtected(path) {
                    skipped.append(path)
                } else {
                    level1.append(node)
                }
            } else {
                addLooseFile(path, info, to: rootNode)
            }
        }

        // Each top-level folder is listed in its own operation, which then queues one operation per
        // subfolder. Work spreads over all cores even when ~/Library holds most of the data, and a
        // folder blocked on a macOS privacy prompt (Desktop, Documents…) only stalls itself.
        let collector = Collector()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount)
        queue.qualityOfService = .userInitiated
        for (index, node) in level1.enumerated() {
            let path = join(root, node.name)
            queue.addOperation {
                for child in listDirectory(path) {
                    guard !progress.isCancelled else { return }
                    let subPath = join(path, child)
                    guard let info = lstatInfo(subPath) else { continue }
                    guard info.isDirectory else {
                        collector.addLooseFile(level1: index, path: subPath, info: info)
                        continue
                    }
                    if protected.isProtected(subPath) {
                        collector.addSkipped(subPath)
                        continue
                    }
                    queue.addOperation {
                        guard !progress.isCancelled else { return }
                        let worker = SubtreeWorker(root: root, progress: progress, protected: protected)
                        collector.addSubtree(level1: index, worker.run(path: subPath))
                    }
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()

        // Workers never touch the shared tree; everything is attached here on one thread.
        for (index, path, info) in collector.looseFiles {
            addLooseFile(path, info, to: level1[index])
        }
        var artifacts: [ProjectArtifact] = []
        var unreadable = 0
        for (index, output) in collector.subtrees {
            if let node = output.node { level1[index].addChild(node) }
            largeFiles += output.largeFiles
            artifacts += output.artifacts
            fileCount += output.fileCount
            unreadable += output.unreadable
            skipped += output.skipped
            candidates += output.duplicateCandidates
        }
        skipped += collector.skipped

        // Second-level nodes were finished by their workers; now roll sizes up two levels.
        for level1 in rootNode.children where level1.isDirectory {
            for child in level1.children where child.isDirectory {
                level1.size += child.size
                level1.fileCount += child.fileCount
            }
        }
        // Loose files at the root were already counted when they were stat'ed above.
        for level1 in rootNode.children where level1.isDirectory {
            rootNode.size += level1.size
            rootNode.fileCount += level1.fileCount
        }
        rootNode.sortChildrenBySize()

        return ScanResult(root: rootNode,
                          largeFiles: largeFiles.sorted { $0.size > $1.size },
                          artifacts: artifacts.sorted { $0.size > $1.size },
                          fileCount: fileCount,
                          unreadableCount: unreadable,
                          skipped: skipped.sorted(),
                          protected: allProtected,
                          duplicateCandidates: candidates,
                          duration: Date().timeIntervalSince(started),
                          finishedAt: Date())
    }

    /// Total allocated size of one path, for locations outside the scanned root.
    static func measure(_ path: String, progress: ScanProgress = ScanProgress(), protected: ProtectedLocations = .none) -> Int64 {
        guard !protected.covers(path), let info = lstatInfo(path) else { return 0 }
        guard info.isDirectory else { return info.allocated }
        progress.show(path: path)
        let worker = SubtreeWorker(root: path, progress: progress, protected: protected, collectDetails: false)
        return worker.run(path: path).node?.size ?? 0
    }

    // MARK: - Helpers

    struct Info {
        let isDirectory: Bool
        let isRegularFile: Bool
        let allocated: Int64
        let logicalSize: Int64
        let inode: UInt64
        let modified: Date
        let accessed: Date
    }

    static func lstatInfo(_ path: String) -> Info? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Info(isDirectory: (st.st_mode & S_IFMT) == S_IFDIR,
                    isRegularFile: (st.st_mode & S_IFMT) == S_IFREG,
                    allocated: Int64(st.st_blocks) * 512,
                    logicalSize: Int64(st.st_size),
                    inode: UInt64(st.st_ino),
                    modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                    accessed: Date(timeIntervalSince1970: TimeInterval(st.st_atimespec.tv_sec)))
    }

    // MARK: - Duplicate candidates

    static let duplicateThreshold: Int64 = 1_000_000

    /// Folders whose files belong to an app, a tool or a build, where removing one "duplicate"
    /// would break something: package folders, app data, bundles and hidden tool homes.
    private static let duplicateExcludedNames: Set<String> = [
        "Library", "node_modules", "bower_components", "site-packages", "dist-packages", "venv", "env",
        "Pods", "Carthage", "DerivedData", "target", "build", "vendor", "__pycache__",
    ]
    private static let bundleExtensions: Set<String> = [
        "app", "appex", "framework", "bundle", "plugin", "kext", "xpc", "photoslibrary", "musiclibrary", "tvlibrary",
        "imovielibrary", "fcpbundle", "logicx", "band", "xcodeproj", "xcworkspace", "xcassets", "sparsebundle",
        "pkg", "lproj", "docset", "playground", "photolibrary", "aplibrary", "migratedphotolibrary",
    ]

    static func isExcludedFromDuplicates(directoryName name: String) -> Bool {
        name.hasPrefix(".") || duplicateExcludedNames.contains(name)
            || bundleExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    static func pathIsExcludedFromDuplicates(_ path: String) -> Bool {
        path.split(separator: "/").dropLast().contains { isExcludedFromDuplicates(directoryName: String($0)) }
    }

    static func listDirectory(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    static func join(_ a: String, _ b: String) -> String { a.hasSuffix("/") ? a + b : a + "/" + b }

    static func exists(_ path: String) -> Bool { access(path, F_OK) == 0 }
}

/// Gathers results from scan operations running on many threads.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var looseFiles: [(Int, String, Scanner.Info)] = []
    private(set) var subtrees: [(Int, SubtreeWorker.Output)] = []
    private(set) var skipped: [String] = []

    func addSkipped(_ path: String) {
        lock.lock(); skipped.append(path); lock.unlock()
    }

    func addLooseFile(level1: Int, path: String, info: Scanner.Info) {
        lock.lock(); looseFiles.append((level1, path, info)); lock.unlock()
    }

    func addSubtree(level1: Int, _ output: SubtreeWorker.Output) {
        lock.lock(); subtrees.append((level1, output)); lock.unlock()
    }
}

/// Scans one subtree on the calling thread.
private final class SubtreeWorker {
    struct Output {
        var node: ScanNode?
        var largeFiles: [LargeFile] = []
        var artifacts: [ProjectArtifact] = []
        var fileCount = 0
        var unreadable = 0
        var skipped: [String] = []
        var duplicateCandidates: [FileCandidate] = []
    }

    private struct PendingArtifact {
        let kind: ProjectArtifact.Kind
        let node: ScanNode
        let path: String
        let projectPath: String
        let lastActivity: Date
    }

    private let home = NSHomeDirectory()
    private let root: String
    private let progress: ScanProgress
    private let protected: ProtectedLocations
    private let collectDetails: Bool
    private var output = Output()
    private var stack: [ScanNode] = []
    /// Parallel to `stack`: whether files in that folder are off-limits for the duplicate finder.
    private var excludedStack: [Bool] = []
    private var baseExcluded = false
    private var pendingArtifacts: [PendingArtifact] = []
    private var seenInodes = Set<UInt64>()
    private var batchFiles = 0
    private var batchBytes: Int64 = 0

    init(root: String, progress: ScanProgress, protected: ProtectedLocations, collectDetails: Bool = true) {
        self.root = root
        self.progress = progress
        self.protected = protected
        self.collectDetails = collectDetails
    }

    func run(path: String) -> Output {
        baseExcluded = Scanner.pathIsExcludedFromDuplicates(path)
        var paths: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { free(paths[0]) }
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return output }
        defer { fts_close(fts) }

        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_D:
                enterDirectory(entry)
                // Don't descend into privacy-protected folders: reading them would block on a prompt.
                // fts still reports the folder once more as FTS_DP, which pops it again.
                if !protected.paths.isEmpty {
                    let path = String(cString: entry.pointee.fts_path)
                    if protected.isProtected(path) {
                        output.skipped.append(path)
                        fts_set(fts, entry, FTS_SKIP)
                    }
                }
            case FTS_DP:
                leaveDirectory()
            case FTS_DNR, FTS_ERR, FTS_NS:
                output.unreadable += 1
                if info == FTS_DNR { leaveDirectory() }
            case FTS_DC:
                break
            default:
                visitFile(entry)
            }
            if batchFiles >= 4000 {
                flushProgress(currentPath: String(cString: entry.pointee.fts_path))
                if progress.isCancelled { break }
            }
        }
        flushProgress(currentPath: path)
        return output
    }

    /// The entry's name is the tail of its path; reading it from `fts_path` avoids touching
    /// the variable-length `fts_name` array, which Swift imports as a one-element tuple.
    private func name(of entry: UnsafeMutablePointer<FTSENT>) -> String {
        let start = Int(entry.pointee.fts_pathlen) - Int(entry.pointee.fts_namelen)
        return String(cString: entry.pointee.fts_path + start)
    }

    private func enterDirectory(_ entry: UnsafeMutablePointer<FTSENT>) {
        let st = entry.pointee.fts_statp.pointee
        let node = ScanNode(name: name(of: entry), isDirectory: true,
                            modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)))
        node.size = Int64(st.st_blocks) * 512
        if let parent = stack.last {
            parent.addChild(node)
        } else {
            output.node = node
        }
        stack.append(node)
        excludedStack.append((excludedStack.last ?? baseExcluded) || Scanner.isExcludedFromDuplicates(directoryName: node.name))
        if collectDetails, pendingArtifacts.isEmpty, let artifact = detectArtifact(node: node, path: String(cString: entry.pointee.fts_path)) {
            pendingArtifacts.append(artifact)
        }
    }

    private func leaveDirectory() {
        guard let node = stack.popLast() else { return }
        excludedStack.removeLast()
        if let parent = stack.last {
            parent.size += node.size
            parent.fileCount += node.fileCount
        }
        if let artifact = pendingArtifacts.last, artifact.node === node {
            pendingArtifacts.removeLast()
            output.artifacts.append(ProjectArtifact(kind: artifact.kind, path: artifact.path, size: node.size,
                                                    projectPath: artifact.projectPath, lastActivity: artifact.lastActivity))
        }
        if node.size < Scanner.pruneBelow {
            node.children = []
        } else {
            // Slivers under 1 MB can't be seen in the disk map; their bytes stay in `looseBytes`.
            node.children.removeAll { $0.size < 1 << 20 }
        }
    }

    private func visitFile(_ entry: UnsafeMutablePointer<FTSENT>) {
        guard let parent = stack.last else { return }
        let st = entry.pointee.fts_statp.pointee
        // Hard links share blocks: count each inode once.
        if st.st_nlink > 1 && (st.st_mode & S_IFMT) != S_IFDIR {
            guard seenInodes.insert(UInt64(st.st_ino)).inserted else { return }
        }
        let allocated = Int64(st.st_blocks) * 512
        parent.size += allocated
        parent.fileCount += 1
        output.fileCount += 1
        batchFiles += 1
        batchBytes += allocated

        if collectDetails, Int64(st.st_size) >= Scanner.duplicateThreshold, (st.st_mode & S_IFMT) == S_IFREG,
           excludedStack.last == false {
            output.duplicateCandidates.append(FileCandidate(
                path: String(cString: entry.pointee.fts_path), size: Int64(st.st_size),
                modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)), inode: UInt64(st.st_ino)))
        }

        guard collectDetails, allocated >= Scanner.fileNodeThreshold else { return }
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        let node = ScanNode(name: name(of: entry), isDirectory: false, modified: modified)
        node.size = allocated
        node.fileCount = 1
        parent.addChild(node)
        if allocated >= Scanner.largeFileThreshold {
            output.largeFiles.append(LargeFile(path: String(cString: entry.pointee.fts_path), size: allocated, modified: modified,
                                               accessed: Date(timeIntervalSince1970: TimeInterval(st.st_atimespec.tv_sec))))
        }
    }

    private func flushProgress(currentPath: String) {
        progress.add(files: batchFiles, bytes: batchBytes, path: currentPath)
        batchFiles = 0
        batchBytes = 0
    }

    // MARK: - Project artifacts

    /// Recognises rebuildable folders, but only inside ordinary projects: never in ~/Library or
    /// hidden tool homes (~/.vscode, ~/.nvm…), where a node_modules can be part of an installed tool.
    private func detectArtifact(node: ScanNode, path: String) -> PendingArtifact? {
        let kind: ProjectArtifact.Kind
        let project = (path as NSString).deletingLastPathComponent
        switch node.name {
        case "node_modules" where Scanner.exists(project + "/package.json"): kind = .nodeModules
        case "target" where Scanner.exists(project + "/Cargo.toml"): kind = .rustTarget
        case ".build" where Scanner.exists(project + "/Package.swift"): kind = .swiftBuild
        case "Pods" where Scanner.exists(project + "/Podfile"): kind = .cocoaPods
        case ".next" where Scanner.exists(project + "/package.json"): kind = .nextCache
        case ".gradle" where Scanner.exists(project + "/build.gradle") || Scanner.exists(project + "/build.gradle.kts")
            || Scanner.exists(project + "/settings.gradle") || Scanner.exists(project + "/settings.gradle.kts"): kind = .gradleProject
        case ".venv", "venv", "env":
            // A `where` clause only binds to the last pattern, so check for every name here.
            guard Scanner.exists(path + "/pyvenv.cfg") else { return nil }
            kind = .pythonVenv
        default: return nil
        }
        guard isOrdinaryProject(project) else { return nil }
        return PendingArtifact(kind: kind, node: node, path: path, projectPath: project,
                               lastActivity: lastActivity(ofProject: project))
    }

    private func isOrdinaryProject(_ project: String) -> Bool {
        guard project.hasPrefix(home + "/") else { return false }
        let relative = project.dropFirst(home.count + 1)
        if relative.hasPrefix("Library/") || relative == "Library" { return false }
        // Any hidden component (~/.nvm/…, ~/.vscode/…, a/.git/…) means a tool's home, not a project.
        return !relative.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// Newest of: the project folder, its manifest/lockfiles, and git's HEAD log (moves on commit/checkout).
    private func lastActivity(ofProject project: String) -> Date {
        let candidates = [project, project + "/.git/logs/HEAD", project + "/.git/index",
                          project + "/package.json", project + "/package-lock.json", project + "/pnpm-lock.yaml",
                          project + "/yarn.lock", project + "/Cargo.toml", project + "/Package.swift",
                          project + "/Podfile", project + "/requirements.txt", project + "/pyproject.toml"]
        return candidates.compactMap { Scanner.lstatInfo($0)?.modified }.max() ?? .distantPast
    }
}
