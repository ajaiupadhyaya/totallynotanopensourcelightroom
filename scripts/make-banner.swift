import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The README banner.
//
// Generated rather than hand-composed so the version never drifts out of date,
// and so it follows the same type rule the application does: the statement is
// set in the text face, and only the *data* — the version stamp — is monospaced.

let version = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "2.1.0"
let sampleURL = URL(fileURLWithPath: "docs/media/samples/sample-architecture.png")
let outputURL = URL(fileURLWithPath: "docs/media/figures/banner.jpg")

let width = 1600, height = 440
let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// The graphite ground, the same value as the app's own chrome.
ctx.setFillColor(srgb(20, 20, 21))
ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

// The photograph occupies the right fifth, bled off the edge and faded into the
// ground so the panel reads as one surface rather than two glued together.
if let source = CGImageSourceCreateWithURL(sampleURL as CFURL, nil),
   let photo = CGImageSourceCreateImageAtIndex(source, 0, nil) {
    let panel = CGRect(x: CGFloat(width) * 0.815, y: 0,
                       width: CGFloat(width) * 0.185, height: CGFloat(height))
    ctx.saveGState()
    ctx.clip(to: panel)
    // Cover the panel, cropping rather than squashing.
    let scale = max(panel.width / CGFloat(photo.width), panel.height / CGFloat(photo.height))
    let drawn = CGSize(width: CGFloat(photo.width) * scale,
                       height: CGFloat(photo.height) * scale)
    ctx.draw(photo, in: CGRect(x: panel.midX - drawn.width / 2,
                               y: panel.midY - drawn.height / 2,
                               width: drawn.width, height: drawn.height))
    // Feather the inner edge back into the ground.
    ctx.drawLinearGradient(
        CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                   colors: [srgb(20, 20, 21, 1), srgb(20, 20, 21, 0)] as CFArray,
                   locations: [0, 1])!,
        start: CGPoint(x: panel.minX, y: 0),
        end: CGPoint(x: panel.minX + panel.width * 0.42, y: 0),
        options: []
    )
    ctx.restoreGState()
}

let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.current = nsCtx

func draw(_ text: String, _ font: NSFont, _ color: CGColor, at point: CGPoint, kern: CGFloat = 0) {
    NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: NSColor(cgColor: color)!,
        .kern: kern,
    ]).draw(at: point)
}

// The statement, in the text face — the app's rule is that language is not
// monospaced.
let headline = NSFont.systemFont(ofSize: 54, weight: .semibold)
draw("No AI.", headline, srgb(236, 236, 236), at: CGPoint(x: 76, y: 296), kern: -1)
draw("No cloud.", headline, srgb(236, 236, 236), at: CGPoint(x: 76, y: 228), kern: -1)
draw("No accounts.", headline, srgb(236, 236, 236), at: CGPoint(x: 76, y: 160), kern: -1)

let body = NSFont.systemFont(ofSize: 17, weight: .regular)
draw("A native macOS develop desk.", body, srgb(156, 156, 156), at: CGPoint(x: 78, y: 108))
draw("Your photographs stay files on your disk.", body, srgb(156, 156, 156),
     at: CGPoint(x: 78, y: 82))

// The version stamp is measurement, so it is monospaced.
draw("PHOTOEDITOR · \(version)",
     NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
     srgb(168, 138, 78), at: CGPoint(x: 78, y: 40), kern: 1.6)

NSGraphicsContext.current = nil

guard let image = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil
      ) else { fatalError("could not render banner") }
CGImageDestinationAddImage(destination, image,
                           [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
guard CGImageDestinationFinalize(destination) else { fatalError("write failed") }
print("wrote \(outputURL.path) at \(version)")
