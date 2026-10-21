import AppKit

/// What Docker is storing, read from `docker system df -v`.
struct DockerSnapshot {
    struct Image: Identifiable {
        let id: String
        let repository: String
        let tag: String
        let size: Int64
        /// Bytes only this image holds; removing it frees about this much.
        let uniqueSize: Int64
        let containers: Int
        let created: String

        var name: String { repository == "<none>" ? "Untagged image" : "\(repository):\(tag)" }
        var isDangling: Bool { repository == "<none>" }
        var shortID: String { String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12)) }
    }

    struct Container: Identifiable {
        let id: String
        let name: String
        let image: String
        let state: String
        let status: String
        let size: Int64
        let volumes: Int

        var isRunning: Bool { state == "running" || state == "restarting" || state == "paused" }
    }

    struct Volume: Identifiable {
        let name: String
        let size: Int64
        /// Containers (running or stopped) that mount it.
        let links: Int
        let isAnonymous: Bool

        var id: String { name }
        var displayName: String { isAnonymous ? "Anonymous volume \(name.prefix(12))…" : name }
    }

    var images: [Image] = []
    var containers: [Container] = []
    var volumes: [Volume] = []
    var buildCacheSize: Int64 = 0
    /// Build cache no image currently uses; `docker builder prune` removes it.
    var buildCacheReclaimable: Int64 = 0
    var buildCacheEntries = 0

    var imagesSize: Int64 { images.reduce(0) { $0 + $1.size } }
    var containersSize: Int64 { containers.reduce(0) { $0 + $1.size } }
    var volumesSize: Int64 { volumes.reduce(0) { $0 + $1.size } }

    var reclaimableImages: Int64 { images.filter { $0.containers == 0 }.reduce(0) { $0 + $1.uniqueSize } }
    var reclaimableContainers: Int64 { containers.filter { !$0.isRunning }.reduce(0) { $0 + $1.size } }
    var reclaimableVolumes: Int64 { volumes.filter { $0.links == 0 }.reduce(0) { $0 + $1.size } }

    /// Parses the single JSON object printed by `docker system df -v --format '{{json .}}'`.
    static func parse(_ data: Data) -> DockerSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func rows(_ key: String) -> [[String: Any]] { json[key] as? [[String: Any]] ?? [] }
        func text(_ row: [String: Any], _ key: String) -> String { row[key] as? String ?? "" }
        func number(_ row: [String: Any], _ key: String) -> Int { Int(text(row, key)) ?? 0 }

        var snapshot = DockerSnapshot()
        snapshot.images = rows("Images").map { row in
            Image(id: text(row, "ID"), repository: text(row, "Repository"), tag: text(row, "Tag"),
                  size: parseSize(text(row, "Size")), uniqueSize: parseSize(text(row, "UniqueSize")),
                  containers: number(row, "Containers"), created: text(row, "CreatedSince"))
        }
        .sorted { $0.size > $1.size }
        snapshot.containers = rows("Containers").map { row in
            Container(id: text(row, "ID"), name: text(row, "Names"), image: text(row, "Image"), state: text(row, "State"),
                      status: text(row, "Status"), size: parseSize(text(row, "Size")), volumes: number(row, "LocalVolumes"))
        }
        .sorted { $0.size > $1.size }
        snapshot.volumes = rows("Volumes").map { row in
            Volume(name: text(row, "Name"), size: parseSize(text(row, "Size")), links: number(row, "Links"),
                   isAnonymous: text(row, "Labels").contains("com.docker.volume.anonymous"))
        }
        .sorted { $0.size > $1.size }
        let cache = rows("BuildCache")
        snapshot.buildCacheEntries = cache.count
        snapshot.buildCacheSize = cache.reduce(0) { $0 + parseSize(text($1, "Size")) }
        snapshot.buildCacheReclaimable = cache.filter { text($0, "InUse") != "true" }.reduce(0) { $0 + parseSize(text($1, "Size")) }
        return snapshot
    }

    /// Docker prints decimal sizes such as "45.6MB", "159.3kB" or "0B".
    static func parseSize(_ string: String) -> Int64 {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (suffix, multiplier) in units where trimmed.hasSuffix(suffix) {
            guard let value = Double(trimmed.dropLast(suffix.count)) else { return 0 }
            return Int64(value * multiplier)
        }
        return 0
    }
}

/// Loads Docker's view of disk usage and turns removable things into cleanable items.
@Observable @MainActor
final class DockerModel {
    enum State {
        case notInstalled
        case notRunning
        case loading
        case ready(DockerSnapshot)
        case failed(String)
    }

    private(set) var state: State = .loading
    var selection: Set<String> = []
    #if DEBUG
    /// Screenshot mode: keeps the made-up snapshot instead of asking the real Docker.
    @ObservationIgnored private var isDemo = false
    #endif

