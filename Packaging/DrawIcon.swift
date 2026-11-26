// Regenerate the original Agent Hub artwork using scripts/build-icon.sh.
import AppKit

guard CommandLine.arguments.count == 3,
      let size = Int(CommandLine.arguments[1]),
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let context = graphics.cgContext
context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let tile = NSBezierPath(roundedRect: NSRect(x: 84, y: 84, width: 856, height: 856),
                        xRadius: 198, yRadius: 198)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 19,
                  color: color(0.01, 0.07, 0.11, 0.38).cgColor)
color(0.08, 0.20, 0.24).setFill()
tile.fill()
context.restoreGState()
NSGradient(starting: color(0.08, 0.19, 0.23),
           ending: color(0.16, 0.39, 0.40))!.draw(in: tile, angle: 100)

// Three activity lanes gather into a shared output, with an open ring at the junction.
let ink = color(0.84, 0.98, 0.91)
ink.setStroke()
func lane(_ start: NSPoint, _ bend: NSPoint, _ end: NSPoint) {
    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: bend)
    path.line(to: end)
    path.lineWidth = 47
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
}
lane(NSPoint(x: 290, y: 685), NSPoint(x: 376, y: 685), NSPoint(x: 520, y: 530))
lane(NSPoint(x: 290, y: 339), NSPoint(x: 376, y: 339), NSPoint(x: 520, y: 494))
lane(NSPoint(x: 290, y: 512), NSPoint(x: 452, y: 512), NSPoint(x: 745, y: 512))
let junction = NSBezierPath(ovalIn: NSRect(x: 478, y: 444, width: 136, height: 136))
color(0.15, 0.30, 0.32).setFill()
junction.fill()
color(0.92, 0.74, 0.41).setStroke()
junction.lineWidth = 33
junction.stroke()
NSGraphicsContext.restoreGraphicsState()
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
