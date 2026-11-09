import AppKit
import Foundation

// Vector-drawn artwork keeps the app mark crisp at every icon size.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let assets = resources.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
let iconset = resources.appendingPathComponent("RemotePad.iconset")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let mint = NSColor(srgbRed: 0.64, green: 0.96, blue: 0.77, alpha: 1)

func draw(size: Int, mac: Bool) -> Data {
    let cg = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: mac ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
    let context = NSGraphicsContext(cgContext: cg, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let transform = AffineTransform(scale: CGFloat(size) / 1024)
    (transform as NSAffineTransform).concat()
    let inset: CGFloat = mac ? 64 : 0
    let rect = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let background = NSBezierPath(roundedRect: rect, xRadius: mac ? 200 : 0, yRadius: mac ? 200 : 0)
    NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.19, blue: 0.18, alpha: 1),
               ending: NSColor(srgbRed: 0.035, green: 0.055, blue: 0.065, alpha: 1))!.draw(in: background, angle: -80)
    let pad = NSBezierPath(roundedRect: CGRect(x: 195, y: 228, width: 634, height: 554), xRadius: 100, yRadius: 100)
    NSColor(srgbRed: 0.17, green: 0.25, blue: 0.23, alpha: 1).setFill()
    pad.fill()
    mint.withAlphaComponent(0.7).setStroke()
    pad.lineWidth = 15
    pad.stroke()
    let separator = NSBezierPath()
    separator.move(to: CGPoint(x: 220, y: 360)); separator.line(to: CGPoint(x: 804, y: 360))
    mint.withAlphaComponent(0.22).setStroke(); separator.lineWidth = 7; separator.stroke()
    let cursor = NSBezierPath()
    cursor.move(to: CGPoint(x: 395, y: 700))
    for point in [CGPoint(x: 395, y: 395), CGPoint(x: 477, y: 474), CGPoint(x: 551, y: 329),
                  CGPoint(x: 613, y: 361), CGPoint(x: 537, y: 503), CGPoint(x: 652, y: 510)] {
        cursor.line(to: point)
    }
    cursor.close()
    NSColor(srgbRed: 0.025, green: 0.06, blue: 0.05, alpha: 1).setStroke()
    cursor.lineJoinStyle = .round; cursor.lineWidth = 24; cursor.stroke()
    NSColor.white.setFill(); cursor.fill()
    mint.setFill()
    NSBezierPath(ovalIn: CGRect(x: 700, y: 675, width: 42, height: 42)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return NSBitmapImageRep(cgImage: cg.makeImage()!).representation(using: .png, properties: [:])!
}
try draw(size: 1024, mac: false).write(to: assets.appendingPathComponent("RemotePad.png"))
try draw(size: 1024, mac: false).write(to: resources.appendingPathComponent("RemotePad-Icon.png"))
let contents = #"{"images":[{"filename":"RemotePad.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}"#
try contents.write(to: assets.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try #"{"info":{"author":"xcode","version":1}}"#.write(to: resources.appendingPathComponent("Assets.xcassets/Contents.json"), atomically: true, encoding: .utf8)
for size in [16, 32, 128, 256, 512] {
    try draw(size: size, mac: true).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(size: size * 2, mac: true).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
print("Generated iOS app icon and macOS iconset.")
