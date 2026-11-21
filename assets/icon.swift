import AppKit
let out = CommandLine.arguments[1]
let s: CGFloat = 1024
let img = NSImage(size: NSSize(width: s, height: s))
img.lockFocus()
let bg = NSBezierPath(roundedRect: NSRect(x: 50, y: 50, width: 924, height: 924), xRadius: 210, yRadius: 210)
NSGradient(colors: [NSColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 1), NSColor(srgbRed: 0.04, green: 0.04, blue: 0.06, alpha: 1)])!.draw(in: bg, angle: -90)
let p = NSMutableParagraphStyle(); p.alignment = .center
let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 520, weight: .heavy), .foregroundColor: NSColor(srgbRed: 0.20, green: 0.82, blue: 0.40, alpha: 1), .paragraphStyle: p]
let str = NSAttributedString(string: ":)", attributes: a)
let h = str.size().height
str.draw(in: NSRect(x: 0, y: (s - h) / 2 + 10, width: s, height: h))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
