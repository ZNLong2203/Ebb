import SwiftUI

struct OverviewView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                greeting
                hero
                DiskProjection(model: model)
                quickWins
                HStack(alignment: .top, spacing: 18) {
                    TopFolders(model: model)
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
            .padding(28)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.salutation).font(.rounded(30, .bold))
            Text("Here's what the tide uncovered in \(model.scanRootDisplay).")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private static var salutation: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    private var hero: some View {
        let safeItems = model.allItems.filter { $0.safety == .safe && $0.isPreselected }
        return Card(padding: 24) {
            HStack(alignment: .center, spacing: 32) {
                JunkDonut(groups: model.groups) { model.section = .junk }
                VStack(alignment: .leading, spacing: 10) {
                    Text("You can safely free").font(.headline).foregroundStyle(.secondary)
                    Text(model.safeBytes.bytes)
                        .font(.rounded(56, .bold))
                        .foregroundStyle(Tide.gradient)
                        .contentTransition(.numericText())
                    Text("Caches and build files that rebuild themselves, plus \(model.reviewBytes.bytes) more worth a look.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button { model.requestClean(safeItems) } label: {
                            Label("Clean Safe Items", systemImage: "sparkles")
                        }
                        .buttonStyle(TideButtonStyle())
                        .disabled(safeItems.isEmpty || model.isScanning || model.cleaner.isWorking)
                        Button("Review Everything") { model.section = .junk }
                            .buttonStyle(GlassButtonStyle())
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private var quickWins: some View {
        let wins = Array(model.allItems.filter { $0.safety == .safe }.sorted { $0.size > $1.size }.prefix(3))
        if !wins.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Quick wins", systemImage: "bolt.fill").font(.headline).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    ForEach(wins) { item in QuickWinCard(item: item, model: model) }
                }
            }
        }
    }

    private var systemData: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("What is \"System Data\"?", systemImage: "questionmark.bubble.fill")
                    .font(.headline)
                    .foregroundStyle(Tide.ocean)
                Text("macOS lumps caches, developer tools, Docker and Time Machine snapshots into System Data. Ebb breaks the parts it can see into the lists here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                LabeledContent("Local snapshots", value: "\(model.disk.localSnapshots)")
                LabeledContent("Purgeable", value: model.disk.purgeable.bytes)
                Text("macOS clears snapshots and purgeable space by itself when the disk runs low.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var scanStats: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Last scan", systemImage: "clock.fill").font(.headline).foregroundStyle(Tide.ocean)
                if let result = model.result {
                    LabeledContent("Files read", value: result.fileCount.formatted())
                    LabeledContent("Size", value: result.root.size.bytes)
                    LabeledContent("Took", value: String(format: "%.1f s", result.duration))
                    LabeledContent("When", value: result.finishedAt.formatted(date: .omitted, time: .shortened))
                }
            }
            .monospacedDigit()
        }
    }

    private func skippedNote(_ skipped: [String]) -> some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                SymbolTile(symbol: "lock.shield.fill", color: .orange, size: 38)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(skipped.count) protected folders weren't scanned").font(.headline)
                    Text(skipped.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Allow Full Disk Access to include them, then reopen Ebb.").font(.callout)
                    HStack {
                        Button("Open Settings") { Permissions.openFullDiskAccessSettings() }
                            .buttonStyle(TideButtonStyle(compact: true))
                        Button("Reopen Ebb") { model.relaunch() }
                            .buttonStyle(GlassButtonStyle())
                    }
                }
            }
        }
    }
}

// MARK: - Donut

/// Reclaimable space by group. Hovering a slice names it in the middle.
private struct JunkDonut: View {
    let groups: [JunkGroup]
    let onTap: () -> Void

    @ViewState private var hovered: Int?

    private let size: CGFloat = 190
    private let thickness: CGFloat = 26

    var body: some View {
        let slices = groups.filter { $0.total > 0 }.sorted { $0.total > $1.total }
        let total = Double(max(slices.reduce(0) { $0 + $1.total }, 1))
        let fractions = slices.map { Double($0.total) / total }
        let starts = fractions.indices.map { fractions[..<$0].reduce(0, +) }

        ZStack {
            Circle().stroke(.quaternary.opacity(0.5), lineWidth: thickness)
            ForEach(Array(slices.enumerated()), id: \.offset) { index, group in
                Circle()
                    .trim(from: starts[index], to: max(starts[index], starts[index] + fractions[index] - 0.006))
                    .stroke(Tide.color(forGroup: group.id), style: StrokeStyle(lineWidth: hovered == index ? thickness + 8 : thickness))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovered)
            }
            VStack(spacing: 2) {
                if let hovered, hovered < slices.count {
                    Text(slices[hovered].title).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
                    Text(slices[hovered].total.bytes).font(.rounded(22, .bold))
                    Text("\(slices[hovered].items.count) items").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Found").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(Int64(total).bytes).font(.rounded(22, .bold))
                    Text("across \(slices.count) groups").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: size - thickness * 2 - 12)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                let dx = point.x - size / 2, dy = point.y - size / 2
                let radius = hypot(dx, dy)
                guard radius > size / 2 - thickness - 6, radius < size / 2 + 6 else { hovered = nil; return }
                // 0 at twelve o'clock, growing clockwise, like the trimmed circles above.
                var angle = atan2(dy, dx) + .pi / 2
                if angle < 0 { angle += 2 * .pi }
                let position = angle / (2 * .pi)
                hovered = starts.indices.last { starts[$0] <= position }
            case .ended:
                hovered = nil
            }
        }
        .onTapGesture(perform: onTap)
        .help("Open Developer Junk")
    }
}

