import AppKit

/// Capacity of the startup volume, split the way macOS counts it.
struct DiskInfo {
    var total: Int64 = 0
    /// Truly free right now.
    var free: Int64 = 0
    /// Free plus space macOS can reclaim on its own (local snapshots, purgeable caches).
    var available: Int64 = 0
    var localSnapshots = 0

    var purgeable: Int64 { max(0, available - free) }
    var used: Int64 { max(0, total - available) }

    static func current() -> DiskInfo {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return DiskInfo() }
        var info = DiskInfo()
        info.total = Int64(values.volumeTotalCapacity ?? 0)
        info.free = Int64(values.volumeAvailableCapacity ?? 0)
        info.available = max(info.free, values.volumeAvailableCapacityForImportantUsage ?? 0)
        return info
    }

    /// Time Machine keeps hourly local snapshots that show up as "System Data".
    static func countLocalSnapshots() async -> Int {
        let (status, output) = await Cleaner.run("/usr/bin/tmutil listlocalsnapshots /")
        guard status == 0 else { return 0 }
        return output.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }.count
    }
}

enum Permissions {
    /// Folders macOS only lets apps with Full Disk Access list. The first one that exists decides.
    private static let probes = ["~/Library/Safari", "~/Library/Mail", "~/Library/Messages", "~/Library/Containers/com.apple.Safari"]

    static var hasFullDiskAccess: Bool {
        for probe in probes.map({ ($0 as NSString).expandingTildeInPath }) where FileManager.default.fileExists(atPath: probe) {
            return (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil
        }
        return false
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
