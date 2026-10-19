#!/usr/bin/env swift
import AppKit

// Draw the source with AppKit, then write PNG-backed ICNS chunks directly.
// This needs no iconutil helper service or intermediate iconset directory.
guard CommandLine.arguments.count == 3 else {
    fputs("用法：make-icon.swift <输出 PNG 路径> <输出 ICNS 路径>\n", stderr)
    exit(1)
}

let dimension = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: dimension,
    pixelsHigh: dimension,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("无法创建图标画布。\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
context.shouldAntialias = true
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: CGFloat(dimension), height: CGFloat(dimension)).fill()

let background = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 202, yRadius: 202)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.40, blue: 0.95, alpha: 1),
    NSColor(calibratedRed: 0.42, green: 0.25, blue: 0.88, alpha: 1)
])!
gradient.draw(in: background, angle: -38)

NSGraphicsContext.saveGraphicsState()
background.addClip()
NSColor.white.withAlphaComponent(0.14).setFill()
NSBezierPath(ovalIn: NSRect(x: 130, y: 620, width: 620, height: 520)).fill()
NSGraphicsContext.restoreGraphicsState()

// Two offset sheets retain a readable translation mark even at menu/Dock sizes.
let backSheet = NSBezierPath(roundedRect: NSRect(x: 204, y: 350, width: 390, height: 420), xRadius: 54, yRadius: 54)
NSColor.white.withAlphaComponent(0.15).setFill()
backSheet.fill()
NSColor.white.withAlphaComponent(0.65).setStroke()
backSheet.lineWidth = 18
backSheet.stroke()

let frontSheet = NSBezierPath(roundedRect: NSRect(x: 430, y: 254, width: 390, height: 420), xRadius: 54, yRadius: 54)
NSColor(calibratedRed: 0.36, green: 0.32, blue: 0.91, alpha: 1).setFill()
frontSheet.fill()
NSColor.white.setStroke()
frontSheet.lineWidth = 18
frontSheet.stroke()

func drawGlyph(_ text: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white
    ]
    let glyph = NSAttributedString(string: text, attributes: attributes)
    let measured = glyph.size()
    glyph.draw(at: NSPoint(x: rect.midX - measured.width / 2, y: rect.midY - measured.height / 2))
}

drawGlyph("A", in: NSRect(x: 209, y: 427, width: 245, height: 270), size: 212, weight: .semibold)
drawGlyph("文", in: NSRect(x: 452, y: 305, width: 346, height: 312), size: 240, weight: .medium)

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("无法编码图标。\n", stderr)
    exit(1)
}

enum IconError: Error { case bitmapAllocation, pngEncoding, unreadableICNS }

func resizedPNG(_ size: Int) throws -> Data {
    if size == dimension { return png }
    guard let source = bitmap.cgImage,
          let resized = NSBitmapImageRep(
              bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
              isPlanar: false, colorSpaceName: .deviceRGB,
              bytesPerRow: 0, bitsPerPixel: 0
          ), let resizedContext = NSGraphicsContext(bitmapImageRep: resized) else {
        throw IconError.bitmapAllocation
    }
    resizedContext.cgContext.interpolationQuality = .high
    resizedContext.cgContext.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let data = resized.representation(using: .png, properties: [:]) else { throw IconError.pngEncoding }
    return data
}

func bigEndianLength(_ length: Int) -> Data {
    var value = UInt32(length).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}

do {
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    // Standard 1x representations, followed by the Retina representations.
    // Every length includes its eight-byte type/length header, in network order.
    let representations: [(String, Int)] = [
        ("icp4", 16), ("icp5", 32), ("icp6", 64),
        ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024),
        ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)
    ]
    var chunks = Data()
    var encodedSizes: [Int: Data] = [:]
    for (type, size) in representations {
        let data: Data
        if let cached = encodedSizes[size] {
            data = cached
        } else {
            data = try resizedPNG(size)
            encodedSizes[size] = data
        }
        chunks.append(Data(type.utf8))
        chunks.append(bigEndianLength(data.count + 8))
        chunks.append(data)
    }
    var icns = Data("icns".utf8)
    icns.append(bigEndianLength(chunks.count + 8))
    icns.append(chunks)
    let icnsPath = CommandLine.arguments[2]
    try icns.write(to: URL(fileURLWithPath: icnsPath), options: .atomic)
    guard let decoded = NSImage(contentsOfFile: icnsPath), decoded.isValid else { throw IconError.unreadableICNS }
    print("已生成 PNG 与 ICNS（\(representations.count) 个尺寸表示，NSImage 解码验证通过）。")
} catch {
    fputs("无法写入图标：\(error.localizedDescription)\n", stderr)
    exit(1)
}
