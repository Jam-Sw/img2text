import CoreGraphics
import Foundation
import ImageIO

enum Mode: String, CaseIterable {
    case ascii, half, quad, sextant, braille, pixel

    var cell: (w: Int, h: Int) {
        switch self {
        case .ascii, .half, .pixel: return (1, 2)
        case .quad: return (2, 2)
        case .sextant: return (2, 3)
        case .braille: return (2, 4)
        }
    }
}

enum Dither: String, CaseIterable {
    case none, floyd, atkinson, bayer
}

struct Options {
    var mode: Mode = .braille
    var width = 128
    var invert = false

    /// 0, 90, 180, 270
    var rotate = 0
    var dither: Dither = .floyd
    /// error-diffusion strength, 0 = plain threshold, 1 = full diffusion
    var strength = 1.0
    var threshold = 128
    /// ascii "gray ramp"
    var chars = " .:-=+*#%@"
    // tint characters
    var color = true
}

struct RGB: Equatable { var r: UInt8, g: UInt8, b: UInt8 }

struct Cell {
    var ch: Character
    var color: RGB
    var bg: RGB? = nil
}

struct Rendering {
    var rows: [[Cell]]

    var plain: String { rows.map { String($0.map(\.ch)) }.joined(separator: "\n") }

    /// 24 bit ANSI
    var ansi: String {
        var out = ""
        for row in rows {
            var last: RGB? = nil, lastBg: RGB? = nil
            for c in row {
                if let bg = c.bg, c.color != last || bg != lastBg {
                    out += "\u{1B}[38;2;\(c.color.r);\(c.color.g);\(c.color.b);48;2;\(bg.r);\(bg.g);\(bg.b)m"
                    last = c.color
                    lastBg = bg
                } else if c.bg == nil, c.ch != " ", c.color != last {
                    out += "\u{1B}[38;2;\(c.color.r);\(c.color.g);\(c.color.b)m"
                    last = c.color
                }
                out.append(c.ch)
            }
            out += "\u{1B}[0m\n"
        }
        return out
    }
}

private let quad = Array(" ▘▝▀▖▌▞▛▗▚▐▜▄▙▟█")
private let brailleBits: [(dx: Int, dy: Int, bit: UInt32)] = [
    (0, 0, 0x01), (0, 1, 0x02), (0, 2, 0x04), (1, 0, 0x08),
    (1, 1, 0x10), (1, 2, 0x20), (0, 3, 0x40), (1, 3, 0x80),
]

private func sextantChar(_ bits: Int) -> Character {
    switch bits {
    case 0: return " "
    case 21: return "▌"
    case 42: return "▐"
    case 63: return "█"
    default:
        let skip = (bits > 21 ? 1 : 0) + (bits > 42 ? 1 : 0)
        return Character(UnicodeScalar(0x1FB00 + bits - 1 - skip)!)
    }
}

enum RenderError: Error, CustomStringConvertible {
    case cannotLoad(String)
    var description: String {
        switch self { case .cannotLoad(let p): return "cannot load image: \(p)" }
    }
}

let maxWidth = 1000
let maxRows = 1000

final class Source {
    let count: Int
    let delays: [Double]
    let size: (w: Int, h: Int)
    private let src: CGImageSource

    init(_ path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0
        else { throw RenderError.cannotLoad(path) }
        self.src = src
        count = CGImageSourceGetCount(src)
        size = (w, h)
        delays = (0..<count).map { i in
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime] ?? gif?[kCGImagePropertyGIFDelayTime]) as? Double ?? 0
            return d < 0.02 ? 0.1 : d
        }
    }

    func image(_ i: Int, maxPixel: Int) -> CGImage? {
        let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
                    kCGImageSourceShouldCache: false] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(src, i, opts)
    }

    func render(_ i: Int, _ o: Options) -> Rendering? {
        let (cols, rows) = grid(o, w: size.w, h: size.h)
        let (cw, ch) = o.mode.cell
        guard let img = image(i, maxPixel: 2 * max(cols * cw, rows * ch)) else { return nil }
        return img2text.render(img, o)
    }
}

func grid(_ o: Options, w: Int, h: Int) -> (cols: Int, rows: Int) {
    let cols = min(max(1, o.width), maxWidth)
    let (iw, ih) = o.rotate % 180 == 0 ? (w, h) : (h, w)
    let rows = Int((Double(ih) / Double(iw) * Double(cols) / 2).rounded())
    return (cols, min(max(1, rows), maxRows))
}


struct Gray {
    let w: Int, h: Int
    var px: [UInt8]
    var rgb: [RGB]
    subscript(x: Int, y: Int) -> UInt8 { px[y * w + x] }
    func color(_ x: Int, _ y: Int) -> RGB { rgb[y * w + x] }
}

