// Renders the app icon (white mic on the brand gradient) to a 1024px PNG: swift make-icon.swift out.png
import AppKit
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 100, dy: 100)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 0.36, green: 0.45, blue: 1, alpha: 1), ending: NSColor(red: 0.20, green: 0.24, blue: 0.85, alpha: 1))!.draw(in: path, angle: -90)
let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold).applying(.init(paletteColors: [.white]))
if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let s = mic.size
    mic.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
