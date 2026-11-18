// Generates the JeanNotch logo from one pixel grid:
//   assets/logo.svg, assets/logo.png (1024 px), assets/AppIcon.icns
// Run from the repo root: swift scripts/make-logo.swift
import AppKit

// 32 x 32 cells of 32 px on a 1024 px canvas.
// N = notch, Y = J: a thin, flat J with two-cell strokes, like the one in the notch.
let grid = [
    "................................",
    "................................",
    "................................",
    "..........NNNNNNNNNNNN..........",
    "..........NNNNNNNNNNNN..........",
    "..........NNNNNNNNNNNN..........",
    "..........NNNNNNNNNNNN..........",
    "...........NNNNNNNNNN...........",
    "...................YY...........",
    "...................YY...........",
    "...................YY...........",
    "...................YY...........",
    "...................YY...........",
    "...................YY...........",
    "...................YY...........",
    "...................YY...........",
    "...................YY...........",
    "...................YY...........",
    "...........YY......YY...........",
    "...........YY......YY...........",
    "...........YY......YY...........",
    ".............YYYYYY.............",
    ".............YYYYYY.............",
    "................................",
    "................................",
    "................................",
    "................................",
    "................................",
    "................................",
    "................................",
    "................................",
    "................................",
]

let cell = 32
let size = 1024
let colors: [Character: String] = [
    "N": "#000000",  // notch
    "Y": "#FDD24F",  // Jean yellow
]
let background = "#1E1E22"
let bgInset = 96, bgRadius = 184

let cells = grid.map { Array($0) }

// MARK: SVG

var svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(size) \(size)" width="\(size)" height="\(size)" shape-rendering="crispEdges">
<rect x="\(bgInset)" y="\(bgInset)" width="\(size - 2 * bgInset)" height="\(size - 2 * bgInset)" rx="\(bgRadius)" fill="\(background)"/>

"""
for y in cells.indices {
    var x = 0
    while x < cells[y].count {
        let kind = cells[y][x]
        guard let fill = colors[kind] else { x += 1; continue }
        var run = 1
        while x + run < cells[y].count, cells[y][x + run] == kind { run += 1 }
        svg += "<rect x=\"\(x * cell)\" y=\"\(y * cell)\" width=\"\(run * cell)\" height=\"\(cell)\" fill=\"\(fill)\"/>\n"
        x += run
    }
}
svg += "</svg>\n"

// MARK: PNG

func color(_ hex: String) -> CGColor {
    let v = Int(hex.dropFirst(), radix: 16)!
    return CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

func renderPNG(pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / CGFloat(size)
    ctx.scaleBy(x: scale, y: scale)
    // Flip to SVG's top-left origin.
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setShouldAntialias(true)
    let bg = CGRect(x: bgInset, y: bgInset, width: size - 2 * bgInset, height: size - 2 * bgInset)
    ctx.addPath(CGPath(roundedRect: bg, cornerWidth: CGFloat(bgRadius), cornerHeight: CGFloat(bgRadius), transform: nil))
    ctx.setFillColor(color(background))
    ctx.fillPath()
    ctx.setShouldAntialias(false)
    for y in cells.indices {
        for x in cells[y].indices {
            guard let fill = colors[cells[y][x]] else { continue }
            ctx.setFillColor(color(fill))
            ctx.fill(CGRect(x: x * cell, y: y * cell, width: cell, height: cell))
        }
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

// MARK: Write

let fm = FileManager.default
let assets = URL(fileURLWithPath: "assets")
try fm.createDirectory(at: assets, withIntermediateDirectories: true)
try svg.write(to: assets.appendingPathComponent("logo.svg"), atomically: true, encoding: .utf8)
try renderPNG(pixels: 1024).write(to: assets.appendingPathComponent("logo.png"))

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try renderPNG(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try renderPNG(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote assets/logo.svg, assets/logo.png, assets/AppIcon.icns")
