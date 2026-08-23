import SwiftUI
import AppKit

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

extension NSColor {
    convenience init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        let v = UInt64(h, radix: 16) ?? 0
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }
}

/// Tethr's "Glide" design language: a soft neutral canvas, floating cards with
/// generous corner radii, pill chips for filtering, and exactly one solid ink
/// call-to-action per screen.
enum Glide {
    private static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
    private static func dyn(_ light: String, _ dark: String) -> Color {
        dyn(NSColor(hex: light), NSColor(hex: dark))
    }

    /// Page background — never white, so cards read as floating above it.
    static let canvas = dyn("#EFEFF1", "#0F1014")
    static let surface = dyn("#FFFFFF", "#1A1C22")
    /// Recessed fill inside a card (search fields, dial keys, dropzones).
    static let surfaceAlt = dyn("#F2F2F5", "#23252C")
    static let ink = dyn("#101114", "#F6F6F8")
    static let inkSoft = dyn("#6C6D74", "#9C9EA6")
    static let inkFaint = dyn("#9C9DA4", "#6B6D75")
    static let hairline = dyn("#E5E5E9", "#2B2D35")
    /// Solid fill for the primary action and the selected nav pill.
    static let inkFill = dyn("#121317", "#F6F6F8")
    /// Text/glyphs drawn on top of `inkFill`.
    static let onInk = dyn("#FFFFFF", "#101114")

    static let cardShadow = dyn(NSColor(white: 0, alpha: 0.07), NSColor(white: 0, alpha: 0.45))
    static let liftShadow = dyn(NSColor(white: 0, alpha: 0.14), NSColor(white: 0, alpha: 0.55))
}

enum Radius {
    static let card: CGFloat = 24
    static let tile: CGFloat = 18
    static let thumb: CGFloat = 15
    static let control: CGFloat = 13
}

/// Palette from the Tethr design tokens.
enum Palette {
    static let green = Color(hex: "#1FA85A")
    static let red = Color(hex: "#E03131")
    static let orange = Color(hex: "#E8880C")
    static let purple = Color(hex: "#7A5AF8")
    static let teal = Color(hex: "#0EA5B7")
    static let pink = Color(hex: "#F43F6E")

    static let accentChoices: [(name: String, color: Color)] = [
        ("Ink", Color(hex: "#17181C")),
        ("Blue", Color(hex: "#2563EB")),
        ("Purple", Color(hex: "#7A5AF8")),
        ("Green", Color(hex: "#1FA85A")),
        ("Orange", Color(hex: "#E8880C")),
    ]

    static let avatarTints: [Color] = [
        Color(hex: "#E8880C"), Color(hex: "#1FA85A"), Color(hex: "#2563EB"),
        Color(hex: "#7A5AF8"), Color(hex: "#F43F6E"), Color(hex: "#0EA5B7"),
        Color(hex: "#D9822B"), Color(hex: "#3F6BD9"),
    ]
}

// MARK: - Surfaces

/// Floating white card — the workhorse container of the design.
struct Card<Content: View>: View {
    var padding: CGFloat = 0
    var radius: CGFloat = Radius.card
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Glide.surface)
                    .shadow(color: Glide.cardShadow, radius: 16, y: 7)
            }
    }
}

/// Section heading — bold sentence case, with an optional trailing link.
struct SectionCaption: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 15.5, weight: .bold))
            .kerning(-0.2)
            .foregroundStyle(Glide.ink)
    }
}

struct SectionHeading<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionCaption(text: text)
            Spacer()
            trailing
        }
    }
}

/// Underlined text link, as used beside section headings ("See all").
struct LinkText: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Glide.ink)
                .underline(hovering, pattern: .solid)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Sheet grabber handle.
struct Grabber: View {
    var body: some View {
        Capsule()
            .fill(Glide.hairline)
            .frame(width: 38, height: 5)
    }
}

// MARK: - Controls

