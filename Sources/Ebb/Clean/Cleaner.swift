import AppKit

/// Performs cleanups and remembers what went to the Trash so it can be put back.
@Observable @MainActor
final class Cleaner {
    struct TrashedItem: Identifiable {
        let id = UUID()
        let original: URL
        let trashed: URL
        let size: Int64
    }

    struct CommandRun: Identifiable {
        let id = UUID()
        let command: String
        let output: String
        let succeeded: Bool
    }

    struct Report {
        var movedToTrash: Int64 = 0
        var commands: [CommandRun] = []
        var failures: [String] = []
        var emptiedTrash = false
    }

    private(set) var history: [TrashedItem] = []
    private(set) var isWorking = false

    /// Bytes sitting in the Trash because of Ebb; they only become free space once the Trash is emptied.
    var trashedBytes: Int64 { history.reduce(0) { $0 + $1.size } }

    func clean(_ items: [JunkItem]) async -> Report {
        isWorking = true
        defer { isWorking = false }
        var report = Report()
        for item in items {
            switch item.action {
            case .trash(let targets):
                for target in targets {
                    do {
                        try await moveToTrash(URL(fileURLWithPath: target.path), size: target.size)
                        report.movedToTrash += target.size
                    } catch {
                        report.failures.append("\((target.path as NSString).abbreviatingWithTildeInPath): \(error.localizedDescription)")
                    }
                }
            case .command(let command):
                let (status, output) = await Self.run(command)
                report.commands.append(CommandRun(command: command, output: output, succeeded: status == 0))
                if status != 0 { report.failures.append("`\(command)` exited with status \(status)") }
            case .emptyTrash:
                if let error = await emptyTrash() { report.failures.append(error) } else { report.emptiedTrash = true }
            }
        }
        return report
    }

    func moveToTrash(_ url: URL, size: Int64) async throws {
        let trashed = try await Task.detached {
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            return result as URL?
        }.value
        if let trashed {
            history.append(TrashedItem(original: url, trashed: trashed, size: size))
        }
    }

    /// Moves an item back from the Trash to where it was.
    func restore(_ item: TrashedItem) throws {
        try FileManager.default.createDirectory(at: item.original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: item.trashed, to: item.original)
        history.removeAll { $0.id == item.id }
    }

    /// Puts back everything Ebb trashed this session; returns the names it couldn't restore.
    func restoreAll() -> [String] {
        var failures: [String] = []
        for item in history.reversed() {
            do { try restore(item) } catch { failures.append(item.original.lastPathComponent) }
        }
        return failures
    }

    /// Asks Finder to empty the Trash (out of process, so the UI stays responsive). Returns an error message on failure.
    func emptyTrash() async -> String? {
        let (status, output) = await Self.run("osascript -e 'tell application \"Finder\" to empty trash'")
        guard status == 0 else {
            return "Couldn't empty the Trash: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        history.removeAll()
        return nil
    }

    /// Runs a command through the user's login shell so Homebrew, conda and Docker are on PATH.
    nonisolated static func run(_ command: String) async -> (Int32, String) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return (Int32(-1), error.localizedDescription)
            }
            // Drain while it runs: a full pipe would otherwise block the command forever.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}

/// `Cleaner.Report` wrapped so it can drive `.sheet(item:)`.
struct CleanReportBox: Identifiable {
    let id = UUID()
    let report: Cleaner.Report
}
