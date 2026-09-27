import CoreGraphics
import CoreText

final class Rasterizer {
    struct Style {
        var fg: CGColor
        var bg: CGColor
        var scale: CGFloat
    }

    private let font: CTFont
    private let cellW: CGFloat, cellH: CGFloat, ascent: CGFloat
    private let pad: CGFloat = 8
    private var glyphs: [Character: (font: CTFont, glyph: CGGlyph)?] = [:]

    init(font: CTFont) {
        self.font = font
        var m: UniChar = 77, g = CGGlyph()  // "M"
        CTFontGetGlyphsForCharacters(font, &m, &g, 1)
        cellW = CTFontGetAdvancesForGlyphs(font, .horizontal, &g, nil, 1)
        ascent = CTFontGetAscent(font)
        cellH = ceil(ascent + CTFontGetDescent(font) + CTFontGetLeading(font))
    }

    private func glyph(_ c: Character) -> (font: CTFont, glyph: CGGlyph)? {
        if let hit = glyphs[c] { return hit }
        let s = String(c)
        let f = CTFontCreateForString(font, s as CFString, CFRange(location: 0, length: s.utf16.count))
        var units = Array(s.utf16), gs = [CGGlyph](repeating: 0, count: units.count)
        let found = CTFontGetGlyphsForCharacters(f, &units, &gs, units.count) ? (f, gs[0]) : nil
        glyphs[c] = found
        return found
    }

    func draw(_ r: Rendering, color: Bool, _ style: Style) -> CGImage? {
        let cols = r.rows.map(\.count).max() ?? 0
        let w = (CGFloat(cols) * cellW + pad * 2), h = (CGFloat(r.rows.count) * cellH + pad * 2)
        guard let ctx = CGContext(data: nil, width: max(1, Int(w * style.scale)), height: max(1, Int(h * style.scale)),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: style.scale, y: style.scale)
        ctx.setFillColor(style.bg)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(style.fg)
        var last: RGB? = nil
        for (ri, row) in r.rows.enumerated() {
            let baseline = h - pad - CGFloat(ri) * cellH - ascent
            for (ci, cell) in row.enumerated() where cell.ch != " " && cell.ch != "\u{2800}" {
                if let bg = cell.bg {
                    let x = pad + CGFloat(ci) * cellW, top = h - pad - CGFloat(ri) * cellH
                    ctx.setShouldAntialias(false)
                    defer { ctx.setShouldAntialias(true) }
                    ctx.setFillColor(red: CGFloat(cell.color.r) / 255, green: CGFloat(cell.color.g) / 255, blue: CGFloat(cell.color.b) / 255, alpha: 1)
                    ctx.fill(CGRect(x: x, y: top - cellH / 2, width: cellW, height: cellH / 2))
                    ctx.setFillColor(red: CGFloat(bg.r) / 255, green: CGFloat(bg.g) / 255, blue: CGFloat(bg.b) / 255, alpha: 1)
                    ctx.fill(CGRect(x: x, y: top - cellH, width: cellW, height: cellH / 2))
                    last = nil
                    continue
                }
                guard var g = glyph(cell.ch) else { continue }
                if color, cell.color != last {
                    ctx.setFillColor(red: CGFloat(cell.color.r) / 255, green: CGFloat(cell.color.g) / 255,
                                     blue: CGFloat(cell.color.b) / 255, alpha: 1)
                    last = cell.color
                }
                var pos = CGPoint(x: pad + CGFloat(ci) * cellW, y: baseline)
                CTFontDrawGlyphs(g.font, &g.glyph, &pos, 1, ctx)
            }
        }
        return ctx.makeImage()
    }
}
