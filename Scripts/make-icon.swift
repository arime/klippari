// Draws the Klippari app icon and writes an .iconset folder.
//
//     swift Scripts/make-icon.swift build/AppIcon.iconset
//     iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
//
// The design is option A from the Paper file ('App icon – options'):
// three rows on near-black, the top one blue, as in the panel where the
// selected row is the only colour.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("usage: swift Scripts/make-icon.swift <output.iconset>")
    exit(1)
}
let output = URL(fileURLWithPath: arguments[1])
try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// Draws on a 1024-point grid: the macOS icon template has an 824pt body
/// centred on the canvas, with the margin left for the shadow.
func draw(in context: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    let space = CGColorSpaceCreateDeviceRGB()

    // Shadow under the body.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(bodyPath)
    context.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // Body: #1C1C1F at the top to #0B0B0D at the bottom.
    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.110, green: 0.110, blue: 0.122, alpha: 1),
        CGColor(red: 0.043, green: 0.043, blue: 0.051, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: []
    )
    context.restoreGState()

    // Hairline edge so the icon holds its shape on dark backgrounds.
    context.addPath(CGPath(
        roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil
    ))
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
    context.setLineWidth(4)
    context.strokePath()

    // Three rows, top to bottom: blue #0A5CFF, then two receding greys.
    let rowWidth: CGFloat = 468
    let rowHeight: CGFloat = 104
    let gap: CGFloat = 54
    let colors = [
        CGColor(red: 0.039, green: 0.361, blue: 1, alpha: 1),
        CGColor(gray: 1, alpha: 0.35),
        CGColor(gray: 1, alpha: 0.18),
    ]
    let totalHeight = 3 * rowHeight + 2 * gap
    for (index, color) in colors.enumerated() {
        let y = body.midY + totalHeight / 2 - rowHeight - CGFloat(index) * (rowHeight + gap)
        let row = CGRect(x: body.midX - rowWidth / 2, y: y, width: rowWidth, height: rowHeight)
        context.addPath(CGPath(roundedRect: row, cornerWidth: 31, cornerHeight: 31, transform: nil))
        context.setFillColor(color)
        context.fillPath()
    }
}

func png(pixels: Int) -> Data {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(in: context)
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    return bitmap.representation(using: .png, properties: [:])!
}

// The sizes iconutil expects.
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
    ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for size in sizes {
    try png(pixels: size.pixels).write(to: output.appendingPathComponent("\(size.name).png"))
}
print("Wrote \(sizes.count) images to \(output.path)")