// MARK: - Disk projection

/// The startup disk now, and how it would look after cleaning the current selection.
private struct DiskProjection: View {
    let model: AppModel

    var body: some View {
        let disk = model.disk
        let reclaim = min(model.selectedBytes + model.cleaner.trashedBytes, disk.used)
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Macintosh HD", systemImage: "internaldrive.fill").font(.headline)
                    Spacer()
                    Text(disk.free.bytes).font(.rounded(17, .bold)).monospacedDigit()
                    Text("free now").foregroundStyle(.secondary)
                    if reclaim > 0 {
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(model.projectedFree.bytes).font(.rounded(17, .bold)).foregroundStyle(Tide.kelp).monospacedDigit()
                        Text("after cleaning").foregroundStyle(.secondary)
                    }
                }
                GeometryReader { geo in
                    let total = CGFloat(max(disk.total, 1))
                    HStack(spacing: 2) {
                        Rectangle().fill(Tide.gradient).frame(width: geo.size.width * CGFloat(disk.used - reclaim) / total)
                        Rectangle().fill(Tide.kelp.opacity(0.85)).frame(width: geo.size.width * CGFloat(reclaim) / total)
                        Rectangle().fill(Tide.sand).frame(width: geo.size.width * CGFloat(disk.purgeable) / total)
                        Rectangle().fill(.quaternary)
                    }
                    .clipShape(Capsule())
                    .animation(.spring(response: 0.5), value: reclaim)
                }
                .frame(height: 16)
                HStack(spacing: 18) {
                    legend(Tide.ocean, "Used", disk.used - reclaim)
                    legend(Tide.kelp, "You can free", reclaim)
                    legend(Tide.sand, "Purgeable", disk.purgeable)
                    legend(.secondary.opacity(0.4), "Free", disk.free)
                    Spacer()
                    Text("of \(disk.total.bytes)").foregroundStyle(.tertiary)
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

// MARK: - Cards

private struct QuickWinCard: View {
    let item: JunkItem
    let model: AppModel

    @ViewState private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                JunkIcon(item: item, artifactKind: model.artifactKind(for: item), size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.headline).lineLimit(1)
                    Text(item.size.bytes).font(.rounded(20, .bold)).foregroundStyle(Tide.gradient)
                }
            }
            Text(item.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
            Button { model.requestClean([item]) } label: { Label("Clean", systemImage: "sparkles") }
                .buttonStyle(TideButtonStyle(compact: true))
                .disabled(model.isScanning || model.cleaner.isWorking)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(hovering ? Tide.lagoon.opacity(0.6) : Color.secondary.opacity(0.15)))
        .shadow(color: .black.opacity(hovering ? 0.12 : 0.05), radius: hovering ? 12 : 6, y: 3)
        .offset(y: hovering ? -2 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct TopFolders: View {
    let model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Label("Where your space goes", systemImage: "chart.bar.fill").font(.headline).foregroundStyle(Tide.ocean)
                if let root = model.result?.root {
                    let top = Array(root.children.prefix(8))
                    let largest = max(top.first?.size ?? 1, 1)
                    ForEach(Array(top.enumerated()), id: \.offset) { index, node in
                        FolderBar(node: node, fraction: CGFloat(node.size) / CGFloat(largest),
                                  color: Treemap.palette[index % Treemap.palette.count]) {
                            model.mapFocus = node.isDirectory && !node.children.isEmpty ? node : nil
                            model.section = .diskMap
                        }
                    }
                }
            }
        }
    }
}

private struct FolderBar: View {
    let node: ScanNode
    let fraction: CGFloat
    let color: Color
    let action: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: IconCache.icon(forFile: node.path)).resizable().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(node.name).lineLimit(1)
                        Spacer()
                        Text(node.size.bytes).monospacedDigit().foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary.opacity(0.5))
                            Capsule().fill(color.gradient).frame(width: max(6, geo.size.width * fraction))
                        }
                    }
                    .frame(height: 7)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).opacity(hovering ? 1 : 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.secondary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open in Disk Map")
    }
}
