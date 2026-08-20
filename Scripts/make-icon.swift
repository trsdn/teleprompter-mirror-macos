// Generates Resources/AppIcon.icns from code, so the icon stays reproducible
// and no binary design file has to be maintained by hand.
//
//     swift Scripts/make-icon.swift
//
// The artwork shows a "T" above a mirror line with its reflection below it,
// which is what the app does: it mirrors a source onto a teleprompter.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let canvas: CGFloat = 1024
private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
private let axis: CGFloat = 560
private let letterTop: CGFloat = 240
private let letterHeight: CGFloat = 270

private func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Design coordinates use a top-left origin, which is easier to reason about
/// than Core Graphics' bottom-left origin.
private func rect(
    x: CGFloat,
    top: CGFloat,
    width: CGFloat,
    height: CGFloat
) -> CGRect {
    CGRect(x: x, y: canvas - top - height, width: width, height: height)
}

/// A "T" built from two rounded bars, so no font dependency is needed.
private func letterT(top: CGFloat, height: CGFloat) -> CGPath {
    let barHeight = height * 0.26
    let stemWidth = height * 0.26
    let width = height * 1.30
    let path = CGMutablePath()
    path.addRoundedRect(
        in: rect(
            x: (canvas - width) / 2,
            top: top,
            width: width,
            height: barHeight
        ),
        cornerWidth: barHeight * 0.3,
        cornerHeight: barHeight * 0.3
    )
    path.addRoundedRect(
        in: rect(
            x: (canvas - stemWidth) / 2,
            top: top + barHeight * 0.7,
            width: stemWidth,
            height: height - barHeight * 0.7
        ),
        cornerWidth: stemWidth * 0.3,
        cornerHeight: stemWidth * 0.3
    )
    return path
}

private func drawArtwork(in context: CGContext) {
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // Apple sizes the rounded plate at 824 pt on a 1024 pt canvas.
    let inset: CGFloat = 100
    let plate = CGRect(
        x: inset,
        y: inset,
        width: canvas - inset * 2,
        height: canvas - inset * 2
    )
    let squircle = CGPath(
        roundedRect: plate,
        cornerWidth: plate.width * 0.225,
        cornerHeight: plate.width * 0.225,
        transform: nil
    )

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -12),
        blur: 24,
        color: color(0x000000, 0.35)
    )
    context.setFillColor(color(0x0C1119))
    context.addPath(squircle)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(squircle)
    context.clip()

    if let background = CGGradient(
        colorsSpace: sRGB,
        colors: [color(0x2B4A6F), color(0x0C1119)] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            background,
            start: CGPoint(x: 0, y: canvas),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
    }

    let upright = letterT(top: letterTop, height: letterHeight)

    // Reflection: the same glyph flipped across the mirror line, fading out.
    let mirrorY = canvas - axis
    var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: mirrorY * 2)
    if let reflection = upright.copy(using: &flip) {
        context.saveGState()
        context.addPath(reflection)
        context.clip()
        if let fade = CGGradient(
            colorsSpace: sRGB,
            colors: [color(0x8FC2FF, 0.55), color(0x8FC2FF, 0.10)] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                fade,
                start: CGPoint(x: 0, y: mirrorY),
                end: CGPoint(x: 0, y: mirrorY - letterHeight),
                options: []
            )
        }
        context.restoreGState()
    }

    // Mirror line.
    let lineWidth = letterHeight * 1.45
    context.setFillColor(color(0x8FC2FF, 0.85))
    context.addPath(CGPath(
        roundedRect: rect(
            x: (canvas - lineWidth) / 2,
            top: axis - 5,
            width: lineWidth,
            height: 10
        ),
        cornerWidth: 5,
        cornerHeight: 5,
        transform: nil
    ))
    context.fillPath()

    // Upright glyph on top of everything.
    context.setFillColor(color(0xFFFFFF))
    context.addPath(upright)
    context.fillPath()

    context.restoreGState()
}

private func renderPNG(size: Int, to url: URL) throws {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let scale = CGFloat(size) / canvas
    context.scaleBy(x: scale, y: scale)
    drawArtwork(in: context)

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              url as CFURL,
              UTType.png.identifier as CFString,
              1,
              nil
          ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = repositoryRoot
    .appendingPathComponent("Resources")
    .appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(
    at: iconset,
    withIntermediateDirectories: true
)

// The sizes macOS expects inside an .iconset directory.
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024)
]

for variant in variants {
    try renderPNG(
        size: variant.size,
        to: iconset.appendingPathComponent("\(variant.name).png")
    )
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "--convert", "icns",
    "--output", repositoryRoot
        .appendingPathComponent("Resources")
        .appendingPathComponent("AppIcon.icns").path,
    iconset.path
]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed.\n".utf8))
    exit(1)
}

try FileManager.default.removeItem(at: iconset)
print("Resources/AppIcon.icns was generated.")
