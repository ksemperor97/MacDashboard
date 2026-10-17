import CoreGraphics
import Foundation

/// Minimal SVG path-data parser (M L H V C S Q T A Z, absolute and relative) producing a CGPath.
enum SVGPath {
    static func parse(_ data: String) -> CGPath {
        let path = CGMutablePath()
        var s = Tokens(Array(data.utf8))
        var command: UInt8 = 0
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?

        while true {
            s.skipSeparators()
            if s.atEnd { break }
            if let c = s.command() {
                command = c
            } else if command == 0 {
                break
            }
            let relative = command >= UInt8(ascii: "a")
            let upper = relative ? command - 32 : command

            func point() -> CGPoint? {
                guard let x = s.number(), let y = s.number() else { return nil }
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            var cubicControl: CGPoint?
            var quadControl: CGPoint?
            switch upper {
            case UInt8(ascii: "M"):
                guard let p = point() else { return path }
                path.move(to: p)
                current = p
                subpathStart = p
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")  // further pairs are line-tos
            case UInt8(ascii: "L"):
                guard let p = point() else { return path }
                path.addLine(to: p)
                current = p
            case UInt8(ascii: "H"):
                guard let x = s.number() else { return path }
                current.x = relative ? current.x + x : x
                path.addLine(to: current)
            case UInt8(ascii: "V"):
                guard let y = s.number() else { return path }
                current.y = relative ? current.y + y : y
                path.addLine(to: current)
            case UInt8(ascii: "C"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                cubicControl = c2
                current = p
            case UInt8(ascii: "S"):
                let c1 = lastCubicControl.map { reflect($0, about: current) } ?? current
                guard let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                cubicControl = c2
                current = p
            case UInt8(ascii: "Q"):
                guard let c = point(), let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                quadControl = c
                current = p
            case UInt8(ascii: "T"):
                let c = lastQuadControl.map { reflect($0, about: current) } ?? current
                guard let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                quadControl = c
                current = p
            case UInt8(ascii: "A"):
                guard let rx = s.number(), let ry = s.number(), let rotation = s.number(),
                      let large = s.flag(), let sweep = s.flag(), let p = point() else { return path }
                addArc(to: path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = p
            case UInt8(ascii: "Z"):
                path.closeSubpath()
                current = subpathStart
            default:
                return path
            }
            lastCubicControl = cubicControl
            lastQuadControl = quadControl
        }
        return path
    }

    private static func reflect(_ p: CGPoint, about c: CGPoint) -> CGPoint {
        CGPoint(x: 2 * c.x - p.x, y: 2 * c.y - p.y)
    }

    /// Elliptical arc as cubic Béziers (SVG spec, endpoint to center parameterization).
    private static func addArc(to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint,
                               rx: CGFloat, ry: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) {
        guard p0 != p1 else { return }
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0 else {
            path.addLine(to: p1)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= sqrt(lambda)
            ry *= sqrt(lambda)
        }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = den == 0 ? 0 : sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry
        let cyp = -coef * ry * x1 / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(Int(ceil(abs(delta) / (.pi / 2))), 1)
        let step = delta / CGFloat(segments)
        let k = 4 / 3 * tan(step / 4)
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cosPhi * x - ry * sinPhi * y, y: cy + rx * sinPhi * x + ry * cosPhi * y)
        }
        for i in 0..<segments {
            let a1 = theta1 + CGFloat(i) * step
            let a2 = a1 + step
            let c1 = map(cos(a1) - k * sin(a1), sin(a1) + k * cos(a1))
            let c2 = map(cos(a2) + k * sin(a2), sin(a2) - k * cos(a2))
            path.addCurve(to: i == segments - 1 ? p1 : map(cos(a2), sin(a2)), control1: c1, control2: c2)
        }
    }

    /// Reads numbers and flags the way SVG allows them to be packed (".5.5", "-1-2", "00").
    private struct Tokens {
        let bytes: [UInt8]
        var i = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { i >= bytes.count }

        mutating func skipSeparators() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: ",")].contains(bytes[i]) { i += 1 }
        }

        mutating func command() -> UInt8? {
            skipSeparators()
            guard i < bytes.count else { return nil }
            let c = bytes[i]
            let isLetter = (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
            guard isLetter, c != UInt8(ascii: "e"), c != UInt8(ascii: "E") else { return nil }
            i += 1
            return c
        }

        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "0") || bytes[i] == UInt8(ascii: "1") else { return nil }
            defer { i += 1 }
            return bytes[i] == UInt8(ascii: "1")
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let start = i
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") { i += 1 }
            var sawDigit = false, sawDot = false
            while i < bytes.count {
                let c = bytes[i]
                if c >= 48 && c <= 57 {
                    sawDigit = true
                } else if c == UInt8(ascii: "."), !sawDot {
                    sawDot = true
                } else {
                    break
                }
                i += 1
            }
            if sawDigit, i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") { i += 1 }
                while i < bytes.count, bytes[i] >= 48 && bytes[i] <= 57 { i += 1 }
            }
            guard sawDigit, let value = Double(String(decoding: bytes[start..<i], as: UTF8.self)) else {
                i = start
                return nil
            }
            return CGFloat(value)
        }
    }
}