private func resample(_ img: CGImage, to w: Int, _ h: Int, rotate: Int) -> Gray {
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: -CGFloat(rotate) * .pi / 180)
        let (dw, dh) = rotate % 180 == 0 ? (w, h) : (h, w)
        ctx.draw(img, in: CGRect(x: -CGFloat(dw) / 2, y: -CGFloat(dh) / 2, width: CGFloat(dw), height: CGFloat(dh)))
    }
    var px = [UInt8](repeating: 0, count: w * h)
    var rgb = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            let d = y * w + x, s = d * 4
            let r = buf[s], g = buf[s + 1], b = buf[s + 2]
            rgb[d] = RGB(r: r, g: g, b: b)
            px[d] = UInt8((299 * Int(r) + 587 * Int(g) + 114 * Int(b)) / 1000)
        }
    }
    return Gray(w: w, h: h, px: px, rgb: rgb)
}

private let floydKernel: [(Int, Int, Float)] = [(1, 0, 7 / 16), (-1, 1, 3 / 16), (0, 1, 5 / 16), (1, 1, 1 / 16)]
private let atkinsonKernel: [(Int, Int, Float)] = [(1, 0, 1 / 8), (2, 0, 1 / 8), (-1, 1, 1 / 8), (0, 1, 1 / 8), (1, 1, 1 / 8), (0, 2, 1 / 8)]
private let bayer4: [Float] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]

private func binarize(_ g: inout Gray, _ o: Options) {
    let w = g.w, h = g.h
    let t = Float(o.threshold)
    switch o.dither {
    case .none:
        for i in g.px.indices { g.px[i] = Float(g.px[i]) >= t ? 255 : 0 }
    case .bayer:
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let offset = (bayer4[(y & 3) * 4 + (x & 3)] / 16 - 0.5) * 255 * Float(o.strength)
                g.px[i] = Float(g.px[i]) >= t + offset ? 255 : 0
            }
        }
    case .floyd, .atkinson:
        let kernel = o.dither == .floyd ? floydKernel : atkinsonKernel
        let k = Float(o.strength)
        var err = g.px.map { Float($0) }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let old = err[i]
                let new: Float = old < t ? 0 : 255
                g.px[i] = UInt8(new)
                let e = (old - new) * k
                for (dx, dy, wt) in kernel {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, nx < w, ny < h { err[ny * w + nx] += e * wt }
                }
            }
        }
    }
}

func render(_ img: CGImage, _ o: Options) -> Rendering {
    let (cw, ch_) = o.mode.cell
    let (cols, rows) = grid(o, w: img.width, h: img.height)
    var g = resample(img, to: cols * cw, rows * ch_, rotate: o.rotate)
    let tiles = o.mode == .pixel && o.color
    if o.invert {
        g.px = g.px.map { 255 - $0 }
        if tiles { g.rgb = g.rgb.map { RGB(r: 255 - $0.r, g: 255 - $0.g, b: 255 - $0.b) } }
    }
    if o.mode != .ascii && !tiles { binarize(&g, o) }
    let ramp = Array(o.chars.isEmpty ? " .:-=+*#%@" : o.chars)

    let black = RGB(r: 0, g: 0, b: 0)
    var out: [[Cell]] = []
    out.reserveCapacity(rows)
    for r in 0..<rows {
        var line: [Cell] = []
        line.reserveCapacity(cols)
        for c in 0..<cols {
            let x0 = c * cw, y0 = r * ch_
            // on = dark
            func on(_ dx: Int, _ dy: Int) -> Bool { g[x0 + dx, y0 + dy] == 0 }
            let glyph: Character
            switch o.mode {
            case .ascii:
                let v = (Int(g[x0, y0]) + Int(g[x0, y0 + 1])) / 2
                glyph = ramp[(255 - v) * ramp.count / 256]
            case .half, .pixel:
                glyph = Array(" ▀▄█")[(on(0, 0) ? 1 : 0) | (on(0, 1) ? 2 : 0)]
            case .quad:
                glyph = quad[(on(0, 0) ? 1 : 0) | (on(1, 0) ? 2 : 0) | (on(0, 1) ? 4 : 0) | (on(1, 1) ? 8 : 0)]
            case .sextant:
                var bits = 0
                for i in 0..<6 where on(i % 2, i / 2) { bits |= 1 << i }
                glyph = sextantChar(bits)
            case .braille:
                var v: UInt32 = 0x2800
                for b in brailleBits where on(b.dx, b.dy) { v |= b.bit }
                glyph = Character(UnicodeScalar(v)!)
            }
            if tiles {
                line.append(Cell(ch: "▀", color: g.color(x0, y0), bg: g.color(x0, y0 + 1)))
                continue
            }
            var color = black
            if o.color {
                var sr = 0, sg = 0, sb = 0, n = 0
                for dy in 0..<ch_ {
                    for dx in 0..<cw where o.mode == .ascii || on(dx, dy) {
                        let p = g.color(x0 + dx, y0 + dy)
                        sr += Int(p.r); sg += Int(p.g); sb += Int(p.b); n += 1
                    }
                }
                if n > 0 { color = RGB(r: UInt8(sr / n), g: UInt8(sg / n), b: UInt8(sb / n)) }
            }
            line.append(Cell(ch: glyph, color: color))
        }
        if o.mode != .braille {
            while line.last?.ch == " " { line.removeLast() }
        }
        out.append(line)
    }
    return Rendering(rows: out)
}
