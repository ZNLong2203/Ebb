import QuickLookThumbnailing
import SwiftUI

struct LargeFilesView: View {
    let model: AppModel

    enum Age: Int, CaseIterable, Identifiable {
        case any = 0, threeMonths = 90, sixMonths = 180, year = 365
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .any: "Any age"
            case .threeMonths: "3+ months"
            case .sixMonths: "6+ months"
            case .year: "1+ year"
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case size = "Largest first", oldest = "Oldest first", name = "Name"
        var id: String { rawValue }
    }

    @ViewState private var selection = Set<String>()
    // Decimal units, to match how ByteCountFormatter (and Finder) print sizes.
    @ViewState private var minSize: Int64 = 100_000_000
    @ViewState private var age: Age = .any
    @ViewState private var sort: Sort = .size
    @ViewState private var confirmTrash = false
    @ViewState private var failures: [String] = []

    private var files: [LargeFile] {
        let cutoff = Date().addingTimeInterval(-Double(age.rawValue) * 86_400)
        let filtered = (model.result?.largeFiles ?? []).filter { $0.size >= minSize && (age == .any || $0.modified < cutoff) }
        switch sort {
        case .size: return filtered.sorted { $0.size > $1.size }
        case .oldest: return filtered.sorted { $0.modified < $1.modified }
        case .name: return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private var selectedFiles: [LargeFile] { files.filter { selection.contains($0.id) } }

    var body: some View {
        let files = files
        let largest = max(files.map(\.size).max() ?? 1, 1)
        VStack(spacing: 0) {
            header(count: files.count, total: files.reduce(0) { $0 + $1.size })
            if files.isEmpty {
                ContentUnavailableView("No large files here", systemImage: "doc.text.magnifyingglass",
                                       description: Text("Try a smaller size or any age."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(files) { file in
                            LargeFileRow(file: file, fraction: CGFloat(file.size) / CGFloat(largest),
                                         protection: model.protection(for: file.path),
                                         isSelected: Binding(
                                            get: { selection.contains(file.id) },
                                            set: { on in if on { selection.insert(file.id) } else { selection.remove(file.id) } }),
                                         model: model)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
            bottomBar
        }
        .confirmationDialog("Move \(selectedFiles.count) file(s) to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) {
                let targets = selectedFiles
                selection = []
                Task { failures = await model.trash(paths: targets.map(\.path), sizes: targets.map(\.size)) }
            }
        } message: {
            Text("\(selectedFiles.reduce(0) { $0 + $1.size }.bytes). You can put them back from the Trash until you empty it.")
        }
    }

    private func header(count: Int, total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Large Files").font(.rounded(28, .bold))
                    Text("\(count) files · \(total.bytes). Big files you haven't touched in months are usually the easiest wins.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            HStack(spacing: 8) {
                Text("Size").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach([Int64(100_000_000), 500_000_000, 1_000_000_000, 5_000_000_000], id: \.self) { size in
                    FilterChip(title: "≥ \(size.bytes)", isOn: minSize == size) { minSize = size }
                }
                Divider().frame(height: 18).padding(.horizontal, 6)
                Text("Untouched").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Age.allCases) { option in
                    FilterChip(title: option.label, tint: Tide.coral, isOn: age == option) { age = option }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 6)
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            if !failures.isEmpty {
                Label("Couldn't move: \(failures.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).lineLimit(1)
            } else {
                Text(selectedFiles.isEmpty ? "Select files to move them to the Trash" : "\(selectedFiles.count) selected")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !selectedFiles.isEmpty {
                Text(selectedFiles.reduce(0) { $0 + $1.size }.bytes).font(.rounded(22, .bold)).foregroundStyle(Tide.gradient)
            }
            Button { confirmTrash = true } label: { Label("Move to Trash…", systemImage: "trash") }
                .buttonStyle(TideButtonStyle())
                .disabled(selectedFiles.isEmpty || model.isScanning)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct LargeFileRow: View {
    let file: LargeFile
    let fraction: CGFloat
    let protection: String?
    @Binding var isSelected: Bool
    let model: AppModel

    @ViewState private var hovering = false
    @ViewState private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            if protection == nil {
                RoundCheck(isOn: $isSelected)
            } else {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 20).help(protection ?? "")
            }
            Image(nsImage: thumbnail ?? IconCache.icon(forFile: file.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                Text(((file.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            AgeBadge(date: file.modified)
            VStack(alignment: .trailing, spacing: 4) {
                Text(file.size.bytes).monospacedDigit().fontWeight(.medium)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary.opacity(0.5))
                        Capsule().fill(Tide.gradient).frame(width: max(4, geo.size.width * fraction))
                    }
                }
                .frame(width: 90, height: 5)
            }
            .frame(width: 96, alignment: .trailing)
            HStack(spacing: 2) {
                Button { Self.quickLook(file.path) } label: { Image(systemName: "eye") }
                    .help("Quick Look")
                Button { model.reveal(file.path) } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isSelected ? Tide.lagoon.opacity(0.12) : (hovering ? Color.secondary.opacity(0.07) : .clear)))
        .contentShape(Rectangle())
        .onTapGesture { if protection == nil { isSelected.toggle() } }
        .onHover { hovering = $0 }
        .task(id: file.path) { thumbnail = await Self.thumbnail(for: file.path) }
    }

    private static func thumbnail(for path: String) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 40, height: 40),
                                                   scale: 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }

    private static func quickLook(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

/// How long a file has sat untouched, coloured from fresh to forgotten.
private struct AgeBadge: View {
    let date: Date

    var body: some View {
        let days = Date().timeIntervalSince(date) / 86_400
        let color: Color = days > 365 ? Tide.coral : days > 180 ? .orange : days > 90 ? Tide.sand : .secondary
        Text(date, format: .relative(presentation: .named))
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
            .fixedSize()
    }
}
