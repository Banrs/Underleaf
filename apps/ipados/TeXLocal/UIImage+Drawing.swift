import UIKit

extension UIImage {
    /// The core's SVG at its size in points, drawn sharp at the screen's scale. UIKit reads no SVG, so this reads what RaTeX
    /// writes (`math_svg`, `glyph_svg`): paths of absolute M, L, Q, C and Z, rects, lines and a translating group. All is
    /// drawn black, to be tinted as a template: `withRenderingMode(.alwaysTemplate)`, or SwiftUI's `.renderingMode(.template)`.
    convenience init?(drawing: Syntax.Drawing) {
        guard let svg = drawing.svg, let width = drawing.width, let height = drawing.height, width > 0, height > 0,
              let viewBox = SVGShapes(svg) else { return nil }
        let format = UIGraphicsImageRendererFormat.preferred()
        // Unspecified outside a view's update: every iPad's screen is 2×.
        format.scale = UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 2
        let drawn = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            let cg = context.cgContext
            cg.scaleBy(x: width / viewBox.size.width, y: height / viewBox.size.height)
            cg.translateBy(x: -viewBox.origin.x, y: -viewBox.origin.y)
            UIColor.black.set()
            viewBox.draw(in: cg)
        }
        guard let image = drawn.cgImage else { return nil }
        self.init(cgImage: image, scale: format.scale, orientation: .up)
    }
}

/// RaTeX's SVG as Core Graphics shapes.
private struct SVGShapes {
    var origin = CGPoint.zero, size = CGSize.zero
    private var fills: [CGPath] = []
    private var strokes: [(path: CGPath, width: CGFloat, dash: CGFloat?)] = []

    init?(_ svg: String) {
        var offset = CGPoint.zero
        for tag in svg.split(separator: "<") {
            let name = tag.prefix { $0.isLetter }
            let attributes = Self.attributes(tag)
            let number = { (key: String) in attributes[key].flatMap(Double.init).map { CGFloat($0) } }
            switch name {
            case "svg":
                let box = attributes["viewBox"]?.split(separator: " ").compactMap { Double($0) } ?? []
                guard box.count == 4, box[2] > 0, box[3] > 0 else { return nil }
                (origin, size) = (CGPoint(x: box[0], y: box[1]), CGSize(width: box[2], height: box[3]))
            case "g":
                let moved = attributes["transform"]?.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
                    .split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) } ?? []
                if moved.count == 2 { offset = CGPoint(x: moved[0], y: moved[1]) }
            case "path":
                guard let path = attributes["d"].flatMap({ Self.path($0, offset: offset) }) else { continue }
                if attributes["fill"] == "none" {
                    strokes.append((path, number("stroke-width") ?? 1, nil))
                } else {
                    fills.append(path)
                }
            case "rect":
                guard let x = number("x"), let y = number("y"), let width = number("width"), let height = number("height")
                else { continue }
                fills.append(CGPath(rect: CGRect(x: x + offset.x, y: y + offset.y, width: width, height: height), transform: nil))
            case "line":
                guard let x1 = number("x1"), let y1 = number("y1"), let x2 = number("x2"), let y2 = number("y2") else { continue }
                let line = CGMutablePath()
                line.move(to: CGPoint(x: x1 + offset.x, y: y1 + offset.y))
                line.addLine(to: CGPoint(x: x2 + offset.x, y: y2 + offset.y))
                let dash = attributes["stroke-dasharray"]?.split(separator: " ").first.flatMap { Double($0) }.map { CGFloat($0) }
                strokes.append((line, number("stroke-width") ?? 1, dash))
            default: continue
            }
        }
        guard size != .zero else { return nil }
    }

    func draw(in context: CGContext) {
        for path in fills {
            context.addPath(path)
            context.fillPath(using: .winding)
        }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            context.setLineWidth(stroke.width)
            context.setLineDash(phase: 0, lengths: stroke.dash.map { [$0, $0] } ?? [])
            context.addPath(stroke.path)
            context.strokePath()
        }
    }

    /// `key="value"` pairs; RaTeX escapes no quote inside a value.
    private static func attributes(_ tag: Substring) -> [String: String] {
        var found: [String: String] = [:]
        let parts = tag.split(separator: "\"", omittingEmptySubsequences: false)
        for i in stride(from: 0, to: parts.count - 1, by: 2) {
            let key = parts[i].split(whereSeparator: \.isWhitespace).last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "=")) }
            if let key { found[key] = String(parts[i + 1]) }
        }
        return found
    }

    /// Absolute commands, each letter followed by its numbers.
    private static func path(_ d: String, offset: CGPoint) -> CGPath? {
        let path = CGMutablePath()
        var command: Character = " ", numbers: [CGFloat] = []
        func flush() {
            let p = stride(from: 0, to: numbers.count - 1, by: 2).map { CGPoint(x: numbers[$0] + offset.x, y: numbers[$0 + 1] + offset.y) }
            switch (command, p.count) {
            case ("M", 1...): path.move(to: p[0]); p.dropFirst().forEach { path.addLine(to: $0) }
            case ("L", 1...): p.forEach { path.addLine(to: $0) }
            case ("Q", 2): path.addQuadCurve(to: p[1], control: p[0])
            case ("C", 3): path.addCurve(to: p[2], control1: p[0], control2: p[1])
            case ("Z", _): path.closeSubpath()
            default: break
            }
            numbers = []
        }
        var token = ""
        for character in d + " " {
            if character.isLetter && character != "e" {
                if let value = Double(token) { numbers.append(CGFloat(value)) }
                token = ""
                flush()
                command = character
            } else if character == " " || character == "," {
                if let value = Double(token) { numbers.append(CGFloat(value)) }
                token = ""
            } else {
                token.append(character)
            }
        }
        flush()
        return path.isEmpty ? nil : path
    }
}
