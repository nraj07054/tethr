import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Regenerates every derived Tethr icon from the two flat exports in this folder,
// writing them straight into the Mac and Android projects.
//
//   swift brand/make-icons.swift            # from the repo root
//
// The exports are a rounded tile on a flat page. Everything downstream is either
// that tile with its corners cut to transparency, or the bare glyph lifted off
// it onto transparency.

struct Bitmap {
    let w: Int, h: Int
    var px: [UInt8]          // RGBA8, premultiplied-last
    subscript(x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
        let i = (y * w + x) * 4
        return (Double(px[i]) / 255, Double(px[i + 1]) / 255, Double(px[i + 2]) / 255)
    }
    func luma(_ x: Int, _ y: Int) -> Double {
        let c = self[x, y]
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }
    /// A CGImage over a copy of the pixels, for drawing.
    func image() -> CGImage {
        var copy = px
        return copy.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h,
                      bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
    }
}

func load(_ path: String) -> Bitmap {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fatalError("cannot read \(path)")
    }
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    px.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return Bitmap(w: w, h: h, px: px)
}

func write(_ img: CGImage, to path: String) {
    let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                              UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil)
    guard CGImageDestinationFinalize(dst) else { fatalError("cannot write \(path)") }
    print("  \((path as NSString).lastPathComponent)  \(img.width)x\(img.height)")
}

func makeImage(w: Int, h: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    draw(ctx)
    return ctx.makeImage()!
}

/// Where the tile sits in an export, and how round its corners are. `isTileDark`
/// picks which way to threshold: the two exports are colour-inverted.
struct Tile {
    let x: Int, y: Int, w: Int, h: Int, radius: Int
}

