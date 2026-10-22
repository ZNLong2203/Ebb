import SwiftUI

/// The macOS 27 SDK turns `@State` into a macro whose plugin only ships with Xcode.
/// Spelling the property wrapper through an alias keeps Command Line Tools builds working.
typealias ViewState<Value> = SwiftUI.State<Value>

extension Safety {
    var color: Color {
        switch self {
        case .safe: Tide.kelp
        case .review: .orange
        case .careful: Tide.coral
        }
    }

    var symbol: String {
        switch self {
        case .safe: "checkmark.shield.fill"
        case .review: "eye.fill"
        case .careful: "exclamationmark.triangle.fill"
        }
    }

    var blurb: String {
        switch self {
        case .safe: "Rebuilds itself"
        case .review: "Worth a look"
        case .careful: "May hold your data"
        }
    }
}

struct SafetyBadge: View {
    let safety: Safety

    var body: some View {
        Label(safety.label, systemImage: safety.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(safety.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(safety.color.opacity(0.14)))
            .fixedSize()
            .help(safety.blurb)
    }
}

// MARK: - Item icons

/// Finder icons are slow to look up, and rows redraw while scrolling.
@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(forFile path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }
}

/// The real app icon when the item belongs to an app, otherwise a tinted symbol for the tool.
struct JunkIcon: View {
    let item: JunkItem
    let artifactKind: ProjectArtifact.Kind?
    var size: CGFloat = 32

    var body: some View {
        if let app = Self.appPath(for: item) {
            Image(nsImage: IconCache.icon(forFile: app))
                .resizable()
                .frame(width: size + 4, height: size + 4)
                .padding(-2)
        } else {
            let look = Self.look(for: item, kind: artifactKind)
            SymbolTile(symbol: look.symbol, color: look.color, size: size)
        }
    }

    private static func appPath(for item: JunkItem) -> String? {
        let fm = FileManager.default
        if item.id.hasPrefix("editor:") {
            let names = ["Cursor": "Cursor", "Code": "Visual Studio Code", "Code - Insiders": "Visual Studio Code - Insiders",
                         "Windsurf": "Windsurf", "VSCodium": "VSCodium"]
            guard let name = names[String(item.id.dropFirst("editor:".count))] else { return nil }
            return ["/Applications/\(name).app", NSHomeDirectory() + "/Applications/\(name).app"].first(where: fm.fileExists)
        }
        if item.id.hasPrefix("cache:/") {
            let bundleID = (item.id as NSString).lastPathComponent
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
        }
        if item.id == "docker", fm.fileExists(atPath: "/Applications/Docker.app") { return "/Applications/Docker.app" }
        // Uninstalls show the app's own icon; duplicates show the file's.
        if item.id.hasPrefix("app:") { return String(item.id.dropFirst("app:".count)) }
        if item.id.hasPrefix("duplicate:") { return String(item.id.dropFirst("duplicate:".count)) }
        return nil
    }

