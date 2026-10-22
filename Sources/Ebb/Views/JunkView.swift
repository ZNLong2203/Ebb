import SwiftUI

struct JunkView: View {
    @Bindable var model: AppModel

    @ViewState private var filter: Safety?
    @ViewState private var search = ""
    @ViewState private var expanded: Set<String> = []
    @ViewState private var collapsed: Set<String> = []

    private var visibleGroups: [JunkGroup] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.groups.compactMap { group in
            let items = group.items.filter { item in
                (filter == nil || item.safety == filter)
                    && (query.isEmpty || item.title.lowercased().contains(query) || item.detail.lowercased().contains(query))
            }
            return items.isEmpty ? nil : JunkGroup(id: group.id, title: group.title, symbol: group.symbol, items: items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(visibleGroups) { group in
                        GroupCard(group: group, model: model,
                                  isCollapsed: collapsed.contains(group.id),
                                  expanded: $expanded) {
                            if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                        }
                    }
                    if visibleGroups.isEmpty {
                        ContentUnavailableView("Nothing here", systemImage: "water.waves",
                                               description: Text("No junk matches this filter."))
                            .padding(.top, 60)
                    }
                }
                .padding(24)
            }
            cleanBar
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Developer Junk").font(.rounded(28, .bold))
                    Text("Caches, build folders and leftovers, each with a plain-English explanation.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Select Suggested") { model.selectDefaults() }
                    Button("Select All Safe") {
                        model.selection.formUnion(model.allItems.filter { $0.safety == .safe }.map(\.id))
                    }
                    Divider()
                    Button("Select None") { model.selectNone() }
                } label: {
                    Label("Selection", systemImage: "checklist")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            HStack(spacing: 8) {
                FilterChip(title: "All", isOn: filter == nil) { filter = nil }
                ForEach(Safety.allCases, id: \.self) { safety in
                    FilterChip(title: safety.label, symbol: safety.symbol, tint: safety.color, isOn: filter == safety) {
                        filter = filter == safety ? nil : safety
                    }
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $search).textFieldStyle(.plain).frame(width: 160)
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

    private var cleanBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.selectedItems.count) selected").font(.headline)
                Text("Free space after cleaning: \(model.projectedFree.bytes)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.selectedBytes.bytes)
                .font(.rounded(26, .bold))
                .foregroundStyle(Tide.gradient)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.3), value: model.selectedBytes)
            Button { model.requestClean(model.selectedItems) } label: { Label("Clean…", systemImage: "sparkles") }
                .buttonStyle(TideButtonStyle())
                .disabled(model.selection.isEmpty || model.isScanning || model.cleaner.isWorking)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct GroupCard: View {
    let group: JunkGroup
    @Bindable var model: AppModel
    let isCollapsed: Bool
    @Binding var expanded: Set<String>
    let toggleCollapsed: () -> Void

    var body: some View {
        let ids = Set(group.items.map(\.id))
        let selectedCount = ids.intersection(model.selection).count
        let largest = max(group.items.map(\.size).max() ?? 1, 1)
        let color = Tide.color(forGroup: group.id)

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                RoundCheck(isOn: Binding(
                    get: { selectedCount == ids.count },
                    set: { on in if on { model.selection.formUnion(ids) } else { model.selection.subtract(ids) } }
                ), mixed: selectedCount > 0 && selectedCount < ids.count)
                SymbolTile(symbol: group.symbol, color: color, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.title).font(.headline)
                    Text("\(group.items.count) \(group.items.count == 1 ? "item" : "items") · \(selectedCount) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(group.total.bytes).font(.rounded(18, .bold)).monospacedDigit()
                Button(action: toggleCollapsed) {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(14)

            if !isCollapsed {
                Divider().padding(.leading, 14)
                VStack(spacing: 2) {
                    ForEach(group.items) { item in
                        JunkRow(item: item, model: model, fraction: CGFloat(item.size) / CGFloat(largest), color: color,
                                isExpanded: expanded.contains(item.id)) {
                            if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
                        }
                    }
                }
                .padding(6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background.secondary))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16)
                .fill(color)
                .frame(width: 4)
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isCollapsed)
    }
}

private struct JunkRow: View {
    let item: JunkItem
    @Bindable var model: AppModel
    let fraction: CGFloat
    let color: Color
    let isExpanded: Bool
    let toggleExpanded: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                RoundCheck(isOn: Binding(
                    get: { model.selection.contains(item.id) },
                    set: { on in if on { model.selection.insert(item.id) } else { model.selection.remove(item.id) } }
                ))
                JunkIcon(item: item, artifactKind: model.artifactKind(for: item), size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title).lineLimit(1)
                        if case .command = item.action {
                            Image(systemName: "terminal").font(.caption).foregroundStyle(.secondary)
                                .help("Cleaned with the tool's own command")
                        }
                    }
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                SafetyBadge(safety: item.safety)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(item.size.bytes).monospacedDigit().fontWeight(.medium)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary.opacity(0.5))
                            Capsule().fill(color.gradient).frame(width: max(4, geo.size.width * fraction))
                        }
                    }
                    .frame(width: 90, height: 5)
                }
                .frame(width: 96, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleExpanded)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.explanation).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Label(actionText, systemImage: actionSymbol)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if item.id == "docker", model.dockerInstalled {
                            Button { model.section = .docker } label: { Label("See What's Inside", systemImage: "ferry") }
                                .buttonStyle(GlassButtonStyle())
                        } else if let path = item.revealPath {
                            Button { model.reveal(path) } label: { Label("Show in Finder", systemImage: "folder") }
                                .buttonStyle(GlassButtonStyle())
                        }
                        Button { model.requestClean([item]) } label: { Label("Clean This", systemImage: "sparkles") }
                            .buttonStyle(TideButtonStyle(compact: true))
                            .disabled(model.isScanning || model.cleaner.isWorking)
                    }
                }
                .padding(.leading, 84)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(hovering || isExpanded ? Color.secondary.opacity(0.07) : .clear))
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isExpanded)
    }

    private var actionText: String {
        switch item.action {
        case .trash: "Goes to the Trash, so you can put it back."
        case .command(let command): "Runs `\(command)`. Can't be undone."
        case .emptyTrash: "Empties the Trash permanently."
        case .launchAgent: "Stops it, then moves it to the Trash so you can put it back."
        }
    }

    private var actionSymbol: String {
        switch item.action {
        case .trash: "arrow.uturn.backward.circle"
        case .command: "terminal"
        case .emptyTrash: "trash"
        case .launchAgent: "power"
        }
    }
}
