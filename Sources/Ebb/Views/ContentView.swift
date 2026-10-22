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
        .frame(minWidth: 960, minHeight: 640)
        .animation(.easeInOut(duration: 0.35), value: model.phase)
    }
}

// MARK: - Welcome

/// The beach: deep water fading to sand, with the two steps that matter.
struct WelcomeView: View {
    let model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Tide.seaBackground.ignoresSafeArea()
            BeachWaves().frame(height: 150)
            VStack(spacing: 22) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
                VStack(spacing: 8) {
                    Text("Ebb").font(.rounded(52, .bold))
                    Text("See what's filling your Mac, and let the clutter wash away.")
                        .font(.title3)
                        .opacity(0.8)
                }
                .foregroundStyle(.white)
                steps
                Text("Nothing leaves your Mac. Cleaned items go to the Trash first, so you can always put them back.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 150)
            .frame(maxHeight: .infinity)
        }
        .environment(\.colorScheme, .dark)
        // Notice the moment the user flips the switch in System Settings.
        .task {
            while !Task.isCancelled {
                model.refreshPermissions()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private var steps: some View {
        VStack(spacing: 0) {
            StepRow(number: 1, done: model.hasFullDiskAccess,
                    title: model.hasFullDiskAccess ? "Full Disk Access is on" : "Allow Full Disk Access",
                    detail: model.hasFullDiskAccess
                        ? "Ebb can see every folder, so nothing is left out."
                        : "Recommended. Without it Ebb skips Desktop, Documents, Downloads and other apps' data, so macOS won't pester you with prompts.") {
                if !model.hasFullDiskAccess {
                    VStack(alignment: .trailing, spacing: 6) {
                        Button("Open Settings") { Permissions.openFullDiskAccessSettings() }
                            .buttonStyle(GlassButtonStyle(onDark: true))
                        Button("Reopen Ebb") { model.relaunch() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            Divider().overlay(.white.opacity(0.12)).padding(.leading, 56)
            StepRow(number: 2, done: false, title: "Scan your Mac",
                    detail: "Takes a few seconds. Ebb only reads; nothing changes until you say so.") {
                VStack(alignment: .trailing, spacing: 6) {
                    Button { model.scan(root: NSHomeDirectory()) } label: {
                        Label("Scan Home", systemImage: "water.waves")
                    }
                    .buttonStyle(TideButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    Button("or choose a folder…") { model.chooseFolder() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(6)
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.15)))
    }
}

private struct StepRow<Trailing: View>: View {
    let number: Int
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(done ? AnyShapeStyle(Tide.kelp) : AnyShapeStyle(Tide.gradient))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
                } else {
                    Text("\(number)").font(.rounded(15, .bold))
                }
            }
            .frame(width: 32, height: 32)
            .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(14)
    }
}

/// Layered waves breaking onto sand along the bottom of the sea screens.
struct BeachWaves: View {
    var body: some View {
        WaveView(layers: [
            .init(color: NSColor(Tide.lagoon).withAlphaComponent(0.35), amplitude: 14, wavelength: 420, period: 9, crest: 0.78),
            .init(color: NSColor(Tide.foam).withAlphaComponent(0.45), amplitude: 11, wavelength: 300, period: -7, crest: 0.6),
            .init(color: NSColor.white.withAlphaComponent(0.55), amplitude: 8, wavelength: 520, period: 14, crest: 0.36),
            .init(color: NSColor(Tide.sand), amplitude: 8, wavelength: 520, period: 14, crest: 0.32),
        ])
        .allowsHitTesting(false)
    }
}

// MARK: - Scanning

struct ScanningView: View {
    let model: AppModel

    /// Rises with the amount measured on a log scale, so it keeps moving on any disk size.
    private var level: Double {
        let gigabytes = Double(model.progress.bytes) / 1e9
        return min(0.95, log10(gigabytes + 1) / log10(400))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Tide.seaBackground.ignoresSafeArea()
            BeachWaves().frame(height: 110)
            VStack(spacing: 22) {
                TideGauge(fraction: level, title: model.progress.bytes.bytes,
                          subtitle: "\(model.progress.files.formatted()) files")
                VStack(spacing: 6) {
                    Text(model.progress.stage == "Scanning" ? "Reading \(model.scanRootDisplay)…" : "\(model.progress.stage)…")
                        .font(.rounded(22))
                    Text((model.progress.currentPath as NSString).abbreviatingWithTildeInPath)
                        .font(.caption.monospaced())
                        .opacity(0.6)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 520)
                }
                .foregroundStyle(.white)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if context.date.timeIntervalSince(model.lastProgressChange) > 4 {
                        Label("This is taking a while. If macOS shows a permission dialog, answer it to continue.",
                              systemImage: "hand.raised.fill")
                            .font(.callout)
                            .foregroundStyle(Tide.sand)
                            .frame(maxWidth: 460)
                    }
                }
                Button("Cancel") { model.cancelScan() }
                    .buttonStyle(GlassButtonStyle(onDark: true))
            }
            .padding(.bottom, 110)
            .frame(maxHeight: .infinity)
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Main window

private struct MainView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.section) {
                SidebarItem(section: .overview, title: "Overview", symbol: "sparkles", color: Tide.ocean, badge: nil)
                SidebarItem(section: .junk, title: "Developer Junk", symbol: "wand.and.stars", color: Tide.lagoon,
                            badge: model.allItems.reduce(0) { $0 + $1.size }.bytes)
                if model.dockerInstalled {
                    SidebarItem(section: .docker, title: "Docker", symbol: "ferry.fill", color: Tide.ocean,
                                badge: model.docker.snapshot.map { ($0.imagesSize + $0.containersSize + $0.volumesSize + $0.buildCacheSize).bytes })
                }
                SidebarItem(section: .apps, title: "Applications", symbol: "square.grid.2x2.fill", color: Tide.lavender,
                            badge: model.apps.apps.isEmpty ? nil : "\(model.apps.apps.count)")
                SidebarItem(section: .duplicates, title: "Duplicates", symbol: "doc.on.doc.fill", color: Color(red: 0.80, green: 0.62, blue: 0.30),
                            badge: model.duplicates.groups.isEmpty ? nil : model.duplicates.groups.reduce(0) { $0 + $1.reclaimable }.bytes)
                SidebarItem(section: .largeFiles, title: "Large Files", symbol: "doc.text.magnifyingglass", color: Tide.coral,
                            badge: "\(model.result?.largeFiles.count ?? 0)")
                SidebarItem(section: .diskMap, title: "Disk Map", symbol: "square.grid.3x3.square", color: Tide.ocean, badge: nil)
                SidebarItem(section: .system, title: "Startup & Maintenance", symbol: "gearshape.2.fill", color: Tide.slate,
                            badge: { let broken = model.system.items.filter(\.isBroken).count; return broken > 0 ? "\(broken) broken" : nil }())
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top) { brand }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 4) {
                    TrashBar(model: model)
                    DiskMiniGauge(disk: model.disk)
                }
                .animation(.spring(response: 0.4), value: model.cleaner.trashedBytes)
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 260)
        } detail: {
            ZStack {
                TideBackdrop()
                Group {
                    switch model.section ?? .overview {
                    case .overview: OverviewView(model: model)
                    case .junk: JunkView(model: model)
                    case .docker: DockerView(model: model)
                    case .apps: AppsView(model: model)
                    case .duplicates: DuplicatesView(model: model)
                    case .system: SystemView(model: model)
                    case .largeFiles: LargeFilesView(model: model)
                    case .diskMap: DiskMapView(model: model)
                    }
                }
                .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.2), value: model.section)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    Text("\(model.progress.stage)… \(model.progress.files.formatted()) files")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Button { model.chooseFolder() } label: { Label("Scan Folder…", systemImage: "folder") }
                        .help("Scan a different folder")
                    Button { model.scan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                        .help("Rescan \(model.scanRootDisplay)")
                }
            }
        }
        .navigationTitle("")
        .sheet(item: $model.cleanFlow) { flow in
            CleanFlowSheet(flow: flow, model: model)
        }
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text("Ebb").font(.rounded(18, .bold))
                Text(model.scanRootDisplay).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}

private struct SidebarItem: View {
    let section: AppModel.Section
    let title: String
    let symbol: String
    let color: Color
    let badge: String?

    var body: some View {
        NavigationLink(value: section) {
            HStack(spacing: 10) {
                SymbolTile(symbol: symbol, color: color, size: 24)
                Text(title)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
        }
    }
}
