// Draws the Sidebar app icon (1024px master) → Resources/AppIcon.icns
// Mark: the app's own layout — a lavender sidebar beside a page, on a dark squircle.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
func gradient(_ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [])
    ctx.restoreGState()
}

// macOS icon grid: 824×824 body centred, with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(bodyPath); ctx.setFillColor(rgb(24, 22, 30)); ctx.fillPath()
ctx.restoreGState()
gradient(bodyPath, [rgb(52, 45, 72), rgb(28, 25, 36), rgb(19, 18, 24)],
         from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
// hairline highlight on the rim
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.setStrokeColor(rgb(255, 255, 255, 0.10)); ctx.setLineWidth(4); ctx.strokePath()

// The window: sidebar column + page.
let win = CGRect(x: 232, y: 276, width: 560, height: 472)
let side = CGRect(x: win.minX, y: win.minY, width: 150, height: win.height)
let page = CGRect(x: side.maxX + 26, y: win.minY, width: win.maxX - side.maxX - 26, height: win.height)

let sidePath = CGPath(roundedRect: side, cornerWidth: 44, cornerHeight: 44, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 0), blur: 60, color: rgb(150, 125, 255, 0.55))
ctx.addPath(sidePath); ctx.setFillColor(rgb(150, 125, 255)); ctx.fillPath()
ctx.restoreGState()
gradient(sidePath, [rgb(196, 182, 255), rgb(124, 96, 255)],
         from: CGPoint(x: side.midX, y: side.maxY), to: CGPoint(x: side.midX, y: side.minY))

// tab lines in the sidebar (first one "active")
for (i, w) in [CGFloat(86), 70, 78].enumerated() {
    let y = side.maxY - 74 - CGFloat(i) * 58
    let r = CGRect(x: side.minX + 30, y: y, width: w, height: 22)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 11, cornerHeight: 11, transform: nil))
    ctx.setFillColor(rgb(255, 255, 255, i == 0 ? 0.95 : 0.55)); ctx.fillPath()
}

let pagePath = CGPath(roundedRect: page, cornerWidth: 44, cornerHeight: 44, transform: nil)
gradient(pagePath, [rgb(255, 255, 255), rgb(226, 224, 236)],
         from: CGPoint(x: page.midX, y: page.maxY), to: CGPoint(x: page.midX, y: page.minY))
// faint content lines on the page
for (i, w) in [CGFloat(250), 200, 230, 150].enumerated() {
    let r = CGRect(x: page.minX + 44, y: page.maxY - 96 - CGFloat(i) * 62, width: w, height: 24)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil))
    ctx.setFillColor(rgb(40, 34, 60, i == 0 ? 0.30 : 0.13)); ctx.fillPath()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