    static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: "/Applications/Docker.app")
            || ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", NSHomeDirectory() + "/.docker/bin/docker"].contains(where: fm.fileExists)
    }

    var snapshot: DockerSnapshot? {
        if case .ready(let snapshot) = state { return snapshot }
        return nil
    }

    func refresh() async {
        #if DEBUG
        if isDemo { return }
        #endif
        guard Self.isInstalled else { state = .notInstalled; return }
        if snapshot == nil { state = .loading }
        let (status, output) = await Cleaner.run("docker system df -v --format '{{json .}}'")
        if status == 0, let snapshot = DockerSnapshot.parse(Data(output.utf8)) {
            state = .ready(snapshot)
            selection.formIntersection(Set(items(in: snapshot).map(\.id)))
        } else if output.contains("Cannot connect") || output.contains("failed to connect") || output.contains("daemon") {
            state = .notRunning
        } else {
            state = .failed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func startDocker() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Docker.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    #if DEBUG
    func loadDemo(_ snapshot: DockerSnapshot) {
        isDemo = true
        state = .ready(snapshot)
    }
    #endif

    // MARK: - Cleanable items

    /// Every removable thing, as cleanup items run through Docker's own commands.
    /// Order matters: containers first, so the images and volumes they held become removable.
    func items(in snapshot: DockerSnapshot) -> [JunkItem] {
        var items: [JunkItem] = []
        for container in snapshot.containers where !container.isRunning {
            items.append(JunkItem(
                id: "docker-container:" + container.id, title: container.name,
                detail: "\(container.image) · \(container.status)",
                explanation: "Removes the stopped container and its writable layer. Its volumes and image are kept.",
                size: container.size, safety: .review, action: .command("docker rm \(container.id)"), isPreselected: false))
        }
        for image in snapshot.images where image.containers == 0 {
            items.append(JunkItem(
                id: "docker-image:" + image.id, title: image.name,
                detail: "\(image.shortID) · created \(image.created)",
                explanation: image.isDangling
                    ? "A leftover layer from an old build with no tag. Nothing refers to it."
                    : "No container uses this image. Docker pulls or builds it again when you need it.",
                size: image.uniqueSize, safety: image.isDangling ? .safe : .review,
                action: .command("docker rmi \(image.id)"), isPreselected: false))
        }
        for volume in snapshot.volumes where volume.links == 0 {
            items.append(JunkItem(
                id: "docker-volume:" + volume.name, title: volume.displayName,
                detail: "Not used by any container",
                explanation: "Volumes hold data such as databases. Removing one deletes that data permanently.",
                size: volume.size, safety: .careful, action: .command("docker volume rm '\(volume.name)'"), isPreselected: false))
        }
        if snapshot.buildCacheReclaimable > 0 {
            items.append(JunkItem(
                id: "docker-buildcache", title: "Unused build cache",
                detail: "\(snapshot.buildCacheEntries) cache entries",
                explanation: "Layers saved by `docker build` that no image uses now. Docker rebuilds them when needed.",
                size: snapshot.buildCacheReclaimable, safety: .safe, action: .command("docker builder prune -f"), isPreselected: false))
        }
        return items
    }

    func selectedItems() -> [JunkItem] {
        guard let snapshot else { return [] }
        return items(in: snapshot).filter { selection.contains($0.id) }
    }
}

#if DEBUG
extension DockerSnapshot {
    /// Made-up but realistic data for screenshots, so no real project names end up public.
    static var demo: DockerSnapshot {
        func hex(_ seed: Int) -> String {
            var x = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15
            return (0..<4).map { _ in x = x &* 6364136223846793005 &+ 1442695040888963407; return String(format: "%016llx", x) }.joined()
        }
        var snapshot = DockerSnapshot()
        let images: [(String, String, Double, Double, Int, String)] = [
            ("acme/storefront-api", "latest", 1.24e9, 0.98e9, 0, "4 months ago"),
            ("acme/storefront-api", "v1.8.2", 1.21e9, 0.04e9, 0, "6 months ago"),
            ("<none>", "<none>", 0.86e9, 0.86e9, 0, "5 months ago"),
            ("mysql", "8.4", 0.60e9, 0.60e9, 0, "8 months ago"),
            ("<none>", "<none>", 0.61e9, 0.61e9, 0, "7 months ago"),
            ("grafana/grafana", "11.2.0", 0.45e9, 0.45e9, 1, "5 months ago"),
            ("postgres", "16", 0.44e9, 0.12e9, 1, "3 weeks ago"),
            ("python", "3.12-slim", 0.25e9, 0.16e9, 1, "5 weeks ago"),
            ("node", "20-alpine", 0.18e9, 0.14e9, 0, "2 months ago"),
            ("redis", "7", 0.12e9, 0.08e9, 1, "3 weeks ago"),
        ]
        snapshot.images = images.enumerated().map { index, row in
            Image(id: "sha256:" + hex(index + 1), repository: row.0, tag: row.1, size: Int64(row.2),
                  uniqueSize: Int64(row.3), containers: row.4, created: row.5)
        }
        let containers: [(String, String, String, String, Double, Int)] = [
            ("ml-notebook", "python:3.12-slim", "exited", "Exited (0) 3 weeks ago", 1.9e9, 1),
            ("old-api", "acme/storefront-api:v1.8.2", "exited", "Exited (137) 2 months ago", 0.42e9, 0),
            ("grafana", "grafana/grafana:11.2.0", "exited", "Exited (0) 5 months ago", 0.095e9, 1),
            ("storefront-db", "postgres:16", "running", "Up 2 hours", 0.064e9, 1),
            ("storefront-cache", "redis:7", "running", "Up 2 hours", 0.002e9, 0),
        ]
        snapshot.containers = containers.enumerated().map { index, row in
            Container(id: hex(100 + index), name: row.0, image: row.1, state: row.2, status: row.3, size: Int64(row.4), volumes: row.5)
        }
        snapshot.volumes = [
            Volume(name: "ml-notebook-data", size: 6_400_000_000, links: 1, isAnonymous: false),
            Volume(name: "legacy_mysql_data", size: 3_100_000_000, links: 0, isAnonymous: false),
            Volume(name: "storefront_pgdata", size: 2_800_000_000, links: 1, isAnonymous: false),
            Volume(name: hex(200), size: 1_200_000_000, links: 0, isAnonymous: true),
            Volume(name: "grafana-storage", size: 210_000_000, links: 1, isAnonymous: false),
        ]
        snapshot.buildCacheSize = 4_600_000_000
        snapshot.buildCacheReclaimable = 3_900_000_000
        snapshot.buildCacheEntries = 58
        return snapshot
    }
}
#endif
