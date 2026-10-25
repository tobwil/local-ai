// Erzeugt das App-Icon im KIsruptiv-Stil: „KI“ + goldener Slash auf dunkelblauem Grund.
// Aufruf: swift Scripts/make-icon.swift <ausgabe.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS-Icon-Raster: 824er Fläche mit Rand, abgerundet.
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(path)
ctx.setFillColor(NSColor(srgbRed: 0x27/255, green: 0x40/255, blue: 0x60/255, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

// Verlauf Dunkelblau → Hellblau
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let colors = [NSColor(srgbRed: 0x1E/255, green: 0x33/255, blue: 0x4E/255, alpha: 1).cgColor,
              NSColor(srgbRed: 0x27/255, green: 0x40/255, blue: 0x60/255, alpha: 1).cgColor,
              NSColor(srgbRed: 0x75/255, green: 0x90/255, blue: 0xBF/255, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
ctx.restoreGState()

// „KI“ fett, „/“ dünn in Gold – wie im Logo
let ki = NSAttributedString(string: "KI", attributes: [
    .font: NSFont.systemFont(ofSize: 430, weight: .black),
    .foregroundColor: NSColor.white,
    .kern: -18,
])
let slash = NSAttributedString(string: "/", attributes: [
    .font: NSFont.systemFont(ofSize: 470, weight: .thin),
    .foregroundColor: NSColor(srgbRed: 0xFC/255, green: 0xC4/255, blue: 0x19/255, alpha: 1),
])
let kiSize = ki.size(), slashSize = slash.size()
let total = kiSize.width + slashSize.width - 30
let x = (size - total) / 2
let y = (size - kiSize.height) / 2 + 10
ki.draw(at: NSPoint(x: x, y: y))
slash.draw(at: NSPoint(x: x + kiSize.width - 30, y: y - 28))
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("→ \(out)")
