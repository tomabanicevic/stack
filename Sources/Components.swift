import AppKit
import SwiftUI

extension GroupColor {
    var color: Color {
        switch self {
        case .indigo: return .indigo
        case .blue: return .blue
        case .teal: return .teal
        case .green: return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .red: return .red
        case .pink: return .pink
        case .purple: return .purple
        case .gray: return .gray
        }
    }
}

/// Colored rounded square with an SF Symbol — used for groups.
struct GroupBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color.gradient)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.35), radius: size * 0.08, y: size * 0.04)
    }
}

/// The real icon of an app (or a placeholder when it can't be found).
struct AppIconImage: View {
    let url: URL?
    var size: CGFloat = 32

    var body: some View {
        if let url {
            Image(nsImage: IconCache.shared.icon(for: url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: size * 0.78, height: size * 0.78)
                .frame(width: size, height: size)
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// Small capsule button used in the bubble.
struct PillButtonStyle: ButtonStyle {
    var foreground: Color = .white
    var fill: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(foreground)
            .background(Capsule().fill(fill.opacity(configuration.isPressed ? 0.28 : 0.14)))
            .contentShape(Capsule())
    }
}

/// Flat sidebar button with a selected state.
struct SidebarButtonStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(selected ? 0.22 : (configuration.isPressed ? 0.12 : 0)))
            )
            .contentShape(Rectangle())
    }
}

/// Popover to pick a group's icon and color.
struct GroupStylePicker: View {
    let binding: Binding<AppGroup>
    private var group: AppGroup { binding.wrappedValue }
    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 8), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Icon").font(.headline)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(AppGroup.symbols, id: \.self) { symbol in
                    Button {
                        binding.wrappedValue.symbol = symbol
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 34, height: 34)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(group.symbol == symbol ? group.color.color.opacity(0.28) : Color.primary.opacity(0.05))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Color").font(.headline)
            HStack(spacing: 7) {
                ForEach(GroupColor.allCases) { color in
                    Button {
                        binding.wrappedValue.color = color
                    } label: {
                        Circle()
                            .fill(color.color.gradient)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(group.color == color ? 0.9 : 0), lineWidth: 2))
                            .padding(1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(width: 236)
    }
}
