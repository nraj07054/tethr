import SwiftUI

extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        let v = UInt64(h, radix: 16) ?? 0
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

/// Palette from the Dogen design tokens.
enum Palette {
    static let green = Color(hex: "#34C759")
    static let red = Color(hex: "#FF3B30")
    static let orange = Color(hex: "#FF9F0A")
    static let purple = Color(hex: "#AF52DE")
    static let teal = Color(hex: "#5AC8FA")
    static let pink = Color(hex: "#FF375F")

    static let accentChoices: [(name: String, color: Color)] = [
        ("Blue", Color(hex: "#0A84FF")),
        ("Purple", Color(hex: "#AF52DE")),
        ("Pink", Color(hex: "#FF375F")),
        ("Green", Color(hex: "#34C759")),
        ("Orange", Color(hex: "#FF9500")),
    ]

    static let avatarTints: [Color] = [
        Color(hex: "#FF9500"), Color(hex: "#34C759"), Color(hex: "#0A84FF"),
        Color(hex: "#AF52DE"), Color(hex: "#FF375F"), Color(hex: "#5AC8FA"),
        Color(hex: "#FF9F0A"), Color(hex: "#30B0C7"),
    ]
}

/// "SECTION" caption style used across screens.
struct SectionCaption: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(.secondary)
    }
}

/// Card container matching the design's translucent cards.
struct Card<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
            )
    }
}

struct Avatar: View {
    let initials: String
    let tint: Color
    var size: CGFloat = 44
    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint, in: Circle())
    }
}

/// Dark phone-shaped device glyph used for the paired device.
struct DeviceGlyph: View {
    var size: CGFloat = 34
    var corner: CGFloat = 9
    var body: some View {
        Image(systemName: "smartphone")
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [Color(hex: "#3A3A42"), Color(hex: "#17171B")],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: corner, style: .continuous)
            )
    }
}

/// Plain button that shrinks and dims slightly while pressed — tactile feedback.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.94
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Rounded hover highlight for list rows (macOS pointer affordance).
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 10
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(
                hovering ? AnyShapeStyle(.quaternary.opacity(0.45)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 10) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }
}

/// Friendly centered empty state, with an optional call-to-action button.
struct EmptyState: View {
    let symbol: String
    let title: String
    let caption: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(caption)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionLabel, let action {
                Button(action: action) {
                    Text(actionLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .frame(height: 34)
                        .background(.tint, in: Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.96))
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: 300)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

struct LiveDot: View {
    var color: Color = Palette.green
    var size: CGFloat = 6
    @State private var dim = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}