    private static func look(for item: JunkItem, kind: ProjectArtifact.Kind?) -> (symbol: String, color: Color) {
        if let kind {
            switch kind {
            case .nodeModules: return ("shippingbox.fill", Tide.kelp)
            case .rustTarget: return ("gearshape.2.fill", .orange)
            case .swiftBuild: return ("swift", .orange)
            case .cocoaPods: return ("circle.hexagongrid.fill", Tide.coral)
            case .pythonVenv: return ("cube.fill", Tide.ocean)
            case .nextCache: return ("n.square.fill", Tide.slate)
            case .gradleProject: return ("gearshape.fill", Tide.lagoon)
            }
        }
        let id = item.id.split(separator: ":").first.map(String.init) ?? item.id
        switch id {
        case "npm": return ("shippingbox.fill", Color(red: 0.80, green: 0.22, blue: 0.22))
        case "yarn": return ("shippingbox.fill", Color(red: 0.17, green: 0.53, blue: 0.75))
        case "pnpm": return ("shippingbox.fill", .orange)
        case "bun": return ("takeoutbag.and.cup.and.straw.fill", Color(red: 0.75, green: 0.62, blue: 0.48))
        case "pip": return ("cube.fill", Color(red: 0.22, green: 0.46, blue: 0.69))
        case "uv": return ("bolt.fill", Tide.lavender)
        case "conda": return ("leaf.fill", Tide.kelp)
        case "homebrew": return ("mug.fill", .orange)
        case "gradle": return ("gearshape.fill", Tide.lagoon)
        case "cargo": return ("shippingbox.circle.fill", .orange)
        case "cocoapods": return ("circle.hexagongrid.fill", Tide.coral)
        case "huggingface": return ("face.smiling.inverse", Color(red: 0.95, green: 0.72, blue: 0.15))
        case "go": return ("hare.fill", Tide.lagoon)
        case "docker": return ("ferry.fill", Tide.ocean)
        case "docker-image": return ("square.stack.3d.up.fill", Tide.ocean)
        case "docker-container": return ("shippingbox.fill", Tide.lagoon)
        case "docker-volume": return ("cylinder.split.1x2.fill", Tide.coral)
        case "docker-buildcache": return ("hammer.fill", Tide.sand)
        case "orphan": return ("puzzlepiece.extension.fill", Tide.coral)
        case "agent": return ("power", Tide.lavender)
        case "deriveddata": return ("hammer.fill", Tide.ocean)
        case "simcaches", "simulators": return ("iphone", Tide.lavender)
        case "devicesupport": return ("cable.connector", Tide.lavender)
        case "archives": return ("archivebox.fill", Tide.slate)
        case "jetbrains": return ("hammer.circle.fill", Color(red: 0.55, green: 0.30, blue: 0.85))
        case "logs": return ("doc.text.fill", Tide.slate)
        case "iosbackups": return ("iphone.and.arrow.forward", Tide.coral)
        case "trash": return ("trash.fill", Tide.slate)
        default: return ("internaldrive.fill", Tide.sand)
        }
    }
}

// MARK: - Sidebar pieces

/// Free space at a glance, at the bottom of the sidebar.
struct DiskMiniGauge: View {
    let disk: DiskInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "internaldrive.fill").foregroundStyle(Tide.lagoon)
                Text("Macintosh HD").font(.caption.weight(.semibold))
                Spacer()
                Text("\(disk.free.bytes) free").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Tide.gradient)
                        .frame(width: geo.size.width * CGFloat(disk.used) / CGFloat(max(disk.total, 1)))
                }
            }
            .frame(height: 6)
        }
        .padding(12)
    }
}

/// Shows where Ebb's trashed files are and offers undo / empty, because trashed bytes aren't free yet.
struct TrashBar: View {
    let model: AppModel

    @ViewState private var confirmEmpty = false
    @ViewState private var message: String?

    var body: some View {
        let bytes = model.cleaner.trashedBytes
        if bytes > 0 {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SymbolTile(symbol: "trash.fill", color: .orange, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(bytes.bytes) in the Trash").font(.callout.weight(.semibold))
                        Text("Empty it to get the space").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Button("Undo All") { message = failureText(model.undoAll()) }
                        .buttonStyle(GlassButtonStyle())
                    Button("Empty Trash") { confirmEmpty = true }
                        .buttonStyle(TideButtonStyle(compact: true))
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.orange.opacity(0.1)))
            .padding(.horizontal, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .confirmationDialog("Empty the Trash?", isPresented: $confirmEmpty) {
                Button("Empty Trash", role: .destructive) {
                    Task { message = await model.emptyTrash() }
                }
            } message: {
                Text("Everything in the Trash is deleted permanently, including items you put there yourself.")
            }
        }
    }

    private func failureText(_ names: [String]) -> String? {
        names.isEmpty ? nil : "Couldn't restore: \(names.joined(separator: ", "))"
    }
}
