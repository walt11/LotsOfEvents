// Reproducible, vector-drawn Soft Gallery icon. Run with: swift scripts/GenerateGalleryIcon.swift
import AppKit

func color(_ hex: UInt) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
let destination = "LotsOfEvents/Assets.xcassets/AppIcon.appiconset"
for variant in ["", "-Dark", "-Tinted"] {
    let dark = variant == "-Dark", tinted = variant == "-Tinted"
    let background = color(tinted ? 0x252525 : dark ? 0x231F1C : 0xF2EDE5)
    let paper = color(tinted ? 0xEEEEEE : dark ? 0xE5D9C8 : 0xFFFDF8)
    let accent = color(tinted ? 0x777777 : 0xB94D2C)
    let ink = color(tinted ? 0x444444 : 0x342D27)
    let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    background.setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
    // A pair of offset paper sheets makes the mark read as a small gallery.
    color(tinted ? 0x999999 : dark ? 0x756559 : 0xD8CDBE).setFill()
    NSBezierPath(roundedRect: NSRect(x: 172, y: 170, width: 666, height: 670), xRadius: 80, yRadius: 80).fill()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.12); shadow.shadowBlurRadius = 22; shadow.shadowOffset = NSSize(width: 0, height: -12)
    NSGraphicsContext.saveGraphicsState(); shadow.set()
    paper.setFill(); NSBezierPath(roundedRect: NSRect(x: 204, y: 208, width: 616, height: 640), xRadius: 68, yRadius: 68).fill()
    NSGraphicsContext.restoreGraphicsState()
    accent.setFill(); NSBezierPath(roundedRect: NSRect(x: 250, y: 700, width: 524, height: 92), xRadius: 23, yRadius: 23).fill()
    // Calendar date, balanced serif numerals; no miniature labels to become unreadable.
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
    let font = NSFont(name: "Georgia", size: 280) ?? .systemFont(ofSize: 280)
    ("24" as NSString).draw(in: NSRect(x: 236, y: 348, width: 552, height: 330), withAttributes: [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph])
    for (i, width) in [CGFloat(280), CGFloat(196)].enumerated() {
        color(tinted ? 0xAAAAAA : 0xB5A797).setFill()
        NSBezierPath(roundedRect: NSRect(x: 304, y: 304 - i * 36, width: Int(width), height: 12), xRadius: 6, yRadius: 6).fill()
    }
    accent.setFill(); NSBezierPath(ovalIn: NSRect(x: 672, y: 274, width: 48, height: 48)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(destination)/AppIcon\(variant).png"))
}
