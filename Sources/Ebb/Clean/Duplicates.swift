import CryptoKit
import Darwin
import Foundation

/// Identical files, found by size, then a sample hash, then a full SHA-256.
struct DuplicateGroup: Identifiable {
    struct File: Identifiable {
        let path: String
        let modified: Date
        /// Bytes only this copy holds. APFS clones share blocks, so deleting one may free nothing.
        let privateSize: Int64

        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
        var folder: String { ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath }
    }

    let id: String
    let size: Int64
    /// Oldest first, so the original is the default copy to keep.
    let files: [File]

    /// Space freed by deleting every copy except one. Counts only blocks each copy owns,
    /// so clones that already share storage add nothing.
    var reclaimable: Int64 { files.dropFirst().reduce(0) { $0 + $1.privateSize } }
    var isAllClones: Bool { files.count > 1 && reclaimable == 0 }
}

enum DuplicateFinder {
    /// Reports (files hashed so far, total to hash).
    typealias Progress = @Sendable (Int, Int) -> Void

    static func find(in candidates: [FileCandidate], progress: Progress, isCancelled: () -> Bool) -> [DuplicateGroup] {
        // Hard links are the same file, not copies: keep one path per inode.
        var seen = Set<UInt64>()
        let unique = candidates.filter { seen.insert($0.inode).inserted }

        let sameSize = Dictionary(grouping: unique, by: \.size).values.filter { $0.count > 1 }
        let total = sameSize.reduce(0) { $0 + $1.count }
        var done = 0
        var groups: [DuplicateGroup] = []

        for bucket in sameSize {
            guard !isCancelled() else { break }
            // A cheap sample of the start and end rules out most same-size strangers.
            let bySample = Dictionary(grouping: bucket) { sampleHash($0.path, size: $0.size) ?? UUID().uuidString }
            for sampled in bySample.values where sampled.count > 1 {
                let byContent = Dictionary(grouping: sampled) { fullHash($0.path) ?? UUID().uuidString }
                for (hash, copies) in byContent where copies.count > 1 {
                    let files = copies.sorted { $0.modified < $1.modified }.map {
                        DuplicateGroup.File(path: $0.path, modified: $0.modified,
                                            privateSize: privateSize($0.path) ?? $0.size)
                    }
                    groups.append(DuplicateGroup(id: hash, size: copies[0].size, files: files))
                }
            }
            done += bucket.count
            progress(done, total)
        }
        return groups.sorted { $0.reclaimable > $1.reclaimable }
    }

    private static let sampleLength = 64 * 1024

    private static func sampleHash(_ path: String, size: Int64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        guard let head = try? handle.read(upToCount: sampleLength) else { return nil }
        hasher.update(data: head)
        if size > Int64(sampleLength * 2) {
            try? handle.seek(toOffset: UInt64(size) - UInt64(sampleLength))
            if let tail = try? handle.read(upToCount: sampleLength) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fullHash(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data
            do { chunk = try handle.read(upToCount: 4 << 20) ?? Data() } catch { return nil }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Bytes not shared with any APFS clone, via getattrlist(ATTR_CMNEXT_PRIVATESIZE).
    static func privateSize(_ path: String) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var buffer = [UInt8](repeating: 0, count: 64)
        let status = getattrlist(path, &request, &buffer, buffer.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> Int64? in
            // Layout: u_int32 length, attribute_set_t (5 × u_int32) of returned attributes, then off_t.
            let returnedFork = raw.loadUnaligned(fromByteOffset: 4 + 16, as: UInt32.self)
            guard returnedFork & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            return raw.loadUnaligned(fromByteOffset: 24, as: Int64.self)
        }
    }
}

/// Runs the duplicate search on demand and keeps the result for the Duplicates screen.
@Observable @MainActor
final class DuplicatesModel {
    enum State {
        case idle
        case searching(done: Int, total: Int)
        case ready([DuplicateGroup])
    }

    private(set) var state: State = .idle
    /// Paths chosen for removal. Every group always keeps at least one copy.
    var selection: Set<String> = []
    @ObservationIgnored private var cancelled = false

    var groups: [DuplicateGroup] {
        if case .ready(let groups) = state { return groups }
        return []
    }

    func search(_ candidates: [FileCandidate]) {
        if case .searching = state { return }
        cancelled = false
        state = .searching(done: 0, total: 0)
        let sink = ProgressSink(model: self)
        Task {
            let groups = await Task.detached(priority: .userInitiated) {
                DuplicateFinder.find(in: candidates, progress: { sink.report($0, $1) }, isCancelled: { false })
            }.value
            guard !cancelled else { state = .idle; return }
            state = .ready(groups)
            selectSuggested()
        }
    }

    func cancel() { cancelled = true }

    fileprivate func showProgress(done: Int, total: Int) {
        guard case .searching = state else { return }
        state = .searching(done: done, total: total)
    }

    /// Keeps the oldest copy (usually the original) and selects the rest, skipping clone-only groups.
    func selectSuggested() {
        selection = Set(groups.filter { !$0.isAllClones }.flatMap { $0.files.dropFirst().map(\.path) })
    }

    func keepOnly(_ file: DuplicateGroup.File, in group: DuplicateGroup) {
        for other in group.files { selection.remove(other.path) }
        for other in group.files where other.path != file.path { selection.insert(other.path) }
    }

    func items() -> [JunkItem] {
        groups.flatMap { group in group.files.filter { selection.contains($0.path) }.map(item) }
    }

    func item(_ file: DuplicateGroup.File) -> JunkItem {
        JunkItem(id: "duplicate:" + file.path, title: file.name, detail: file.folder,
                 explanation: "An identical copy of this file stays on your Mac.",
                 size: file.privateSize, safety: .review,
                 action: .trash([TrashTarget(path: file.path, size: file.privateSize)]), isPreselected: false,
                 revealPath: file.path)
    }

    /// After a cleanup the removed files are gone; drop them from the groups.
    func forget(_ paths: Set<String>) {
        guard case .ready(let groups) = state else { return }
        let remaining = groups.compactMap { group -> DuplicateGroup? in
            let files = group.files.filter { !paths.contains($0.path) }
            return files.count > 1 ? DuplicateGroup(id: group.id, size: group.size, files: files) : nil
        }
        state = .ready(remaining)
        selection.subtract(paths)
    }
}

/// Carries progress from the background search to the model on the main thread.
private final class ProgressSink: @unchecked Sendable {
    private weak var model: DuplicatesModel?

    init(model: DuplicatesModel) { self.model = model }

    func report(_ done: Int, _ total: Int) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { model?.showProgress(done: done, total: total) }
        }
    }
}
