import SwiftUI

/// Identical files, with only the space that deleting them would really free.
struct DuplicatesView: View {
    @Bindable var model: AppModel

    var body: some View {
        let duplicates = model.duplicates
        VStack(spacing: 0) {
            header
            switch duplicates.state {
            case .idle:
                start.frame(maxHeight: .infinity)
            case .searching(let done, let total):
                VStack(spacing: 14) {
                    ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                        .progressViewStyle(.linear)
                        .tint(Tide.lagoon)
                        .frame(width: 340)
                    Text(total > 0 ? "Comparing \(done) of \(total) same-size files…" : "Grouping files by size…")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxHeight: .infinity)
            case .ready(let groups):
                if groups.isEmpty {
                    ContentUnavailableView("No duplicates", systemImage: "checkmark.seal",
                                           description: Text("Every file of 1 MB or more in \(model.scanRootDisplay) is unique."))
                        .frame(maxHeight: .infinity)
                } else {
                    results(groups)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Duplicates").font(.rounded(28, .bold))
                Text("Identical files in your folders. Copies that are APFS clones already share storage, so Ebb counts only the space you'd really get back.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if case .ready = model.duplicates.state {
                Button { model.duplicates.search(model.result?.duplicateCandidates ?? []) } label: {
                    Label("Search Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(GlassButtonStyle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    private var start: some View {
        let count = model.result?.duplicateCandidates.count ?? 0
        return VStack(spacing: 16) {
            SymbolTile(symbol: "doc.on.doc.fill", color: Tide.sand, size: 64)
            Text("Find duplicate files").font(.rounded(22, .bold))
            Text("Ebb compares \(count.formatted()) files of 1 MB or more in \(model.scanRootDisplay): first by size, then by content. App data, build folders and app bundles are left out, because removing a \"duplicate\" there can break things.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Button { model.duplicates.search(model.result?.duplicateCandidates ?? []) } label: {
                Label("Find Duplicates", systemImage: "magnifyingglass")
            }
            .buttonStyle(TideButtonStyle())
            .disabled(count == 0)
        }
        .padding(40)
    }

    private func results(_ groups: [DuplicateGroup]) -> some View {
        let duplicates = model.duplicates
        let items = duplicates.items()
        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        SummaryTile(symbol: "doc.on.doc.fill", color: Tide.sand, title: "Duplicate sets",
                                    value: "\(groups.count)", caption: "\(groups.reduce(0) { $0 + $1.files.count }) files")
                        SummaryTile(symbol: "arrow.down.circle.fill", color: Tide.kelp, title: "You can free",
                                    value: groups.reduce(0) { $0 + $1.reclaimable }.bytes, caption: "keeping one copy of each")
                        SummaryTile(symbol: "link", color: Tide.lavender, title: "Already shared (clones)",
                                    value: "\(groups.filter(\.isAllClones).count)", caption: "deleting these frees nothing")
                    }
                    HStack {
                        FilterChip(title: "Keep oldest, select the rest", symbol: "wand.and.stars", isOn: false) { duplicates.selectSuggested() }
                        FilterChip(title: "Clear selection", isOn: false) { duplicates.selection = [] }
                        Spacer()
                    }
                    ForEach(groups) { group in
                        DuplicateGroupCard(group: group, model: model)
                    }
                }
                .padding(24)
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(items.count) selected").font(.headline)
                    Text("Every set keeps at least one copy. Removed copies go to the Trash.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(items.reduce(0) { $0 + $1.size }.bytes).font(.rounded(26, .bold)).foregroundStyle(Tide.gradient)
                Button { model.requestClean(items) } label: { Label("Move to Trash…", systemImage: "trash") }
                    .buttonStyle(TideButtonStyle())
                    .disabled(items.isEmpty || model.cleaner.isWorking)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

private struct DuplicateGroupCard: View {
    let group: DuplicateGroup
    @Bindable var model: AppModel

    var body: some View {
        let duplicates = model.duplicates
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(nsImage: IconCache.icon(forFile: group.files[0].path)).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.files[0].name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Text("\(group.files.count) copies · \(group.size.bytes) each").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if group.isAllClones {
                    Label("Clones share storage", systemImage: "link").font(.caption.weight(.semibold)).foregroundStyle(Tide.lavender)
                } else {
                    Text("frees \(group.reclaimable.bytes)").font(.callout.weight(.semibold)).foregroundStyle(Tide.kelp)
                }
            }
            ForEach(group.files) { file in
                let selected = duplicates.selection.contains(file.path)
                let keptCount = group.files.filter { !duplicates.selection.contains($0.path) }.count
                HStack(spacing: 10) {
                    RoundCheck(isOn: Binding(
                        get: { selected },
                        set: { on in
                            // Never let the last remaining copy be selected.
                            if on, keptCount > 1 { duplicates.selection.insert(file.path) }
                            if !on { duplicates.selection.remove(file.path) }
                        }))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.folder).font(.callout).lineLimit(1).truncationMode(.middle)
                        Text("Modified \(file.modified.formatted(date: .abbreviated, time: .omitted))\(file.privateSize == 0 ? " · shares storage with another copy" : "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !selected {
                        Text("Keep").font(.caption.weight(.semibold)).foregroundStyle(Tide.kelp)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(Tide.kelp.opacity(0.12)))
                    }
                    Button { duplicates.keepOnly(file, in: group) } label: { Text("Keep only this") }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    Button { model.reveal(file.path) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                }
                .padding(.leading, 4)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}