/// Pill filter chip — solid ink when selected, outlined when not.
struct Chip: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Glide.onInk : Glide.ink)
                .padding(.horizontal, 17)
                .frame(height: 34)
                .background {
                    Capsule()
                        .fill(selected ? Glide.inkFill : Glide.surface)
                        .overlay {
                            if !selected {
                                Capsule().strokeBorder(hovering ? Glide.inkFaint : Glide.hairline, lineWidth: 1)
                            }
                        }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: selected)
    }
}

/// Horizontal chip row bound to a selection.
struct ChipBar<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(options, id: \.value) { option in
                    Chip(label: option.label, selected: selection == option.value) {
                        selection = option.value
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 2)
        }
    }
}

/// The one solid call-to-action per screen — a wide ink capsule.
struct InkButton: View {
    let label: String
    var symbol: String? = nil
    var fill: Color? = nil
    var height: CGFloat = 48
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 14.5, weight: .semibold))
            }
            .foregroundStyle(fill == nil ? Glide.onInk : Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            // Falls back to the app tint, which is the chosen accent. Callers
            // that pass an explicit fill (a red "End call") keep theirs.
            .background(fill.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint), in: Capsule())
            .shadow(color: Glide.cardShadow, radius: 10, y: 5)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.975))
    }
}

/// Circular icon button — white on the canvas, or ink-filled for emphasis.
struct CircleIconButton: View {
    let symbol: String
    var size: CGFloat = 38
    var filled = false
    var tint: Color? = nil
    var hint: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.36, weight: .medium))
                .foregroundStyle(filled ? Glide.onInk : (tint ?? Glide.ink))
                .frame(width: size, height: size)
                .background {
                    Circle()
                        .fill(filled ? Glide.inkFill : Glide.surface)
                        .shadow(color: Glide.cardShadow, radius: hovering ? 10 : 6, y: 3)
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .help(hint)
    }
}

/// Pill-shaped search field.
struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Glide.inkFaint)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Glide.ink)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Glide.inkFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 15)
        .frame(width: width, height: 38)
        .background {
            Capsule()
                .fill(Glide.surface)
                .shadow(color: Glide.cardShadow, radius: 8, y: 3)
        }
    }
}

// MARK: - Identity

/// Rounded-square media thumbnail — the list-row identity mark.
/// An Android app's own icon, mirrored from the phone. Falls back to the tinted
/// symbol badge while the icon is still in flight, or for a package whose icon
/// the phone cannot read.
struct AppIcon: View {
    @EnvironmentObject var pairing: PairingManager
    let pkg: String
    var symbol: String? = nil
    let tint: Color
    var size: CGFloat = 46
    var radius: CGFloat = Radius.thumb

    var body: some View {
        if let icon = pairing.appIcons[pkg] {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            Thumb(symbol: symbol, tint: tint, size: size, radius: radius)
        }
    }
}

struct Thumb: View {
    var initials: String = ""
    var symbol: String? = nil
    let tint: Color
    var size: CGFloat = 46
    var radius: CGFloat = Radius.thumb

    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.36, weight: .semibold))
            } else {
                Text(initials)
                    .font(.system(size: size * 0.34, weight: .bold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(
            LinearGradient(colors: [tint.opacity(0.92), tint], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: radius, style: .continuous)
        )
    }
}

struct Avatar: View {
    let initials: String
    let tint: Color
    var size: CGFloat = 44
    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.34, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [tint.opacity(0.92), tint], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: Circle()
            )
    }
}

// MARK: - Brand

/// The Tethr artwork, shipped as a package resource.
///
/// `Bundle.module` traps outright when its resource bundle is missing — which
/// it is if only the built binary was copied into Tethr.app — so the bundle is
/// located by hand and a missing mark degrades to a drawn glyph instead of
/// taking the app down on launch.
enum Brand {
    /// The full mark: white nodes on the ink tile, corners already rounded.
    static let logo: NSImage? = image(named: "TethrLogo")
    /// The nodes alone on transparency, for tinting.
    static let glyph: NSImage? = image(named: "TethrGlyph")

