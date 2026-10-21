import SwiftUI

/// Shows exactly what will happen before anything is touched.
struct ConfirmCleanSheet: View {
    let items: [JunkItem]
    let model: AppModel

    var body: some View {
        let trashItems = items.filter { $0.action.isUndoable }
        let commands = items.filter { if case .command = $0.action { true } else { false } }
        let total = items.reduce(0) { $0 + $1.size }

        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                SymbolTile(symbol: "wand.and.stars", color: Tide.lagoon, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean \(items.count) \(items.count == 1 ? "item" : "items")").font(.rounded(22, .bold))
                    Text("About \(total.bytes) will be cleared").foregroundStyle(.secondary)
                }
                Spacer()
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(items) { item in
                        HStack(spacing: 10) {
                            JunkIcon(item: item, artifactKind: model.artifactKind(for: item), size: 24)
                            Text(item.title).lineLimit(1)
                            Spacer()
                            SafetyBadge(safety: item.safety)
                            Text(item.size.bytes).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 76, alignment: .trailing)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 260)

            if !trashItems.isEmpty {
                Callout(symbol: "arrow.uturn.backward.circle.fill", color: Tide.kelp,
                        text: "\(trashItems.count) go to the Trash. You can put them back until you empty it.")
            }
            if !commands.isEmpty {
                Callout(symbol: "terminal.fill", color: .orange,
                        text: "\(commands.count) are cleaned with the tool's own command, which can't be undone: "
                            + commands.compactMap { if case .command(let c) = $0.action { c } else { nil } }.joined(separator: " · "))
            }

            HStack {
                Spacer()
                Button("Cancel") { model.pendingClean = nil }
                    .buttonStyle(GlassButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button { model.confirmPendingClean() } label: { Label("Clean \(total.bytes)", systemImage: "sparkles") }
                    .buttonStyle(TideButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 580)
    }
}

private struct Callout: View {
    let symbol: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).font(.title3)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.1)))
    }
}

/// After a cleanup: a moment of delight, then the one thing left to do (empty the Trash).
struct CelebrationSheet: View {
    let report: Cleaner.Report
    let model: AppModel

    @ViewState private var bubbling = false
    @ViewState private var emptyError: String?
    @ViewState private var emptied = false

    var body: some View {
        ZStack {
            Tide.seaBackground
            BubblesView(isActive: bubbling).allowsHitTesting(false)
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(.white.opacity(0.12)).frame(width: 96, height: 96)
                    Image(systemName: report.failures.isEmpty ? "checkmark" : "exclamationmark")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)
                }
                .scaleEffect(bubbling ? 1 : 0.6)
                .animation(.spring(response: 0.5, dampingFraction: 0.55), value: bubbling)

                Text(headline).font(.rounded(30, .bold)).foregroundStyle(.white).multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

                details

                HStack(spacing: 10) {
                    if report.movedToTrash > 0 && !emptied {
                        Button { Task { await empty() } } label: { Label("Empty Trash Now", systemImage: "trash") }
                            .buttonStyle(TideButtonStyle())
                    }
                    Button("Done") { model.cleanReport = nil }
                        .buttonStyle(GlassButtonStyle(onDark: true))
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            }
            .padding(30)
        }
        .frame(width: 500, height: 460)
        .environment(\.colorScheme, .dark)
        .onAppear { bubbling = true }
    }

    private var headline: String {
        if emptied { return "\(report.movedToTrash.bytes) freed" }
        if report.movedToTrash > 0 { return "\(report.movedToTrash.bytes) cleared" }
        return report.failures.isEmpty ? "All clean" : "Done, with a few hiccups"
    }

    private var subtitle: String {
        if emptied { return "Your Mac has room to breathe again." }
        if report.movedToTrash > 0 { return "It's in the Trash for now. Empty it to turn it into free space, or undo from the sidebar." }
        return "The tools' own cleanup commands have finished."
    }

    @ViewBuilder private var details: some View {
        if !report.commands.isEmpty || !report.failures.isEmpty || emptyError != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(report.commands) { run in
                        DisclosureGroup {
                            Text(run.output.isEmpty ? "(no output)" : run.output)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            Label(run.command, systemImage: run.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.caption.monospaced())
                                .foregroundStyle(run.succeeded ? Tide.foam : Tide.coral)
                        }
                    }
                    ForEach(report.failures, id: \.self) { Text($0).font(.caption).foregroundStyle(Tide.coral) }
                    if let emptyError { Text(emptyError).font(.caption).foregroundStyle(Tide.coral) }
                }
                .padding(10)
            }
            .frame(maxHeight: 110)
            .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.2)))
            .foregroundStyle(.white)
        }
    }

    private func empty() async {
        emptyError = await model.emptyTrash()
        if emptyError == nil {
            emptied = true
            bubbling = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { bubbling = true }
        }
    }
}
