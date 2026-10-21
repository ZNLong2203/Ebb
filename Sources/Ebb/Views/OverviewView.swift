import SwiftUI

struct OverviewView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DiskBar(disk: model.disk)
                hero
                HStack(alignment: .top, spacing: 18) {
                    topFolders
                    VStack(spacing: 18) {
                        systemData
                        scanStats
                    }
                    .frame(width: 300)
                }
                if let skipped = model.result?.skipped, !skipped.isEmpty {
                    skippedNote(skipped)
                }
            }
            .padding(24)
        }
    }

    private func skippedNote(_ skipped: [String]) -> some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(skipped.count) protected folders weren't scanned").font(.headline)
                    Text(skipped.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Give Ebb Full Disk Access to include them, then reopen Ebb.").font(.callout)
                    HStack {
                        Button("Open Privacy Settings") { Permissions.openFullDiskAccessSettings() }
                        Button("Reopen Ebb") { model.relaunch() }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var hero: some View {
        Card {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("You can free up to").font(.headline).foregroundStyle(.secondary)
                    Text(model.safeBytes.bytes)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(Tide.gradient)
                    Text("of caches and build files that rebuild themselves, plus \(model.reviewBytes.bytes) more worth reviewing.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.section = .junk } label: {
                    Label("Review & Clean", systemImage: "sparkles").padding(.horizontal, 8).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var topFolders: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Where your space goes").font(.headline)
                if let root = model.result?.root {
                    let top = Array(root.children.prefix(8))
                    let largest = max(top.first?.size ?? 1, 1)
                    ForEach(top) { node in
                        Button {
                            model.mapFocus = node.isDirectory ? node : root
                            model.section = .diskMap
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                                        .foregroundStyle(Tide.shallow)
                                    Text(node.name).lineLimit(1)
                                    Spacer()
                                    Text(node.size.bytes).monospacedDigit().foregroundStyle(.secondary)
                                }
                                GeometryReader { geo in
                                    Capsule().fill(Tide.gradient)
                                        .frame(width: max(4, geo.size.width * CGFloat(node.size) / CGFloat(largest)))
                                }
                                .frame(height: 6)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Explains the part of "System Data" Ebb can see, since that's what people ask about most.
    private var systemData: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("About \"System Data\"", systemImage: "questionmark.circle").font(.headline)
                Text("macOS lumps caches, developer tools, Docker and Time Machine snapshots into System Data.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Local snapshots", value: "\(model.disk.localSnapshots)")
                LabeledContent("Purgeable", value: model.disk.purgeable.bytes)
                Text("macOS removes snapshots and purgeable data by itself when space runs low.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var scanStats: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Last scan", systemImage: "clock").font(.headline)
                if let result = model.result {
                    LabeledContent("Folder", value: model.scanRootDisplay)
                    LabeledContent("Files", value: result.fileCount.formatted())
                    LabeledContent("Size", value: result.root.size.bytes)
                    LabeledContent("Took", value: String(format: "%.1f s", result.duration))
                    if result.unreadableCount > 0 {
                        LabeledContent("Skipped", value: "\(result.unreadableCount.formatted()) protected")
                    }
                }
            }
            .monospacedDigit()
        }
    }
}

/// Startup disk as used / purgeable / free, like the bar in System Settings but with numbers.
struct DiskBar: View {
    let disk: DiskInfo

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Macintosh HD", systemImage: "internaldrive.fill").font(.headline)
                    Spacer()
                    Text("\(disk.free.bytes) free of \(disk.total.bytes)").foregroundStyle(.secondary).monospacedDigit()
                }
                GeometryReader { geo in
                    let total = CGFloat(max(disk.total, 1))
                    HStack(spacing: 2) {
                        Rectangle().fill(Tide.gradient).frame(width: geo.size.width * CGFloat(disk.used) / total)
                        Rectangle().fill(Tide.sand).frame(width: geo.size.width * CGFloat(disk.purgeable) / total)
                        Rectangle().fill(.quaternary)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 14)
                HStack(spacing: 16) {
                    legend(Tide.shallow, "Used", disk.used)
                    legend(Tide.sand, "Purgeable", disk.purgeable)
                    legend(.secondary.opacity(0.4), "Free", disk.free)
                }
                .font(.caption)
            }
        }
    }

    private func legend(_ color: Color, _ title: String, _ value: Int64) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).foregroundStyle(.secondary)
            Text(value.bytes).monospacedDigit()
        }
    }
}