    /// The glyph at menu-bar size, as a template so it follows the menu bar's
    /// own light/dark appearance rather than staying stubbornly dark.
    static let menuBarGlyph: NSImage? = {
        guard let glyph else { return nil }
        let img = NSImage(size: NSSize(width: 17, height: 17), flipped: false) { rect in
            glyph.draw(in: rect)
            return true
        }
        img.isTemplate = true
        return img
    }()

    private static func image(named name: String) -> NSImage? {
        for bundle in bundles {
            if let url = bundle.url(forResource: name, withExtension: "png"),
               let img = NSImage(contentsOf: url) { return img }
        }
        return nil
    }

    /// Bundle.main covers resources dropped straight into Contents/Resources;
    /// the nested `.bundle` scan covers SwiftPM's Tethr_Tethr.bundle, which sits
    /// beside the binary under `swift run` and inside Contents/Resources once
    /// it has been copied into the .app.
    private static let bundles: [Bundle] = {
        var found = [Bundle.main]
        // Listed by path, not URL: under `swift run` the build directory is a
        // symlink, and a URL without the directory flag fails to enumerate it.
        let roots = [Bundle.main.resourceURL?.path, Bundle.main.bundleURL.path].compactMap { $0 }
        for root in roots {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            found += names
                .filter { $0.hasSuffix(".bundle") }
                .compactMap { Bundle(path: root + "/" + $0) }
        }
        return found
    }()
}

/// The Tethr mark — the app's identity in the sidebar, the welcome sheet, and
/// the menu bar. Distinct from `DeviceGlyph`, which stands for the *phone*.
struct BrandMark: View {
    var size: CGFloat = 38
    var corner: CGFloat = 12

    var body: some View {
        if let logo = Brand.logo {
            // The artwork's own corners are far tighter than the Glide radius,
            // so it is re-clipped to sit in the same family as the cards.
            Image(nsImage: logo)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        } else {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(Glide.onInk)
                .frame(width: size, height: size)
                .background(Glide.inkFill, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
    }
}

/// Dark phone-shaped device glyph used for the paired device.
struct DeviceGlyph: View {
    var size: CGFloat = 38
    var corner: CGFloat = 12
    var body: some View {
        Image(systemName: "iphone.gen3")
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(Glide.onInk)
            .frame(width: size, height: size)
            .background(Glide.inkFill, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
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

/// Small status pill — a dot plus a short label, on a white capsule.
struct StatusPill: View {
    let label: String
    var color: Color = Palette.green
    var body: some View {
        HStack(spacing: 6) {
            LiveDot(color: color, size: 6)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Glide.ink)
        }
        .padding(.horizontal, 13)
        .frame(height: 30)
        .background {
            Capsule()
                .fill(Glide.surface)
                .shadow(color: Glide.cardShadow, radius: 7, y: 3)
        }
    }
}

// MARK: - Behaviour

/// Plain button that shrinks and dims slightly while pressed — tactile feedback.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.94
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Rounded hover highlight for list rows (macOS pointer affordance).
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = Radius.tile
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(
                hovering ? AnyShapeStyle(Glide.surfaceAlt) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = Radius.tile) -> some View {
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
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Glide.inkSoft)
                .frame(width: 78, height: 78)
                .background {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(Glide.surface)
                        .shadow(color: Glide.cardShadow, radius: 16, y: 8)
                }
            Text(title)
                .font(.system(size: 19, weight: .bold))
                .kerning(-0.3)
                .foregroundStyle(Glide.ink)
                .padding(.top, 20)
            Text(caption)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(Glide.inkSoft)
                .multilineTextAlignment(.center)
                .padding(.top, 7)
            if let actionLabel, let action {
                InkButton(label: actionLabel, action: action)
                    .frame(width: 220)
                    .padding(.top, 22)
            }
        }
        .frame(maxWidth: 330)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}
