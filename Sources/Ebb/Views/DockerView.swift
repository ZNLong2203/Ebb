import SwiftUI

/// Docker, broken down: which images, containers, volumes and build cache take space, and what can go.
struct DockerView: View {
    @Bindable var model: AppModel

    enum Tab: String, CaseIterable, Identifiable {
        case images = "Images", containers = "Containers", volumes = "Volumes", buildCache = "Build Cache"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .images: "square.stack.3d.up.fill"
            case .containers: "shippingbox.fill"
            case .volumes: "cylinder.split.1x2.fill"
            case .buildCache: "hammer.fill"
            }
        }
        var color: Color {
            switch self {
            case .images: Tide.ocean
            case .containers: Tide.lagoon
            case .volumes: Tide.coral
            case .buildCache: Tide.sand
            }
        }
    }

    @ViewState private var tab: Tab = .images

    var body: some View {
        let docker = model.docker
        VStack(spacing: 0) {
            header
            switch docker.state {
            case .notInstalled:
                ContentUnavailableView("Docker isn't installed", systemImage: "ferry",
                                       description: Text("Install Docker Desktop and Ebb will show what it stores."))
                    .frame(maxHeight: .infinity)
            case .notRunning:
                notRunning.frame(maxHeight: .infinity)
            case .loading:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Asking Docker what it stores…").foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Docker didn't answer", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message).font(.caption.monospaced())
                } actions: {
                    Button("Try Again") { Task { await docker.refresh() } }.buttonStyle(TideButtonStyle(compact: true))
                }
                .frame(maxHeight: .infinity)
            case .ready(let snapshot):
                content(snapshot)
            }
        }
        .task {
            await docker.refresh()
            // While Docker is starting, check again every few seconds.
            while !Task.isCancelled, case .notRunning = docker.state {
                try? await Task.sleep(for: .seconds(3))
                await docker.refresh()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Docker").font(.rounded(28, .bold))
                Text("What Docker keeps on your Mac, and what you can safely let go.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await model.docker.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .buttonStyle(GlassButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    private var notRunning: some View {
        VStack(spacing: 16) {
            SymbolTile(symbol: "ferry.fill", color: Tide.ocean, size: 64)
            Text("Docker Desktop isn't running").font(.rounded(22, .bold))
            Text("Ebb asks Docker itself for sizes, so it needs to be running. Start it and this page fills in automatically.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button { model.docker.startDocker() } label: { Label("Start Docker", systemImage: "play.fill") }
                .buttonStyle(TideButtonStyle())
        }
        .padding(40)
    }

    private func content(_ snapshot: DockerSnapshot) -> some View {
        let docker = model.docker
        let removable = Dictionary(uniqueKeysWithValues: docker.items(in: snapshot).map { ($0.id, $0) })
        let selected = docker.selectedItems()
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        StatCard(tab: .images, isSelected: tab == .images, total: snapshot.imagesSize,
                                 caption: "\(snapshot.images.count) images · \(snapshot.reclaimableImages.bytes) unused") { tab = .images }
                        StatCard(tab: .containers, isSelected: tab == .containers, total: snapshot.containersSize,
                                 caption: "\(snapshot.containers.count) containers · \(snapshot.containers.filter { !$0.isRunning }.count) stopped") { tab = .containers }
                        StatCard(tab: .volumes, isSelected: tab == .volumes, total: snapshot.volumesSize,
                                 caption: "\(snapshot.volumes.count) volumes · \(snapshot.reclaimableVolumes.bytes) unused") { tab = .volumes }
                        StatCard(tab: .buildCache, isSelected: tab == .buildCache, total: snapshot.buildCacheSize,
                                 caption: "\(snapshot.buildCacheReclaimable.bytes) unused") { tab = .buildCache }
                    }
                    if let image = model.allItems.first(where: { $0.id == "docker" }) {
                        Label("Docker Desktop's disk image takes \(image.size.bytes) on your Mac. Removing things here frees space inside it, and Docker hands it back to macOS over time.",
                              systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    quickSelect(snapshot)
                    VStack(spacing: 2) {
                        rows(snapshot, removable: removable)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background.secondary))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator.opacity(0.5)))
                }
                .padding(24)
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selected.count) selected").font(.headline)
                    Text("Removed with Docker's own commands. This can't be undone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(selected.reduce(0) { $0 + $1.size }.bytes)
                    .font(.rounded(26, .bold))
                    .foregroundStyle(Tide.gradient)
                Button { model.requestClean(selected) } label: { Label("Remove…", systemImage: "trash") }
                    .buttonStyle(TideButtonStyle())
                    .disabled(selected.isEmpty || model.cleaner.isWorking)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    @ViewBuilder private func quickSelect(_ snapshot: DockerSnapshot) -> some View {
        let docker = model.docker
        HStack(spacing: 8) {
            switch tab {
            case .images:
                FilterChip(title: "Select untagged", symbol: "tag.slash", isOn: false) {
                    docker.selection.formUnion(snapshot.images.filter { $0.isDangling && $0.containers == 0 }.map { "docker-image:" + $0.id })
                }
                FilterChip(title: "Select all unused", symbol: "checklist", isOn: false) {
                    docker.selection.formUnion(snapshot.images.filter { $0.containers == 0 }.map { "docker-image:" + $0.id })
                }
            case .containers:
                FilterChip(title: "Select all stopped", symbol: "stop.circle", isOn: false) {
                    docker.selection.formUnion(snapshot.containers.filter { !$0.isRunning }.map { "docker-container:" + $0.id })
                }
            case .volumes:
                Label("Volumes can hold databases and other data. Only unused ones can be selected, and none are selected for you.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Tide.coral)
            case .buildCache:
                EmptyView()
            }
            Spacer()
            if !docker.selection.isEmpty {
                Button("Clear selection") { docker.selection = [] }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func rows(_ snapshot: DockerSnapshot, removable: [String: JunkItem]) -> some View {
        switch tab {
        case .images:
            ForEach(snapshot.images) { image in
                DockerRow(model: model, item: removable["docker-image:" + image.id], symbol: Tab.images.symbol, color: Tab.images.color,
                          title: image.name, detail: "\(image.shortID) · created \(image.created)",
                          size: image.size,
                          note: image.uniqueSize < image.size ? "frees \(image.uniqueSize.bytes)" : nil,
                          blocked: image.containers > 0 ? "Used by \(image.containers) container\(image.containers == 1 ? "" : "s")" : nil)
            }
        case .containers:
            ForEach(snapshot.containers) { container in
                DockerRow(model: model, item: removable["docker-container:" + container.id], symbol: Tab.containers.symbol,
                          color: Tab.containers.color, title: container.name, detail: "\(container.image) · \(container.status)",
                          size: container.size, note: nil, blocked: container.isRunning ? "Running" : nil)
            }
        case .volumes:
            ForEach(snapshot.volumes) { volume in
                DockerRow(model: model, item: removable["docker-volume:" + volume.name], symbol: Tab.volumes.symbol,
                          color: Tab.volumes.color, title: volume.displayName,
                          detail: volume.links == 0 ? "Not used by any container" : "Mounted by \(volume.links) container\(volume.links == 1 ? "" : "s")",
                          size: volume.size, note: nil,
                          blocked: volume.links > 0 ? "In use: remove its containers first" : nil)
            }
        case .buildCache:
            DockerRow(model: model, item: removable["docker-buildcache"], symbol: Tab.buildCache.symbol, color: Tab.buildCache.color,
                      title: "Unused build cache", detail: "\(snapshot.buildCacheEntries) entries · \(snapshot.buildCacheSize.bytes) in total",
                      size: snapshot.buildCacheReclaimable, note: nil,
                      blocked: snapshot.buildCacheReclaimable == 0 ? "Nothing unused" : nil)
        }
    }
}

private struct StatCard: View {
    let tab: DockerView.Tab
    let isSelected: Bool
    let total: Int64
    let caption: String
    let action: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SymbolTile(symbol: tab.symbol, color: tab.color, size: 30)
                    Spacer()
                    if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(tab.color) }
                }
                Text(tab.rawValue).font(.headline)
                Text(total.bytes).font(.rounded(22, .bold)).monospacedDigit()
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? tab.color : Color.secondary.opacity(hovering ? 0.35 : 0.15), lineWidth: isSelected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct DockerRow: View {
    @Bindable var model: AppModel
    /// The cleanup item when this thing can be removed; nil when it's blocked.
    let item: JunkItem?
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    let size: Int64
    let note: String?
    let blocked: String?

    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            if let item, blocked == nil {
                RoundCheck(isOn: Binding(
                    get: { model.docker.selection.contains(item.id) },
                    set: { on in if on { model.docker.selection.insert(item.id) } else { model.docker.selection.remove(item.id) } }
                ))
            } else {
                Image(systemName: "lock.fill").foregroundStyle(.tertiary).frame(width: 20)
            }
            SymbolTile(symbol: symbol, color: color, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if let blocked {
                Text(blocked)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary.opacity(0.6)))
            } else if let item {
                SafetyBadge(safety: item.safety)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(size.bytes).monospacedDigit().fontWeight(.medium)
                if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Color.secondary.opacity(0.07) : .clear))
        .opacity(blocked == nil ? 1 : 0.7)
        .onHover { hovering = $0 }
        .help(item?.explanation ?? blocked ?? "")
    }
}
