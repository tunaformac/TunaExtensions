// Renders a store icon: a white SF Symbol on a flat continuous-corner tile, 1024×1024 sRGB with
// a 40 px transparent margin, like the Strongbox, Messages 2FA, Music and Spotify icons.
// usage: swift scripts/render-symbol-icon.swift <symbol> <hex> <regular|medium|semibold|bold> <glyph-height> <out.png>
// CloudShareExtension/icon.png: icloud.and.arrow.up.fill 5E5CE6 semibold 580
import AppKit
import QuartzCore
let a = CommandLine.arguments
let symbol = a[1], hex = a[2], weightName = a[3], glyphHeight = CGFloat(Double(a[4])!), out = a[5]
let weights: [String: NSFont.Weight] = ["regular": .regular, "medium": .medium, "semibold": .semibold, "bold": .bold]
func color(_ h: String) -> NSColor {
  let v = Int(h.dropFirst(h.hasPrefix("#") ? 1 : 0), radix: 16)!
  return NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
}
let S = 1024, margin: CGFloat = 40, tile = CGFloat(S) - 2 * margin
let cg = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)

let layer = CALayer()
layer.frame = CGRect(x: margin, y: margin, width: tile, height: tile)
layer.backgroundColor = color(hex).cgColor
layer.cornerRadius = tile * 0.2237
layer.cornerCurve = .continuous
cg.saveGState(); cg.translateBy(x: margin, y: margin); layer.render(in: cg); cg.restoreGState()

// Monochrome rendering keeps the symbol's cut-outs transparent, so the tile shows through
// (as Strongbox's lock does); a palette colour would paint every layer white.
let config = NSImage.SymbolConfiguration(pointSize: 400, weight: weights[weightName]!)
let template = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let glyph = NSImage(size: template.size, flipped: false) { rect in
  template.draw(in: rect)
  NSColor.white.set()
  rect.fill(using: .sourceAtop)
  return true
}
let scale = glyphHeight / glyph.size.height
let gs = NSSize(width: glyph.size.width * scale, height: glyphHeight)
glyph.draw(in: NSRect(x: (CGFloat(S) - gs.width) / 2, y: (CGFloat(S) - gs.height) / 2, width: gs.width, height: gs.height))
NSGraphicsContext.current = nil
let rep = NSBitmapImageRep(cgImage: cg.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
