import SwiftUI

/// The macOS 27 SDK turns `@State` into a macro whose plugin only ships with Xcode.
/// Spelling the property wrapper through an alias keeps Command Line Tools builds working.
typealias ViewState<Value> = SwiftUI.State<Value>

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension Safety {
    var color: Color {
        switch self {
        case .safe: .green
        case .review: .orange
        case .careful: .red
        }
    }

    var symbol: String {
        switch self {
        case .safe: "checkmark.shield.fill"
        case .review: "eye.fill"
        case .careful: "exclamationmark.triangle.fill"
        }
    }
}

struct SafetyBadge: View {
    let safety: Safety

    var body: some View {
        Label(safety.label, systemImage: safety.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(safety.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(safety.color.opacity(0.14)))
            .fixedSize()
    }
}

/// Rounded panel used throughout the overview.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

/// The ebb-tide gradient shared by the icon, hero numbers and disk bar.
enum Tide {
    static let deep = Color(red: 0.05, green: 0.33, blue: 0.62)
    static let shallow = Color(red: 0.17, green: 0.74, blue: 0.84)
    static let sand = Color(red: 0.96, green: 0.78, blue: 0.55)
    static let gradient = LinearGradient(colors: [deep, shallow], startPoint: .leading, endPoint: .trailing)
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
                Label("\(bytes.bytes) in the Trash", systemImage: "trash.fill")
                    .font(.callout.weight(.semibold))
                Text("Empty the Trash to turn it into free space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Undo All") { message = failureText(model.undoAll()) }
                    Button("Empty Trash…") { confirmEmpty = true }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
                if let message {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.12)))
            .padding(10)
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
