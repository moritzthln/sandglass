#!/usr/bin/env swift
//
// Draws Sandglass's icon and writes `Resources/Sandglass.icns`.
//
// Run from `mac/`:  swift scripts/make-icon.swift
//
// The `.icns` is committed, so a normal build never runs this — it is here so the icon can be
// changed by editing numbers rather than by opening a drawing program, and so the shape is
// readable as the reason for it rather than as a binary nobody can revise.
//
// **What it draws, and why.** A countdown ring, not a shield. The menu bar already speaks in
// shields because it reports status there, and a shield is what every security app on the Mac
// puts in the Dock. The ring is what this app actually shows a person: the wait between wanting
// something and getting it. It also survives 16 points, which is the size that matters most here —
// System Settings lists Sandglass at that size in Accessibility and Automation, and after every
// reinstall that list is where the user has to go.
//
// The geometry follows Apple's Big Sur grid: a 1024 canvas with the rounded square inset to 824,
// corner radius 185. Anything drawn outside that square is clipped by macOS's own mask on some
// surfaces, so everything stays well inside it.

import AppKit
import CoreGraphics
import Foundation

// MARK: - The drawing

/// Canvas edge, in points, at 1x for the largest slice.
let canvas: CGFloat = 1024
/// Apple's Big Sur icon grid: the square is inset, not flush to the edge.
let squareEdge: CGFloat = 824
let cornerRadius: CGFloat = 185

/// Graphite, lit from above. Dark on purpose: the icon is read against the light background of a
/// System Settings list far more often than against a Dock.
let backgroundTop = CGColor(red: 0.196, green: 0.231, blue: 0.278, alpha: 1)      // #323B47
let backgroundBottom = CGColor(red: 0.086, green: 0.106, blue: 0.133, alpha: 1)   // #161B22
/// The hourglass. A muted teal — it reads as an instrument rather than as a warning, which is the
/// difference between this app and a parental control.
let ringColor = CGColor(red: 0.373, green: 0.788, blue: 0.706, alpha: 1)          // #5FC9B4

func drawIcon(into context: CGContext, edge: CGFloat) {
    let scale = edge / canvas
    context.saveGState()
    context.scaleBy(x: scale, y: scale)

    let inset = (canvas - squareEdge) / 2
    let square = CGRect(x: inset, y: inset, width: squareEdge, height: squareEdge)
    let squircle = CGPath(
        roundedRect: square, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
    )

    context.saveGState()
    context.addPath(squircle)
    context.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(
        colorsSpace: space, colors: [backgroundTop, backgroundBottom] as CFArray, locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: square.maxY),
            end: CGPoint(x: 0, y: square.minY),
            options: []
        )
    }
    context.restoreGState()

    drawHourglass(into: context)
    context.restoreGState()
}

/// An hourglass, drawn from the system symbol.
///
/// **Chosen** over a progress ring and four others, judged as rendered rather than described. The
/// ring was the more distinctive mark and this is the more legible one: an hourglass says *waiting*
/// to anybody, in any size, without a caption — and waiting is the whole mechanic. The menu bar
/// carries the same family one size down, where `hourglass.tophalf.filled` and `.bottomhalf.filled`
/// are the two states that survive 17 points.
///
/// Taken from SF Symbols rather than drawn by hand: it is Apple's own glyph, so it sits at the
/// same optical weight as everything else in the Dock and the Finder, and it costs no bezier
/// arithmetic that would have to be revised the next time the shape changes.
func drawHourglass(into context: CGContext) {
    let height: CGFloat = 430
    guard let symbol = NSImage(
        systemSymbolName: "hourglass", accessibilityDescription: nil
    )?.withSymbolConfiguration(.init(pointSize: height, weight: .regular)) else { return }

    // Tinted by filling the colour and keeping only where the glyph is opaque (`destinationIn`).
    // A symbol image carries its own colour, and `CGContext.clip(to:mask:)` reads a mask the
    // other way round than one expects — black paints, white does not — which is how the first
    // attempt came out as a teal rectangle with the hourglass punched out of it.
    let size = symbol.size
    let box = NSRect(
        x: (canvas - size.width) / 2, y: (canvas - size.height) / 2,
        width: size.width, height: size.height
    )
    let tinted = NSImage(size: size, flipped: false) { bounds in
        NSColor(cgColor: ringColor)?.set()
        bounds.fill()
        symbol.draw(in: bounds, from: .zero, operation: .destinationIn, fraction: 1)
        return true
    }

    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    tinted.draw(in: box)
    NSGraphicsContext.current = previous
}

// MARK: - Rendering the slices

func bitmapContext(edge: Int) -> CGContext? {
    CGContext(
        data: nil,
        width: edge,
        height: edge,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
}

/// The icon drawn once, at the largest slice. Every smaller slice is this image scaled down.
///
/// Drawing each slice directly does not work for the glyph: the tinted symbol is an `NSImage`
/// drawn into a context scaled to the slice, and AppKit rasterizes it far coarser than the slice
/// needs, so everything below 1024 came out visibly pixelated — in the Dock and the Finder, the
/// sizes people actually see. A high-quality downsample from one sharp master has no such failure.
let master: CGImage? = {
    guard let context = bitmapContext(edge: 1024) else { return nil }
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    drawIcon(into: context, edge: 1024)
    return context.makeImage()
}()

func render(edge: Int) -> Data? {
    guard let master, let context = bitmapContext(edge: edge) else { return nil }
    context.interpolationQuality = .high
    context.draw(master, in: CGRect(x: 0, y: 0, width: edge, height: edge))
    guard let image = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: edge, height: edge)
    return rep.representation(using: .png, properties: [:])
}

/// The ten slices `iconutil` expects, as (file name, pixel edge).
let slices: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let fileManager = FileManager.default
let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("Sandglass-icon-\(ProcessInfo.processInfo.processIdentifier)")
let iconset = scratch.appendingPathComponent("Sandglass.iconset")
try? fileManager.removeItem(at: scratch)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

for (name, edge) in slices {
    guard let png = render(edge: edge) else {
        FileHandle.standardError.write(Data("FAIL: could not render \(name)\n".utf8))
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent(name))
}

let destination = URL(fileURLWithPath: fileManager.currentDirectoryPath)
    .appendingPathComponent("Resources/Sandglass.icns")
try? fileManager.createDirectory(
    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("FAIL: iconutil exited \(iconutil.terminationStatus)\n".utf8))
    exit(1)
}

try? fileManager.removeItem(at: scratch)
print("wrote \(destination.path)")
