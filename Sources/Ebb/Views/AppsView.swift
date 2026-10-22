import SwiftUI

/// Uninstall apps completely, find ones you never open, and sweep up what deleted apps left behind.
struct AppsView: View {
    @Bindable var model: AppModel

    enum Filter: String, CaseIterable { case all = "All", unused = "Not opened in 90 days", large = "Over 1 GB" }
    enum Sort: String, CaseIterable, Identifiable { case size = "Largest first", lastUsed = "Least recently used", name = "Name"; var id: String { rawValue } }

    @ViewState private var filter: Filter = .all
    @ViewState private var sort: Sort = .size
    @ViewState private var search = ""
    @ViewState private var expanded: String?

    private var visibleApps: [InstalledApp] {
        let query = search.lowercased()
        let filtered = model.apps.apps.filter { app in
            (query.isEmpty || app.name.lowercased().contains(query))
                && (filter != .unused || app.isUnused)
                && (filter != .large || app.totalSize >= 1_000_000_000)
        }
        switch sort {
        case .size: return filtered.sorted { $0.totalSize > $1.totalSize }
        case .lastUsed: return filtered.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        case .name: return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        let apps = model.apps
        VStack(spacing: 0) {
            header
            if case .ready = apps.state {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        summary
                        VStack(spacing: 2) {
                            ForEach(visibleApps) { app in
                                AppRow(app: app, model: model, isExpanded: expanded == app.id) {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                        expanded = expanded == app.id ? nil : app.id
                                    }
                                }
                            }
                            if visibleApps.isEmpty {
                                Text("No apps match.").foregroundStyle(.secondary).padding(20)
                            }
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background.secondary))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator.opacity(0.5)))
                        if !apps.orphans.isEmpty { orphansCard }
                    }
                    .padding(24)
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Measuring your apps and what they keep in ~/Library…").foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .task {
            if case .idle = apps.state, let result = model.result { apps.load(protected: result.protected) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Applications").font(.rounded(28, .bold))
                    Text("Uninstall apps completely, including the data they leave in ~/Library.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Sort", selection: $sort) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.menu)
                    .fixedSize()
            }
            HStack(spacing: 8) {
                ForEach(Filter.allCases, id: \.self) { option in
                    FilterChip(title: option.rawValue, isOn: filter == option) { filter = option }
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search apps", text: $search).textFieldStyle(.plain).frame(width: 150)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(.quaternary.opacity(0.6)))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 6)
    }

    private var summary: some View {
        let apps = model.apps
        let unused = apps.unusedApps
        return HStack(spacing: 12) {
            SummaryTile(symbol: "square.grid.2x2.fill", color: Tide.lavender, title: "Apps",
                        value: "\(apps.apps.count)", caption: apps.apps.reduce(0) { $0 + $1.totalSize }.bytes + " in total")
            SummaryTile(symbol: "moon.zzz.fill", color: .orange, title: "Not opened in 90 days",
                        value: "\(unused.count)", caption: unused.reduce(0) { $0 + $1.totalSize }.bytes + " you could reclaim")
            SummaryTile(symbol: "puzzlepiece.extension.fill", color: Tide.coral, title: "Leftovers from deleted apps",
                        value: apps.orphans.reduce(0) { $0 + $1.size }.bytes, caption: "\(apps.orphans.count) apps already gone")
        }
    }

    private var orphansCard: some View {
        let apps = model.apps
        let selected = apps.orphanItems()
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SymbolTile(symbol: "puzzlepiece.extension.fill", color: Tide.coral, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Leftovers from deleted apps").font(.headline)
                    Text("Data in ~/Library named after apps that are no longer installed and untouched for 30+ days.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !selected.isEmpty {
                    Button { model.requestClean(selected) } label: {
                        Label("Remove \(selected.reduce(0) { $0 + $1.size }.bytes)…", systemImage: "trash")
                    }
                    .buttonStyle(TideButtonStyle(compact: true))
                }
            }
            ForEach(apps.orphans) { orphan in
                HStack(spacing: 12) {
                    RoundCheck(isOn: Binding(
                        get: { apps.selectedOrphans.contains(orphan.id) },
                        set: { on in if on { apps.selectedOrphans.insert(orphan.id) } else { apps.selectedOrphans.remove(orphan.id) } }))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(orphan.bundleID).lineLimit(1)
                        Text("\(Set(orphan.items.map(\.kind)).sorted().joined(separator: ", ")) · last changed \(orphan.lastModified.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    SafetyBadge(safety: .review)
                    Text(orphan.size.bytes).monospacedDigit().frame(width: 80, alignment: .trailing)
                    Button { model.reveal(orphan.items[0].path) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

struct SummaryTile: View {
    let symbol: String
    let color: Color
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SymbolTile(symbol: symbol, color: color, size: 30)
            Text(title).font(.headline).lineLimit(1)
            Text(value).font(.rounded(22, .bold)).monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

private struct AppRow: View {
    let app: InstalledApp
    @Bindable var model: AppModel
    let isExpanded: Bool
    let toggle: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: IconCache.icon(forFile: app.path)).resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.name).fontWeight(.medium).lineLimit(1)
                        if let version = app.version { Text(version).font(.caption).foregroundStyle(.tertiary) }
                        if app.isAppStore {
                            Text("App Store").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(.quaternary.opacity(0.7)))
                        }
                    }
                    Text(lastUsedText).font(.caption).foregroundStyle(app.isUnused ? .orange : .secondary)
                }
                Spacer(minLength: 12)
                if !app.leftovers.isEmpty {
                    Text("+\(app.leftoversSize.bytes) data").font(.caption).foregroundStyle(.secondary)
                }
                Text(app.totalSize.bytes).monospacedDigit().fontWeight(.medium).frame(width: 84, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    detailRow(symbol: "app.fill", title: "App bundle", path: app.path, size: app.size)
                    ForEach(app.leftovers) { leftover in
                        detailRow(symbol: "folder.fill", title: leftover.kind, path: leftover.path, size: leftover.size)
                    }
                    if app.leftovers.isEmpty {
                        Text("No data found in ~/Library for this app.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Everything above goes to the Trash. You can put it back until you empty it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button { model.reveal(app.path) } label: { Label("Show in Finder", systemImage: "folder") }
                            .buttonStyle(GlassButtonStyle())
                        if app.isRunning {
                            Button { quit() } label: { Label("Quit \(app.name)", systemImage: "xmark.circle") }
                                .buttonStyle(GlassButtonStyle())
                        } else {
                            Button { model.requestClean([model.apps.uninstallItem(app)]) } label: {
                                Label("Uninstall", systemImage: "trash")
                            }
                            .buttonStyle(TideButtonStyle(compact: true))
                            .disabled(model.cleaner.isWorking)
                        }
                    }
                }
                .padding(.leading, 58)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(hovering || isExpanded ? Color.secondary.opacity(0.07) : .clear))
        .onHover { hovering = $0 }
    }

    private var lastUsedText: String {
        guard let lastUsed = app.lastUsed else { return "Never opened, as far as Spotlight knows" }
        return "Last opened \(lastUsed.formatted(.relative(presentation: .named)))"
    }

    private func detailRow(symbol: String, title: String, path: String, size: Int64) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            Text(title).font(.callout).frame(width: 140, alignment: .leading)
            Text((path as NSString).abbreviatingWithTildeInPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(size.bytes).font(.callout).monospacedDigit()
        }
    }

    private func quit() {
        guard let id = app.bundleID else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
    }
}
