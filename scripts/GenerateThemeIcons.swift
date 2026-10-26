// Reproducible, vector-drawn app icons, one per app theme. Run with: swift scripts/GenerateThemeIcons.swift
// Graphite (the default theme) fills the primary AppIcon set, with its tinted variant; the other themes become
// alternate icons that the app switches to when that theme is chosen.
import AppKit

struct IconColors {
    let background, sheet, backSheet, bar, ink, lines, dot: UInt
}
// Icon colors follow each theme; on dark themes the page is lifted above the background so it stays visible.
let themes: [(name: String, colors: IconColors)] = [
    ("Graphite", IconColors(background: 0x0D0E0F, sheet: 0x26282B, backSheet: 0x1A1B1D, bar: 0x8DB4DE, ink: 0xECEDEE, lines: 0x5A5E64, dot: 0x8DB4DE)),
    ("Light", IconColors(background: 0xF2F2F7, sheet: 0xFFFFFF, backSheet: 0xD1D1D6, bar: 0x007AFF, ink: 0x1C1C1E, lines: 0xAEAEB2, dot: 0x007AFF)),
    ("Dark", IconColors(background: 0x000000, sheet: 0x2C2C2E, backSheet: 0x1C1C1E, bar: 0x0A84FF, ink: 0xFFFFFF, lines: 0x636366, dot: 0x0A84FF)),
    ("Midnight", IconColors(background: 0x0A0F1C, sheet: 0x1C2740, backSheet: 0x141C2E, bar: 0x64D2FF, ink: 0xE8EDF7, lines: 0x4A5876, dot: 0x64D2FF)),
    ("Forest", IconColors(background: 0x0E1411, sheet: 0x213029, backSheet: 0x18211C, bar: 0x30D158, ink: 0xE6EEE8, lines: 0x4D6356, dot: 0x30D158)),
    ("Studio", IconColors(background: 0xF2F2F0, sheet: 0xFFFDF8, backSheet: 0xDCD8CE, bar: 0xC24D2B, ink: 0x292B2E, lines: 0xB5A797, dot: 0xC24D2B))
]
let tinted = IconColors(background: 0x252525, sheet: 0xEEEEEE, backSheet: 0x999999, bar: 0x777777, ink: 0x444444, lines: 0xAAAAAA, dot: 0x777777)

func color(_ hex: UInt) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func drawIcon(_ c: IconColors, to path: String) throws {
    let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    color(c.background).setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
    // A pair of offset sheets reads as a small stack of calendar pages.
    color(c.backSheet).setFill()
    NSBezierPath(roundedRect: NSRect(x: 172, y: 170, width: 666, height: 670), xRadius: 80, yRadius: 80).fill()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.18); shadow.shadowBlurRadius = 22; shadow.shadowOffset = NSSize(width: 0, height: -12)
    NSGraphicsContext.saveGraphicsState(); shadow.set()
    color(c.sheet).setFill(); NSBezierPath(roundedRect: NSRect(x: 204, y: 208, width: 616, height: 640), xRadius: 68, yRadius: 68).fill()
    NSGraphicsContext.restoreGraphicsState()
    color(c.bar).setFill(); NSBezierPath(roundedRect: NSRect(x: 250, y: 700, width: 524, height: 92), xRadius: 23, yRadius: 23).fill()
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
    let font = NSFont(name: "Georgia", size: 280) ?? .systemFont(ofSize: 280)
    ("24" as NSString).draw(in: NSRect(x: 236, y: 348, width: 552, height: 330), withAttributes: [.font: font, .foregroundColor: color(c.ink), .paragraphStyle: paragraph])
    for (i, width) in [CGFloat(280), CGFloat(196)].enumerated() {
        color(c.lines).setFill()
        NSBezierPath(roundedRect: NSRect(x: 304, y: 304 - i * 36, width: Int(width), height: 12), xRadius: 6, yRadius: 6).fill()
    }
    color(c.dot).setFill(); NSBezierPath(ovalIn: NSRect(x: 672, y: 274, width: 48, height: 48)).fill()
    NSGraphicsContext.restoreGraphicsState()
    try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func writeContents(_ json: String, in folder: String) throws {
    try json.write(toFile: "\(folder)/Contents.json", atomically: true, encoding: .utf8)
}

let catalog = "LotsOfEvents/Assets.xcassets"
for (name, colors) in themes {
    let primary = name == "Graphite"
    let folder = "\(catalog)/\(primary ? "AppIcon" : "AppIcon-\(name)").appiconset"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    try drawIcon(colors, to: "\(folder)/AppIcon.png")
    if primary {
        // Graphite is already dark, so the Home Screen's dark mode uses the same art.
        try drawIcon(colors, to: "\(folder)/AppIcon-Dark.png")
        try drawIcon(tinted, to: "\(folder)/AppIcon-Tinted.png")
        try writeContents("""
        {
          "images" : [
            { "filename" : "AppIcon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
            { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "AppIcon-Dark.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
            { "appearances" : [ { "appearance" : "luminosity", "value" : "tinted" } ], "filename" : "AppIcon-Tinted.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
          ],
          "info" : { "author" : "xcode", "version" : 1 }
        }
        """, in: folder)
    } else {
        try writeContents("""
        {
          "images" : [
            { "filename" : "AppIcon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
          ],
          "info" : { "author" : "xcode", "version" : 1 }
        }
        """, in: folder)
    }
}
