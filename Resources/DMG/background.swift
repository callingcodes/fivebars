// Renders the DMG window background (640x400 points) at 1x and 2x, then joins them into one TIFF.
// Usage: swift Resources/DMG/background.swift <IBMPlexSans-Regular.ttf> <out-dir>
// Card stock and ink from site/assets/site.css. The cue between the two icons is the menu bar glyph
// itself: five bars rising into an arrowhead, centred between the icons on their centre line.
import AppKit

let args = CommandLine.arguments
CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: args[1]) as CFURL, .process, nil)
let outDir = URL(fileURLWithPath: args[2])

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
let paper = color(0xf2ede2), paper2 = color(0xe8e1d2), ink = color(0x18203a), ink2 = color(0x4a5169)
let size = NSSize(width: 640, height: 400)

func render(scale: CGFloat) -> URL {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                               pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Flip so y runs down, like Finder's icon positions.
    let flip = NSAffineTransform()
    flip.translateX(by: 0, yBy: size.height)
    flip.scaleX(by: 1, yBy: -1)
    flip.concat()

    // Card stock, a touch deeper at the foot.
    NSGradient(starting: paper, ending: paper2)!.draw(in: NSRect(origin: .zero, size: size), angle: 90)

    // The cue, centred between the icons on their centre line: five bars rising into an arrowhead.
    let line: CGFloat = 170, barWidth: CGFloat = 5, gap: CGFloat = 5
    let headWidth: CGFloat = 14, cueWidth = 5 * barWidth + 4 * gap + 6 + headWidth
    let startX = 320 - cueWidth / 2
    for index in 0..<5 {
        let height = 6 + CGFloat(index) * 4
        let rect = NSRect(x: startX + CGFloat(index) * (barWidth + gap), y: line - height / 2,
                          width: barWidth, height: height)
        ink.withAlphaComponent(0.25 + CGFloat(index) * 0.11).setFill()
        NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }
    let headX = startX + 5 * barWidth + 4 * gap + 6
    let head = NSBezierPath()
    head.move(to: NSPoint(x: headX, y: line - 13))
    head.line(to: NSPoint(x: headX + headWidth, y: line))
    head.line(to: NSPoint(x: headX, y: line + 13))
    head.close()
    head.lineJoinStyle = .round
    head.lineWidth = 3
    ink2.setFill()
    ink2.setStroke()
    head.fill()
    head.stroke()

    // Caption on the icon labels' line (Finder centres labels 83 pt below the icon), in the site's sans.
    let font = NSFont(name: "IBMPlexSans", size: 13) ?? NSFont.systemFont(ofSize: 13)
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let text = NSAttributedString(string: "Drag to Applications", attributes: [
        .font: font, .foregroundColor: ink2, .paragraphStyle: style,
    ])
    let textHeight = text.size().height
    // Text draws upright only in an unflipped space, so undo the flip around it.
    NSGraphicsContext.saveGraphicsState()
    flip.invert()
    flip.concat()
    text.draw(in: NSRect(x: 220, y: size.height - 253 - textHeight / 2, width: 200, height: textHeight))
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    let url = outDir.appendingPathComponent(scale == 1 ? "background.png" : "background@2x.png")
    try! rep.representation(using: .png, properties: [.compressionFactor: 1])!.write(to: url)
    return url
}

_ = render(scale: 1)
_ = render(scale: 2)
