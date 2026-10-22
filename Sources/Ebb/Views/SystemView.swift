import SwiftUI

/// What starts with your Mac, plus a few safe maintenance fixes.
struct SystemView: View {
    @Bindable var model: AppModel

    var body: some View {
        let system = model.system
        let removable = system.cleanupItems()
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Startup & Maintenance").font(.rounded(28, .bold))
                    Text("What launches in the background, which items are broken, and one-click fixes using macOS's own tools.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { system.load() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(GlassButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    backgroundItems
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Maintenance", systemImage: "wrench.and.screwdriver.fill").font(.headline).foregroundStyle(Tide.ocean)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                            ForEach(MaintenanceTask.all) { task in
                                MaintenanceCard(task: task, system: system)
                            }
                        }
                        Text("Not here on purpose: \"free up RAM\" (macOS manages memory better on its own) and removing languages or app architectures (it breaks app signatures).")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(24)
            }
            if !removable.isEmpty {
                HStack {
                    Text("\(removable.count) selected").font(.headline)
                    Spacer()
                    Button { model.requestClean(removable) } label: { Label("Remove from Startup…", systemImage: "power") }
                        .buttonStyle(TideButtonStyle())
                        .disabled(model.cleaner.isWorking)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        }
        .task { if !system.isLoaded { system.load() } }
    }

    private var backgroundItems: some View {
        let system = model.system
        let broken = system.items.filter(\.isBroken)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Background items", systemImage: "power.circle.fill").font(.headline).foregroundStyle(Tide.ocean)
                Spacer()
                if !broken.isEmpty {
                    FilterChip(title: "Select \(broken.filter(\.isRemovable).count) broken", symbol: "bandage", tint: Tide.coral, isOn: false) {
                        system.selection.formUnion(broken.filter(\.isRemovable).map(\.id))
                    }
                }
            }
            Text("Launch agents and daemons start with your Mac or at login. Broken ones point to a program that no longer exists, usually from an app you deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(spacing: 2) {
                ForEach(system.items) { item in
                    BackgroundItemRow(item: item, model: model)
                }
                if system.isLoaded && system.items.isEmpty {
                    Text("No background items found.").foregroundStyle(.secondary).padding(16)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        }
    }
}

private struct BackgroundItemRow: View {
    let item: BackgroundItem
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            if item.isRemovable {
                RoundCheck(isOn: Binding(
                    get: { model.system.selection.contains(item.id) },
                    set: { on in if on { model.system.selection.insert(item.id) } else { model.system.selection.remove(item.id) } }))
            } else {
                Image(systemName: "lock.fill").foregroundStyle(.tertiary).frame(width: 20)
                    .help("Installed for all users; removing it needs an administrator. Use Show in Finder.")
            }
            SymbolTile(symbol: item.isBroken ? "bandage.fill" : "power", color: item.isBroken ? Tide.coral : Tide.lavender, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.owner.map { "\($0) · \(item.label)" } ?? item.label).lineLimit(1).truncationMode(.middle)
                Text(item.program ?? "(launched from its app)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if item.isBroken {
                Text("Broken").font(.caption.weight(.semibold)).foregroundStyle(Tide.coral)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Tide.coral.opacity(0.12)))
            }
            if item.runsAtLoad {
                Text("At login").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(.quaternary.opacity(0.6)))
            }
            Text(item.scope.rawValue).font(.caption).foregroundStyle(.tertiary).frame(width: 96, alignment: .trailing)
            Button { model.reveal(item.path) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Show in Finder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private struct MaintenanceCard: View {
    let task: MaintenanceTask
    let system: SystemModel

    var body: some View {
        let isRunning = system.running.contains(task.id)
        let result = system.results[task.id]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SymbolTile(symbol: task.symbol, color: Tide.ocean, size: 32)
                Text(task.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            Text(task.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                if task.needsAdmin {
                    Label("Asks for your password", systemImage: "lock.shield").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Run") { system.run(task) }.buttonStyle(TideButtonStyle(compact: true))
                }
            }
            if let result {
                Label(result.succeeded ? "Done" : result.output, systemImage: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(result.succeeded ? Tide.kelp : Tide.coral)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}
