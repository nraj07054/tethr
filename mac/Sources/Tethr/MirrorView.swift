import SwiftUI

/// Phone Mirroring — status of the live stream plus a jump to its window.
struct MirrorView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Phone Mirroring",
                         subtitle: "See and control your phone right here") {
                if pairing.mirrorFrame != nil {
                    StatusPill(label: "Live · \(pairing.deviceName ?? "Phone")")
                }
            }
            if pairing.mirrorFrame != nil {
                EmptyState(symbol: "macwindow.on.rectangle",
                           title: "Mirroring in Its Own Window",
                           caption: "Your phone's screen is showing in a separate, phone-shaped window. Click and drag on it to control your phone.",
                           actionLabel: "Bring Window to Front") {
                    openWindow(id: "mirror")
                }
            } else if pairing.isConnected {
                EmptyState(symbol: "rectangle.on.rectangle",
                           title: "Ready to Mirror",
                           caption: "Open Tethr on your \(pairing.deviceName ?? "phone") and tap “Mirror Screen”, then allow screen capture.")
            } else if state.contentAvailable {
                EmptyState(symbol: "rectangle.on.rectangle",
                           title: "Phone Not Connected",
                           caption: "Open the Tethr app on your phone to reconnect, then tap “Mirror Screen”.")
            } else {
                PairPrompt(symbol: "rectangle.on.rectangle",
                           title: "Mirror Your Phone",
                           caption: "Scan the QR code with your phone to see and control its screen right here.")
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: pairing.mirrorFrame == nil)
    }
}

/// Standalone, phone-shaped window that shows the live screen and forwards
/// clicks/drags to the phone as taps and swipes.
struct MirrorWindow: View {
    @EnvironmentObject var pairing: PairingManager
    @Environment(\.dismiss) private var dismiss
    // Distinguishes a tap from a swipe (points, in the displayed image space).
    private let tapSlop: CGFloat = 6

    var body: some View {
        ZStack(alignment: .bottom) {
            content
            navBar
                .padding(.bottom, 14)
        }
        .background(Color.black)
        .frame(minWidth: 240, minHeight: 480)
        // Mirroring ending — stopped on the phone, or the link dropping — must
        // take this window with it. Leaving a frozen last frame on screen reads
        // as a live mirror that has hung. The window owns its own dismissal
        // because it is the one thing guaranteed to exist while it is open.
        .onChange(of: pairing.mirrorFrame == nil) { _, stopped in
            if stopped { dismiss() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let frame = pairing.mirrorFrame {
            GeometryReader { geo in
                let rect = fittedRect(image: frame.size, in: geo.size)
                Image(nsImage: frame)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                handle(start: value.startLocation, end: value.location, in: rect)
                            }
                    )
            }
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Waiting for your phone's screen…")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Floating dark pill of hardware keys, hovering over the stream.
    private var navBar: some View {
        HStack(spacing: 6) {
            navButton("chevron.left", "back") { pairing.pressKey("back") }
            navButton("circle", "home") { pairing.pressKey("home") }
            navButton("square.on.square", "recents") { pairing.pressKey("recents") }
        }
        .padding(6)
        .background {
            Capsule()
                .fill(Color(hex: "#141519").opacity(0.92))
                .overlay(Capsule().strokeBorder(.white.opacity(0.09), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
        }
    }

    private func navButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 44, height: 38)
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .help(help)
    }

    /// The rect the aspect-fit image actually occupies inside `box` (letterboxed).
    private func fittedRect(image: CGSize, in box: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(box.width / image.width, box.height / image.height)
        let w = image.width * scale, h = image.height * scale
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    private func norm(_ p: CGPoint, in rect: CGRect) -> CGPoint? {
        guard rect.width > 0, rect.height > 0, rect.contains(p) else { return nil }
        return CGPoint(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height)
    }

    private func handle(start: CGPoint, end: CGPoint, in rect: CGRect) {
        guard let s = norm(start, in: rect) else { return }
        let dist = hypot(end.x - start.x, end.y - start.y)
        if dist <= tapSlop {
            pairing.tap(x: s.x, y: s.y)
        } else if let e = norm(end, in: rect) {
            pairing.swipe(x1: s.x, y1: s.y, x2: e.x, y2: e.y, ms: 180)
        }
    }
}

/// Live phone screen streamed from the device, in a bezel.
struct LiveMirrorFrame: View {
    let image: NSImage

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .fill(Color(hex: "#0A0A0C"))
                .shadow(color: .black.opacity(0.4), radius: 30, y: 20)
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                .padding(11)
        }
        .aspectRatio(
            (image.size.width + 22) / max(image.size.height + 22, 1),
            contentMode: .fit
        )
    }
}