func findTile(_ bmp: Bitmap, isTileDark: Bool) -> Tile {
    func isTile(_ x: Int, _ y: Int) -> Bool {
        isTileDark ? bmp.luma(x, y) < 0.5 : bmp.luma(x, y) > 0.85
    }
    var minX = bmp.w, minY = bmp.h, maxX = -1, maxY = -1
    for y in 0..<bmp.h {
        for x in 0..<bmp.w where isTile(x, y) {
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
    let w = maxX - minX + 1, h = maxY - minY + 1
    // On the tile's top row the flat run is the full width less one radius at
    // each end, which reads the corner directly rather than fitting a curve.
    var run = 0
    for x in minX...maxX where isTile(x, minY) { run += 1 }
    var radius = (w - run) / 2
    if radius <= 0 { radius = Int(Double(w) * 0.08) }
    return Tile(x: minX, y: minY, w: w, h: h, radius: radius)
}

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
let darkSrc = "\(root)/brand/tethr-mark-dark.png"    // dark tile on a white page
let lightSrc = "\(root)/brand/tethr-mark-light.png"  // white tile on a grey page
let androidRes = "\(root)/android/app/src/main/res"
let macApp = "\(root)/mac/Tethr.app/Contents/Resources"
let macRes = "\(root)/mac/Sources/Tethr/Resources"

func mkdir(_ path: String) {
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

let bmp = load(darkSrc)
let tile = findTile(bmp, isTileDark: true)
print("dark tile: \(tile.w)x\(tile.h) at (\(tile.x),\(tile.y)), radius \(tile.radius) " +
      "(\(String(format: "%.1f", Double(tile.radius) / Double(tile.w) * 100))%)")

// The export is a couple of percent wider than tall. Trim the flat sides in to
// square it — invisible, where stretching to square would not be.
let side = min(tile.w, tile.h)
let cropX = tile.x + (tile.w - side) / 2
let cropY = tile.y + (tile.h - side) / 2

let tint = bmp[tile.x + tile.w / 2, tile.y + tile.h / 10]   // top-centre, clear of the glyph
let tileColor = CGColor(red: tint.r, green: tint.g, blue: tint.b, alpha: 1)
let tileHex = String(format: "#%02X%02X%02X", Int(tint.r * 255), Int(tint.g * 255), Int(tint.b * 255))
print("tile colour: \(tileHex)")

/// True where a pixel of the *export* falls well inside the tile's silhouette.
/// The radius is deliberately overstated: the corner is a squircle, so a circle
/// fitted to it cuts inside the artwork and would leak page-white into the
/// glyph mask. The glyph starts ~19% down, so an oversized corner never bites.
func insideTile(_ x: Int, _ y: Int) -> Bool {
    let r = Double(tile.radius) * 2
    let fx = Double(x - tile.x), fy = Double(y - tile.y)
    let w = Double(tile.w), h = Double(tile.h)
    guard fx >= 0, fy >= 0, fx <= w, fy <= h else { return false }
    let cx = fx < r ? r : (fx > w - r ? w - r : fx)
    let cy = fy < r ? r : (fy > h - r ? h - r : fy)
    let dx = fx - cx, dy = fy - cy
    return dx * dx + dy * dy <= r * r
}

// ── Glyph on transparency ────────────────────────────────────────────────────
// Inside the tile the artwork is near-binary, so a narrow threshold band keeps
// the antialiased edges without dragging the tile colour along. The rounded
// corners expose the white page behind the tile — which reads exactly like the
// glyph — so they are masked out first.
var glyph = [UInt8](repeating: 0, count: side * side * 4)
var gMinX = side, gMinY = side, gMaxX = -1, gMaxY = -1
for y in 0..<side {
    for x in 0..<side {
        guard insideTile(cropX + x, cropY + y) else { continue }
        let a = min(max((bmp.luma(cropX + x, cropY + y) - 0.35) / 0.30, 0), 1)
        let v = UInt8(a * 255)
        let i = (y * side + x) * 4
        glyph[i] = v; glyph[i + 1] = v; glyph[i + 2] = v; glyph[i + 3] = v
        if a > 0.02 {
            if x < gMinX { gMinX = x }; if x > gMaxX { gMaxX = x }
            if y < gMinY { gMinY = y }; if y > gMaxY { gMaxY = y }
        }
    }
}
let glyphFull = glyph.withUnsafeMutableBytes { buf -> CGImage in
    CGContext(data: buf.baseAddress, width: side, height: side,
              bitsPerComponent: 8, bytesPerRow: side * 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
}
let gW = gMaxX - gMinX + 1, gH = gMaxY - gMinY + 1
let glyphTrimmed = glyphFull.cropping(to: CGRect(x: gMinX, y: gMinY, width: gW, height: gH))!
print("glyph: \(gW)x\(gH) — \(String(format: "%.0f", Double(gW) / Double(side) * 100))% of the tile")
guard gW < Int(Double(side) * 0.95), gW > Int(Double(side) * 0.4) else {
    fatalError("glyph bbox \(gW)x\(gH) of \(side) looks wrong — corner mask failed")
}

/// The glyph centred on a square canvas, optionally recoloured.
func glyphSquare(size: Int, inset: Double, color: CGColor?) -> CGImage {
    makeImage(w: size, h: size) { ctx in
        let box = Double(size) * (1 - inset * 2)
        let scale = box / Double(max(gW, gH))
        let dw = Double(gW) * scale, dh = Double(gH) * scale
        let rect = CGRect(x: (Double(size) - dw) / 2, y: (Double(size) - dh) / 2, width: dw, height: dh)
        guard let color else { return ctx.draw(glyphTrimmed, in: rect) }
        ctx.clip(to: rect, mask: glyphTrimmed)
        ctx.setFillColor(color)
        ctx.fill(rect)
    }
}

// ── The rounded tile, corners cut to transparency ────────────────────────────
func roundedTile(size: Int, source: CGImage, srcRect: CGRect, radiusFrac: Double) -> CGImage {
    makeImage(w: size, h: size) { ctx in
        let r = Double(size) * radiusFrac
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                           cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.clip()
        ctx.draw(source.cropping(to: srcRect)!, in: CGRect(x: 0, y: 0, width: size, height: size))
    }
}

// Likewise round the emitted tile a little harder than measured, so the clip
// eats into the artwork rather than leaving a sliver of page behind it.
let radiusFrac = Double(tile.radius) * 1.25 / Double(side)
let darkImg = bmp.image()
// CoreGraphics draws from the bottom-left; the scans above ran top-left.
let darkRect = CGRect(x: cropX, y: bmp.h - cropY - side, width: side, height: side)

let lightBmp = load(lightSrc)
let lightTile = findTile(lightBmp, isTileDark: false)
let lSide = min(lightTile.w, lightTile.h)
let lX = lightTile.x + (lightTile.w - lSide) / 2
let lY = lightTile.y + (lightTile.h - lSide) / 2
let lightImg = lightBmp.image()
let lightRect = CGRect(x: lX, y: lightBmp.h - lY - lSide, width: lSide, height: lSide)
print("light tile: \(lightTile.w)x\(lightTile.h), radius \(lightTile.radius)")

// ── Emit ─────────────────────────────────────────────────────────────────────
let densities = [("mdpi", 1), ("hdpi", 2), ("xhdpi", 2), ("xxhdpi", 3), ("xxxhdpi", 4)]
/// dp → px per bucket. hdpi is 1.5×, which the integer table above can't hold.
let scales: [String: Double] = ["mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4]
func px(_ dp: Double, _ bucket: String) -> Int { Int((dp * scales[bucket]!).rounded()) }

// Android launcher icon. On API 26+ the adaptive pair wins, and minSdk is 26,
// so the legacy PNGs are only there for tooling and the store listing.
print("android launcher:")
for (bucket, _) in densities {
    let dir = "\(androidRes)/mipmap-\(bucket)"
    mkdir(dir)
    write(roundedTile(size: px(48, bucket), source: darkImg, srcRect: darkRect, radiusFrac: radiusFrac),
          to: "\(dir)/ic_launcher.png")
    // Adaptive foregrounds are a 108dp canvas whose outer third the launcher
    // may crop, so the glyph is inset to stay inside the safe circle.
    write(glyphSquare(size: px(108, bucket), inset: 0.30, color: nil),
          to: "\(dir)/ic_launcher_foreground.png")
}

// Status-bar icons are drawn from alpha alone, so the white glyph is the shape.
print("android notification:")
for (bucket, _) in densities {
    let dir = "\(androidRes)/drawable-\(bucket)"
    mkdir(dir)
    write(glyphSquare(size: px(24, bucket), inset: 0.12, color: nil),
          to: "\(dir)/ic_tethr_notification.png")
}

print("android in-app:")
mkdir("\(androidRes)/drawable-nodpi")
write(roundedTile(size: 256, source: darkImg, srcRect: darkRect, radiusFrac: radiusFrac),
      to: "\(androidRes)/drawable-nodpi/tethr_logo.png")

print("macOS in-app:")
mkdir(macRes)
write(roundedTile(size: 512, source: darkImg, srcRect: darkRect, radiusFrac: radiusFrac),
      to: "\(macRes)/TethrLogo.png")
write(glyphSquare(size: 512, inset: 0, color: tileColor), to: "\(macRes)/TethrGlyph.png")

// macOS .icns: Apple's grid insets the rounded square inside a clear margin, and
// wants both the 1× and the @2× of every logical size.
print("macOS icon:")
let iconset = NSTemporaryDirectory() + "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
mkdir(iconset)
func macIcon(_ s: Int) -> CGImage {
    makeImage(w: s, h: s) { ctx in
        let inset = Double(s) * 0.095
        let box = Double(s) - inset * 2
        let t = roundedTile(size: max(Int(box.rounded()), 1), source: darkImg,
                            srcRect: darkRect, radiusFrac: radiusFrac)
        ctx.draw(t, in: CGRect(x: inset, y: inset, width: box, height: box))
    }
}
for logical in [16, 32, 128, 256, 512] {
    write(macIcon(logical), to: "\(iconset)/icon_\(logical)x\(logical).png")
    write(macIcon(logical * 2), to: "\(iconset)/icon_\(logical)x\(logical)@2x.png")
}
mkdir(macApp)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", "\(macApp)/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("  AppIcon.icns")

// The launcher background must match the ink the artwork is drawn on.
let colors = """
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- The ink the Tethr mark sits on, sampled from brand/tethr-mark-dark.png. -->
    <color name="tethr_mark">\(tileHex)</color>
</resources>

"""
try! colors.write(toFile: "\(androidRes)/values/colors.xml", atomically: true, encoding: .utf8)
print("  colors.xml — tethr_mark \(tileHex)")
