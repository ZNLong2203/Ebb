import SwiftUI

struct LargeFilesView: View {
    let model: AppModel

    enum Age: Int, CaseIterable, Identifiable {
        case any = 0, threeMonths = 90, sixMonths = 180, year = 365
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .any: "Any time"
            case .threeMonths: "Over 3 months ago"
            case .sixMonths: "Over 6 months ago"
            case .year: "Over a year ago"
            }
        }
    }

    @ViewState private var selection = Set<LargeFile.ID>()
    @ViewState private var minSize: Int64 = 100 << 20
    @ViewState private var age: Age = .any
    @ViewState private var sortOrder = [KeyPathComparator(\LargeFile.size, order: .reverse)]
    @ViewState private var confirmTrash = false
    @ViewState private var failures: [String] = []

    private var files: [LargeFile] {
        let cutoff = Date().addingTimeInterval(-Double(age.rawValue) * 86_400)
        return (model.result?.largeFiles ?? [])
            .filter { $0.size >= minSize && (age == .any || $0.modified < cutoff) }
            .sorted(using: sortOrder)
    }

    private var selectedFiles: [LargeFile] { files.filter { selection.contains($0.id) } }
    private var blocked: [LargeFile] { selectedFiles.filter { model.protection(for: $0.path) != nil } }

    var body: some View {
        VStack(spacing: 0) {
            Table(files, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { file in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 18, height: 18)
                        Text(file.name).lineLimit(1)
                        if let reason = model.protection(for: file.path) {
                            Image(systemName: "lock.fill").foregroundStyle(.secondary).help(reason)
                        }
                    }
                }
                TableColumn("Size", value: \.size) { Text($0.size.bytes).monospacedDigit() }
                    .width(min: 70, ideal: 90)
                TableColumn("Modified", value: \.modified) { Text($0.modified, format: .relative(presentation: .named)) }
                    .width(min: 100, ideal: 130)
                TableColumn("Location") { file in
                    Text(((file.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .contextMenu(forSelectionType: LargeFile.ID.self) { ids in
                Button("Show in Finder") { ids.first.map(model.reveal) }
            } primaryAction: { ids in
                ids.first.map(model.reveal)
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

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Picker("At least", selection: $minSize) {
                Text("100 MB").tag(Int64(100 << 20))
                Text("500 MB").tag(Int64(500 << 20))
                Text("1 GB").tag(Int64(1 << 30))
                Text("5 GB").tag(Int64(5 << 30))
            }
            .fixedSize()
            Picker("Modified", selection: $age) {
                ForEach(Age.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
            Spacer()
            if !failures.isEmpty {
                Text("Couldn't move: \(failures.joined(separator: ", "))").font(.caption).foregroundStyle(.red).lineLimit(1)
            } else if let reason = blocked.first.flatMap({ model.protection(for: $0.path) }) {
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("\(files.count) files · \(files.reduce(0) { $0 + $1.size }.bytes)")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Button("Show in Finder") { selectedFiles.first.map { model.reveal($0.path) } }
                .disabled(selectedFiles.isEmpty)
            Button("Move to Trash…") { confirmTrash = true }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFiles.isEmpty || !blocked.isEmpty || model.isScanning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
