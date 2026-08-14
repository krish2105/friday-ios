import AppKit
import CoreGraphics
import Foundation

// FRIDAY app icon — amber orb with voice rings on charcoal.
// Palette taken from FridayTheme: ground #0B0B0D, amber #FFB33B.

let size = 1024.0
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("context")
}

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}

let amber = (r: 1.0, g: 0.702, b: 0.231)
let centre = CGPoint(x: size / 2, y: size / 2)

// 1. Ground — a very slight vertical lift so it is not a flat black square.
let ground = CGGradient(colorsSpace: cs, colors: [
    rgb(0.086, 0.086, 0.098), rgb(0.035, 0.035, 0.043)
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(ground, start: CGPoint(x: 0, y: size),
                       end: CGPoint(x: 0, y: 0), options: [])

// 2. Outer bloom — wide, very soft, sells the "glow" without any blur cost.
let bloom = CGGradient(colorsSpace: cs, colors: [
    rgb(amber.r, amber.g, amber.b, 0.30),
    rgb(amber.r, amber.g, amber.b, 0.10),
    rgb(amber.r, amber.g, amber.b, 0.0)
] as CFArray, locations: [0, 0.45, 1])!
ctx.drawRadialGradient(bloom, startCenter: centre, startRadius: 0,
                       endCenter: centre, endRadius: size * 0.46, options: [])

// 3. Voice rings — two arcs, unequal sweeps and weights so it reads as motion
//    rather than a target. Drawn before the core so the orb sits on top.
func arc(radius: Double, start: Double, sweep: Double, width: Double, alpha: Double) {
    ctx.setStrokeColor(rgb(amber.r, amber.g, amber.b, alpha))
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.addArc(center: centre, radius: radius,
               startAngle: start * .pi / 180,
               endAngle: (start + sweep) * .pi / 180,
               clockwise: false)
    ctx.strokePath()
}
arc(radius: size * 0.355, start: 118, sweep: 145, width: 26, alpha: 0.90)
arc(radius: size * 0.355, start: -52, sweep: 74, width: 26, alpha: 0.45)
arc(radius: size * 0.285, start: -18, sweep: 108, width: 15, alpha: 0.55)

// 4. Orb core — bright centre falling to transparent.
let core = CGGradient(colorsSpace: cs, colors: [
    rgb(1.0, 0.88, 0.62, 1.0),
    rgb(amber.r, amber.g, amber.b, 0.95),
    rgb(amber.r, amber.g, amber.b, 0.18)
] as CFArray, locations: [0, 0.42, 1])!
let coreRadius = size * 0.205
ctx.drawRadialGradient(core, startCenter: CGPoint(x: centre.x, y: centre.y + size * 0.02),
                       startRadius: 0, endCenter: centre, endRadius: coreRadius, options: [])

// 5. Rim — the crisp edge that keeps the orb from looking like a smudge.
ctx.setStrokeColor(rgb(1.0, 0.82, 0.50, 0.95))
ctx.setLineWidth(7)
ctx.addArc(center: centre, radius: coreRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.strokePath()

guard let image = ctx.makeImage() else { fatalError("image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
let out = CommandLine.arguments[1]
try png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
