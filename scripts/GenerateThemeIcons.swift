// Package the approved Agenda Pulse artwork into opaque 1024px app-icon assets.
// Run from the repository root: swift scripts/GenerateThemeIcons.swift
// Source artwork is retained in Artwork/AgendaPulse; this does not redraw or recolor it.
import AppKit

let catalog = "LotsOfEvents/Assets.xcassets"

func export(_ appearance: String, to path: String) throws {
    let source = URL(fileURLWithPath: "Artwork/AgendaPulse/\(appearance).png")
    guard let image = NSImage(contentsOf: source),
          let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                                  bytesPerRow: 4096, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw NSError(domain: "AgendaPulseIcons", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot read \(source.path)"])
    }
    // Asset-catalog normalization only: preserve the approved artwork, remove any alpha channel,
    // and use the exact dimensions required by the universal iOS/Catalyst icon slot.
    context.interpolationQuality = .high
    context.draw(bitmap, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    let output = NSBitmapImageRep(cgImage: context.makeImage()!)
    try output.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func writeSet(_ name: String, base: String) throws {
    let folder = "\(catalog)/\(name).appiconset"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    try export(base, to: "\(folder)/AppIcon.png")
    try export("Dark", to: "\(folder)/AppIcon-Dark.png")
    try export("Tinted", to: "\(folder)/AppIcon-Tinted.png")
    let json = """
    {
      "images": [
        { "filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" },
        { "appearances": [{ "appearance": "luminosity", "value": "dark" }], "filename": "AppIcon-Dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" },
        { "appearances": [{ "appearance": "luminosity", "value": "tinted" }], "filename": "AppIcon-Tinted.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" }
      ],
      "info": { "author": "xcode", "version": 1 }
    }
    """
    try json.write(toFile: "\(folder)/Contents.json", atomically: true, encoding: .utf8)
}

try writeSet("AppIcon", base: "Light")
// Retain existing alternate-icon identifiers so saved theme choices keep working.
for name in ["Light", "Dark", "Midnight", "Forest", "Studio"] {
    try writeSet("AppIcon-\(name)", base: ["Light", "Studio"].contains(name) ? "Light" : "Dark")
}
try export("Dark", to: "LotsOfEventsWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
print("Packaged Agenda Pulse light, dark, and tinted icons, all theme alternates, and the Watch icon.")
