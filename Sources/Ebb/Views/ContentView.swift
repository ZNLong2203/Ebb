import SwiftUI

struct ContentView: View {
    let model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .welcome:
                WelcomeView(model: model)
            case .scanning where model.result == nil:
                ScanningView(model: model)
            default:
                MainView(model: model)
            }
        }
        .frame(minWidth: 920, minHeight: 620)
    }
}

private struct MainView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.section) {
                NavigationLink(value: AppModel.Section.overview) {
                    Label("Overview", systemImage: "gauge.with.dots.needle.33percent")
                }
                NavigationLink(value: AppModel.Section.junk) {
                    Label("Developer Junk", systemImage: "sparkles")
                        .badge(Text(model.allItems.reduce(0) { $0 + $1.size }.bytes))
                }
                NavigationLink(value: AppModel.Section.largeFiles) {
                    Label("Large Files", systemImage: "doc.text.magnifyingglass")
                        .badge(model.result?.largeFiles.count ?? 0)
                }
                NavigationLink(value: AppModel.Section.diskMap) {
                    Label("Disk Map", systemImage: "square.grid.3x3.square")
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
            .safeAreaInset(edge: .bottom) { TrashBar(model: model) }
        } detail: {
            switch model.section ?? .overview {
            case .overview: OverviewView(model: model)
            case .junk: JunkView(model: model)
            case .largeFiles: LargeFilesView(model: model)
            case .diskMap: DiskMapView(model: model)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    Text("Scanning… \(model.progress.files.formatted()) files")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Button { model.chooseFolder() } label: { Label("Scan Folder…", systemImage: "folder") }
                    Button { model.scan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                        .help("Rescan \(model.scanRootDisplay)")
                }
            }
        }
        .navigationTitle("Ebb")
        .navigationSubtitle(model.scanRootDisplay)
    }
}

struct WelcomeView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
            VStack(spacing: 8) {
                Text("Ebb").font(.system(size: 40, weight: .bold, design: .rounded))
                Text("See what's filling your Mac, and clear what you don't need.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { model.scan(root: NSHomeDirectory()) } label: {
                    Label("Scan Home Folder", systemImage: "magnifyingglass").padding(.horizontal, 10).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Button("Choose Folder…") { model.chooseFolder() }
                    .controlSize(.large)
            }
            FullDiskAccessNote(model: model)
                .frame(maxWidth: 520)
            Text("Nothing leaves your Mac, and Ebb never deletes anything directly: cleaned items go to the Trash so you can put them back.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Notice the moment the user flips the switch in System Settings.
        .task {
            while !Task.isCancelled {
                model.refreshPermissions()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
}

struct FullDiskAccessNote: View {
    let model: AppModel

    var body: some View {
        if model.hasFullDiskAccess {
            Label("Full Disk Access is on", systemImage: "checkmark.shield.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
        } else {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield").foregroundStyle(.orange).font(.title2)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recommended: give Ebb Full Disk Access").font(.callout.weight(.semibold))
                    Text("Without it, Ebb skips Desktop, Documents, Downloads, iCloud Drive and other apps' data, so macOS doesn't interrupt you with a permission dialog for each one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Open Privacy Settings, switch Ebb on, then reopen Ebb.")
                        .font(.caption.weight(.medium))
                    HStack {
                        Button("Open Privacy Settings") { Permissions.openFullDiskAccessSettings() }
                        Button("Reopen Ebb") { model.relaunch() }
                    }
                    .controlSize(.small)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.1)))
        }
    }
}

struct ScanningView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text(model.progress.stage == "Scanning" ? "Scanning \(model.scanRootDisplay)…" : "\(model.progress.stage)…")
                .font(.title2.weight(.semibold))
            HStack(spacing: 24) {
                VStack {
                    Text(model.progress.files.formatted()).font(.title.weight(.bold).monospacedDigit())
                    Text("files").font(.caption).foregroundStyle(.secondary)
                }
                VStack {
                    Text(model.progress.bytes.bytes).font(.title.weight(.bold).monospacedDigit())
                    Text("measured").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text((model.progress.currentPath as NSString).abbreviatingWithTildeInPath)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 520)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if context.date.timeIntervalSince(model.lastProgressChange) > 4 {
                    Label("This is taking a while. If macOS shows a permission dialog, answer it to continue.",
                          systemImage: "hand.raised.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: 460)
                }
            }
            Button("Cancel") { model.cancelScan() }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
