// Vox branding — renders the alien mascot and sets it as the app's icon via
// NSWorkspace.setIcon. This writes icon METADATA beside the bundle; it never
// touches the signed code, so the app's signature and Accessibility grant stay
// intact. Usage:  swift brand.swift /Applications/Hammerspoon.app
import AppKit

let target = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "/Applications/Hammerspoon.app"

let S: CGFloat = 1024
let alien = NSColor(red: 0.45, green: 0.97, blue: 0.72, alpha: 1)   // mint
let eyes  = NSColor(red: 0.02, green: 0.06, blue: 0.12, alpha: 1)
let cyan  = NSColor(red: 0.35, green: 0.90, blue: 1.00, alpha: 0.30)

let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

// rounded-square background with a dark navy gradient
let bg = NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: S - 192, height: S - 192),
                      xRadius: 190, yRadius: 190)
bg.addClip()
NSGradient(colors: [NSColor(red: 0.07, green: 0.08, blue: 0.15, alpha: 1),
                    NSColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1)])!
    .draw(in: bg, angle: -90)
bg.setClip()

// faint cyan waveform bars flanking the alien
cyan.setFill()
func bar(_ x: CGFloat, _ h: CGFloat) {
    NSBezierPath(roundedRect: NSRect(x: x, y: 512 - h/2, width: 26, height: h),
                 xRadius: 13, yRadius: 13).fill()
}
let hgts: [CGFloat] = [70, 130, 190]
for (i, x) in [250.0, 300.0, 350.0].enumerated() { bar(CGFloat(x), hgts[i]) }
for (i, x) in [648.0, 698.0, 748.0].enumerated() { bar(CGFloat(x), hgts[2 - i]) }

// antenna stalk + tip
alien.setStroke()
let ant = NSBezierPath()
ant.move(to: NSPoint(x: 512, y: 760)); ant.line(to: NSPoint(x: 512, y: 858))
ant.lineWidth = 26; ant.lineCapStyle = .round; ant.stroke()
alien.setFill()
NSBezierPath(ovalIn: NSRect(x: 470, y: 838, width: 84, height: 84)).fill()

// head (mint oval, slightly taller than wide)
NSBezierPath(ovalIn: NSRect(x: 322, y: 350, width: 380, height: 410)).fill()

// eyes
eyes.setFill()
NSBezierPath(ovalIn: NSRect(x: 420, y: 545, width: 92, height: 122)).fill()
NSBezierPath(ovalIn: NSRect(x: 512, y: 545, width: 92, height: 122)).fill()

// smile (arc under the eyes)
eyes.setStroke()
let smile = NSBezierPath()
smile.appendArc(withCenter: NSPoint(x: 512, y: 545), radius: 82,
                startAngle: 205, endAngle: 335)
smile.lineWidth = 26; smile.lineCapStyle = .round; smile.stroke()

img.unlockFocus()

if NSWorkspace.shared.setIcon(img, forFile: target, options: []) {
    print("branded \(target) with the Vox icon")
} else {
    FileHandle.standardError.write("setIcon failed for \(target)\n".data(using: .utf8)!)
    exit(1)
}
