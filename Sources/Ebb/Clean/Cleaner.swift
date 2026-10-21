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
        /// Estimated space released by tools' own commands (docker rmi, conda clean…).
        var freedByCommands: Int64 = 0
        var commands: [CommandRun] = []
        var failures: [String] = []
        var emptiedTrash = false
    }

    /// Live state of the running cleanup, shown while it works so it never looks frozen.
    struct Progress {
        var total = 0
        var completed = 0
        var bytesTotal: Int64 = 0
        var bytesDone: Int64 = 0
        var current = ""
        var detail = ""

        var fraction: Double { bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : Double(completed) / Double(max(total, 1)) }
    }

    private(set) var history: [TrashedItem] = []
    private(set) var isWorking = false
    private(set) var progress = Progress()

    /// Bytes sitting in the Trash because of Ebb; they only become free space once the Trash is emptied.
    var trashedBytes: Int64 { history.reduce(0) { $0 + $1.size } }

    func clean(_ items: [JunkItem]) async -> Report {
        isWorking = true
        defer { isWorking = false }
        var report = Report()
        progress = Progress(total: items.count, bytesTotal: items.reduce(0) { $0 + $1.size })
        for item in items {
            progress.current = item.title
            switch item.action {
            case .trash(let targets):
                progress.detail = "Moving to the Trash…"
                for target in targets {
                    do {
                        try await moveToTrash(URL(fileURLWithPath: target.path), size: target.size)
                        report.movedToTrash += target.size
                    } catch {
                        report.failures.append("\((target.path as NSString).abbreviatingWithTildeInPath): \(error.localizedDescription)")
                    }
                }
            case .command(let command):
                progress.detail = "Running \(command)"
                let (status, output) = await Self.run(command)
                report.commands.append(CommandRun(command: command, output: output, succeeded: status == 0))
                if status == 0 {
                    report.freedByCommands += item.size
                } else {
                    report.failures.append("`\(command)` exited with status \(status)")
                }
            case .emptyTrash:
                progress.detail = "Emptying the Trash…"
                if let error = await emptyTrash() { report.failures.append(error) } else { report.emptiedTrash = true }
            }
            progress.completed += 1
            progress.bytesDone += item.size
        }
        // Keep the last item on screen; the sheet lingers a moment before showing the result.
        progress.detail = "Finishing up…"
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

/// One trip through the cleanup sheet.
struct CleanFlow: Identifiable {
    enum Phase {
        case confirm
        case running
        case done(Cleaner.Report)
    }

    let id = UUID()
    let items: [JunkItem]
    var phase: Phase = .confirm
}
