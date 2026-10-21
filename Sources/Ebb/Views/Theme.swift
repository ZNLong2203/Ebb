import SwiftUI

/// Ebb's palette: from deep water to the sand the tide leaves behind.
enum Tide {
    static let abyss = Color(red: 0.03, green: 0.13, blue: 0.32)
    static let deep = Color(red: 0.05, green: 0.24, blue: 0.52)
    static let ocean = Color(red: 0.07, green: 0.40, blue: 0.76)
    static let lagoon = Color(red: 0.12, green: 0.70, blue: 0.78)
    static let foam = Color(red: 0.44, green: 0.88, blue: 0.85)
    static let sand = Color(red: 0.95, green: 0.79, blue: 0.53)
    static let coral = Color(red: 0.95, green: 0.47, blue: 0.36)
    static let kelp = Color(red: 0.25, green: 0.70, blue: 0.50)
    static let lavender = Color(red: 0.55, green: 0.49, blue: 0.94)
    static let slate = Color(red: 0.40, green: 0.46, blue: 0.55)

    static let gradient = LinearGradient(colors: [ocean, lagoon], startPoint: .leading, endPoint: .trailing)
    static let seaBackground = LinearGradient(colors: [abyss, deep, ocean], startPoint: .top, endPoint: .bottom)

    /// One colour per junk group, shared by the donut, group cards and badges.
    static func color(forGroup id: String) -> Color {
        switch id {
        case "packages": lagoon
        case "projects": kelp
        case "editors": coral
        case "docker": ocean
        case "xcode": lavender
        case "caches": sand
        default: slate
        }
    }
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

/// Big rounded numbers read friendlier than the default SF digits.
extension Font {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Buttons

/// The primary call to action: an ocean-gradient capsule that glows a little on hover.
struct TideButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        TideButtonBody(configuration: configuration, compact: compact, isEnabled: isEnabled)
    }

    private struct TideButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let compact: Bool
        let isEnabled: Bool
        @ViewState private var hovering = false

        var body: some View {
            configuration.label
                .font(compact ? .callout.weight(.semibold) : .rounded(15))
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? 14 : 22)
                .padding(.vertical, compact ? 7 : 11)
                .background(
                    Capsule().fill(isEnabled ? AnyShapeStyle(Tide.gradient) : AnyShapeStyle(Color.gray.opacity(0.45)))
                )
                .overlay(Capsule().strokeBorder(.white.opacity(hovering ? 0.35 : 0.15)))
                .shadow(color: Tide.lagoon.opacity(isEnabled && hovering ? 0.55 : 0.25), radius: hovering ? 14 : 8, y: 4)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// Quiet secondary button: translucent capsule.
struct GlassButtonStyle: ButtonStyle {
    var onDark = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(onDark ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(onDark ? AnyShapeStyle(.white.opacity(configuration.isPressed ? 0.25 : 0.14))
                                              : AnyShapeStyle(.quaternary.opacity(configuration.isPressed ? 1 : 0.7))))
            .overlay(Capsule().strokeBorder(onDark ? .white.opacity(0.2) : .clear))
    }
}

// MARK: - Surfaces

/// A soft card used across every screen.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator.opacity(0.5)))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }
}

/// Faint tide wash behind the detail views, so the app doesn't feel like a plain grey form.
struct TideBackdrop: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            RadialGradient(colors: [Tide.lagoon.opacity(0.10), .clear], center: .topTrailing, startRadius: 20, endRadius: 520)
            RadialGradient(colors: [Tide.sand.opacity(0.08), .clear], center: .bottomLeading, startRadius: 20, endRadius: 480)
        }
        .ignoresSafeArea()
    }
}

/// A gradient tile holding an SF Symbol, used as the icon for groups and tools.
struct SymbolTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white))
            .shadow(color: color.opacity(0.3), radius: 3, y: 1)
    }
}

/// A selectable pill used for filters.
struct FilterChip: View {
    let title: String
    var symbol: String?
    var tint: Color = Tide.ocean
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(isOn ? .white : .primary)
            .background(Capsule().fill(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary.opacity(0.6))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

/// Round checkbox that matches the tide palette better than the stock square one.
struct RoundCheck: View {
    @Binding var isOn: Bool
    var mixed = false

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack {
                Circle().strokeBorder(isOn || mixed ? Color.clear : Color.secondary.opacity(0.5), lineWidth: 1.5)
                if isOn || mixed {
                    Circle().fill(Tide.gradient)
                    Image(systemName: mixed ? "minus" : "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 20, height: 20)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isOn)
    }
}
