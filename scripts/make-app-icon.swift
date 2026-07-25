import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// PhotoEditor's app icon.
//
// The mark is a single film frame: a dark rebate carrying an image window, and
// in that window the tonal ramp the whole application exists to shape. It says
// "photographs, as files" in one shape, and it survives being 16 pixels wide,
// which is the only test an app icon actually has to pass.
//
// Every size is drawn from the same proportional maths rather than downsampled
// from one master, so the small ones stay crisp instead of turning to mud. Fine
// detail — sprocket holes, the amber edge print — is drawn only at sizes that
// can hold it.

func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func continuousRoundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    // Approximates Apple's continuous ("squircle") corner with a bezier whose
    // control points sit further along the edge than a circular arc's would.
    let r = min(radius, min(rect.width, rect.height) / 2)
    let k = r * 0.32
    let p = CGMutablePath()
    p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
    p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r),
               control1: CGPoint(x: rect.maxX - k, y: rect.minY),
               control2: CGPoint(x: rect.maxX, y: rect.minY + k))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
    p.addCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
               control1: CGPoint(x: rect.maxX, y: rect.maxY - k),
               control2: CGPoint(x: rect.maxX - k, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
    p.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
               control1: CGPoint(x: rect.minX + k, y: rect.maxY),
               control2: CGPoint(x: rect.minX, y: rect.maxY - k))
    p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
    p.addCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
               control1: CGPoint(x: rect.minX, y: rect.minY + k),
               control2: CGPoint(x: rect.minX + k, y: rect.minY))
    p.closeSubpath()
    return p
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: stops.map(\.0) as CFArray,
               locations: stops.map(\.1))!
}

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Everything is expressed as a fraction of the canvas, so the drawing is
    // resolution-independent by construction.
    func u(_ fraction: CGFloat) -> CGFloat { fraction * s }
    let detailed = size >= 128
    let fineDetail = size >= 256

    // MARK: The body — a graphite squircle

    let bodyRect = CGRect(x: u(0.098), y: u(0.098), width: u(0.804), height: u(0.804))
    let body = continuousRoundedPath(bodyRect, radius: u(0.180))

    // Contact shadow, so the icon sits on the dock rather than floating.
    if detailed {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -u(0.012)),
                      blur: u(0.030), color: srgb(0, 0, 0, 0.55))
        ctx.addPath(body)
        ctx.setFillColor(srgb(20, 20, 21))
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(srgb(62, 62, 65), 0), (srgb(38, 38, 40), 0.45), (srgb(21, 21, 23), 1)]),
        start: CGPoint(x: 0, y: bodyRect.maxY), end: CGPoint(x: 0, y: bodyRect.minY),
        options: []
    )
    ctx.restoreGState()

    // The specular top edge — the same one-pixel bevel the app's own controls
    // use to read as machined.
    if detailed {
        ctx.saveGState()
        ctx.addPath(body)
        ctx.setStrokeColor(srgb(255, 255, 255, 0.16))
        ctx.setLineWidth(max(u(0.004), 1))
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([(srgb(255, 255, 255, 0.9), 0), (srgb(255, 255, 255, 0), 0.5)]),
            start: CGPoint(x: 0, y: bodyRect.maxY), end: CGPoint(x: 0, y: bodyRect.midY),
            options: []
        )
        ctx.restoreGState()
    }

    // MARK: The film frame

    // A 3:2 image window — the aspect the subject actually comes in — inside a
    // darker rebate.
    let frameWidth = u(0.560)
    let frameHeight = frameWidth * 2 / 3
    let rebateInset = detailed ? u(0.052) : u(0.040)
    let rebateRect = CGRect(
        x: (s - frameWidth) / 2 - rebateInset,
        y: (s - frameHeight) / 2 - rebateInset,
        width: frameWidth + rebateInset * 2,
        height: frameHeight + rebateInset * 2
    )
    let windowRect = CGRect(x: (s - frameWidth) / 2, y: (s - frameHeight) / 2,
                            width: frameWidth, height: frameHeight)

    ctx.saveGState()
    ctx.addPath(continuousRoundedPath(rebateRect, radius: u(0.022)))
    ctx.setFillColor(srgb(12, 12, 13))
    ctx.fillPath()
    ctx.restoreGState()

    // The photograph: the tonal ramp, shadow to highlight, warm at the top the
    // way a print is. This is the only colour in the whole identity, and it is
    // carrying photographic meaning — which is the app's rule for colour.
    ctx.saveGState()
    let windowPath = continuousRoundedPath(windowRect, radius: u(0.008))
    ctx.addPath(windowPath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([
            (srgb(246, 238, 222), 0),
            (srgb(214, 197, 170), 0.22),
            (srgb(126, 133, 140), 0.52),
            (srgb(52, 62, 74), 0.80),
            (srgb(14, 20, 30), 1),
        ]),
        start: CGPoint(x: windowRect.minX, y: windowRect.maxY),
        end: CGPoint(x: windowRect.midX, y: windowRect.minY),
        options: []
    )

    // A horizon: one straight edge is what turns a gradient into a photograph.
    if detailed {
        let horizon = windowRect.minY + windowRect.height * 0.36
        ctx.setFillColor(srgb(10, 15, 24, 0.62))
        ctx.fill(CGRect(x: windowRect.minX, y: windowRect.minY,
                        width: windowRect.width, height: horizon - windowRect.minY))
        // The thin bright line along it reads as light on water.
        ctx.setFillColor(srgb(255, 246, 226, 0.42))
        ctx.fill(CGRect(x: windowRect.minX, y: horizon,
                        width: windowRect.width, height: max(u(0.004), 1)))
    }
    ctx.restoreGState()

    // MARK: Rebate detail
    //
    // Sprocket holes and edge print are what make the shape read as *film*
    // rather than as a generic picture. They are also the first things to turn
    // to mud, so they appear only where there are pixels to hold them.

    if fineDetail {
        let holeWidth = u(0.026)
        let holeHeight = u(0.018)
        let count = 7
        let spacing = rebateRect.width / CGFloat(count + 1)
        ctx.setFillColor(srgb(46, 46, 48))
        for i in 1...count {
            let x = rebateRect.minX + spacing * CGFloat(i) - holeWidth / 2
            // The first two holes on the top run are omitted: that is where the
            // edge print goes, and on a real negative the legend interrupts the
            // perforations rather than sitting on top of them.
            for (row, y) in [rebateRect.minY + u(0.014),
                             rebateRect.maxY - u(0.014) - holeHeight].enumerated() {
                if row == 1 && i <= 2 { continue }
                ctx.addPath(continuousRoundedPath(
                    CGRect(x: x, y: y, width: holeWidth, height: holeHeight),
                    radius: u(0.005)
                ))
            }
        }
        ctx.fillPath()

        // Edge print, in the dim amber a negative carries its own provenance in.
        let label = "36A"
        let font = NSFont.monospacedSystemFont(ofSize: u(0.026), weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: srgb(168, 138, 78))!,
            .kern: u(0.004),
        ]
        let line = NSAttributedString(string: label, attributes: attributes)
        let textSize = line.size()
        ctx.saveGState()
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx
        line.draw(at: CGPoint(x: rebateRect.minX + u(0.018),
                              y: rebateRect.maxY - textSize.height - u(0.010)))
        NSGraphicsContext.current = nil
        ctx.restoreGState()
    }

    return ctx.makeImage()!
}

// MARK: - Write

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, pixels) in sizes {
    let image = drawIcon(size: pixels)
    let url = outputDirectory.appendingPathComponent("\(name).png")
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil
    ) else { fatalError("could not create \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("write failed") }
    print("wrote \(name).png  (\(pixels)px)")
}
