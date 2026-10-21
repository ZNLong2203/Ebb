import SwiftUI

struct JunkView: View {
    @Bindable var model: AppModel

    @ViewState private var confirming: [JunkItem]?
    @ViewState private var report: CleanReportBox?

    var body: some View {
        List {
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.items) { item in
                        JunkRow(item: item, isOn: Binding(
                            get: { model.selection.contains(item.id) },
                            set: { on in
                                if on { model.selection.insert(item.id) } else { model.selection.remove(item.id) }
                            }
                        ), model: model)
                    }
                } header: {
                    HStack {
                        Label(group.title, systemImage: group.symbol)
                        Spacer()
                        Text(group.total.bytes).monospacedDigit()
                    }
                    .font(.headline)
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .bottom) { cleanBar }
        .toolbar {
            ToolbarItemGroup {
                Button("Select Suggested") { model.selectDefaults() }
                Button("Select None") { model.selectNone() }
            }
        }
        .sheet(isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            if let items = confirming {
                ConfirmCleanSheet(items: items) {
                    confirming = nil
                    Task { report = CleanReportBox(report: await model.clean(items)) }
                } onCancel: { confirming = nil }
            }
        }
        .sheet(item: $report) { box in
            CleanReportSheet(report: box.report, model: model) { report = nil }
        }
    }

    private var cleanBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.selectedItems.count) selected").font(.headline)
                Text("Safe items are pre-selected. Projects you touched this week never are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.selectedBytes.bytes)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(Tide.gradient)
            Button("Clean…") { confirming = model.selectedItems }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.selection.isEmpty || model.isScanning || model.cleaner.isWorking)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

private struct JunkRow: View {
    let item: JunkItem
    @Binding var isOn: Bool
    let model: AppModel

    @ViewState private var showInfo = false

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $isOn).toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if case .command = item.action {
                Image(systemName: "terminal").foregroundStyle(.secondary).help("Cleaned with the tool's own command")
            }
            SafetyBadge(safety: item.safety)
            Text(item.size.bytes)
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .popover(isPresented: $showInfo, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.title).font(.headline)
                        Text(item.explanation).fixedSize(horizontal: false, vertical: true)
                        Text(actionText).font(.callout).foregroundStyle(.secondary)
                        if let path = item.revealPath {
                            Button("Show in Finder") { model.reveal(path) }
                        }
                    }
                    .padding(16)
                    .frame(width: 320)
                }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
    }

    private var actionText: String {
        switch item.action {
        case .trash: "Cleaning moves it to the Trash, so you can put it back."
        case .command(let command): "Cleaning runs `\(command)`. This can't be undone."
        case .emptyTrash: "Cleaning empties the Trash permanently."
        }
    }
}

/// `Cleaner.Report` wrapped so it can drive `.sheet(item:)`.
struct CleanReportBox: Identifiable {
    let id = UUID()
    let report: Cleaner.Report
}

private struct ConfirmCleanSheet: View {
    let items: [JunkItem]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let commands = items.filter { if case .command = $0.action { true } else { false } }
        VStack(alignment: .leading, spacing: 14) {
            Text("Clean \(items.count) items?").font(.title2.weight(.bold))
            Text("\(items.reduce(0) { $0 + $1.size }.bytes) selected. Folders go to the Trash; you can put them back until you empty it.")
                .foregroundStyle(.secondary)
            List(items) { item in
                HStack {
                    SafetyBadge(safety: item.safety)
                    Text(item.title).lineLimit(1)
                    Spacer()
                    Text(item.size.bytes).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 180, maxHeight: 280)
            if !commands.isEmpty {
                Label {
                    Text("\(commands.count) item(s) are cleaned by running the tool's own command, which can't be undone: ")
                        + Text(commands.compactMap { if case .command(let c) = $0.action { c } else { nil } }.joined(separator: ", ")).font(.callout.monospaced())
                } icon: {
                    Image(systemName: "terminal").foregroundStyle(.orange)
                }
                .font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Clean", action: onConfirm).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}

private struct CleanReportSheet: View {
    let report: Cleaner.Report
    let model: AppModel
    let onDone: () -> Void

    @ViewState private var emptyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(report.failures.isEmpty ? "Done" : "Done, with some problems",
                  systemImage: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(report.failures.isEmpty ? .green : .orange)
            if report.movedToTrash > 0 {
                Text("Moved \(report.movedToTrash.bytes) to the Trash. Empty the Trash to turn it into free space, or use Undo All in the sidebar to put everything back.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(report.commands) { run in
                DisclosureGroup {
                    ScrollView {
                        Text(run.output.isEmpty ? "(no output)" : run.output)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 140)
                } label: {
                    Label(run.command, systemImage: run.succeeded ? "checkmark" : "xmark")
                        .font(.callout.monospaced())
                        .foregroundStyle(run.succeeded ? Color.primary : Color.red)
                }
            }
            ForEach(report.failures, id: \.self) { failure in
                Text(failure).font(.caption).foregroundStyle(.red)
            }
            if let emptyError { Text(emptyError).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                if report.movedToTrash > 0 {
                    Button("Empty Trash Now") {
                        Task {
                            emptyError = await model.emptyTrash()
                            if emptyError == nil { onDone() }
                        }
                    }
                }
                Button("Done", action: onDone).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}
