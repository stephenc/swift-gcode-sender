import Foundation

public enum SVGConversionError: LocalizedError {
    case invalidDocument, noPaths
    public var errorDescription: String? { self == .invalidDocument ? "The SVG could not be parsed." : "The SVG contains no supported paths or shapes." }
}

public struct SVGInfo: Sendable {
    public let bounds: Bounds3D
    public let colors: [String]
}

public struct SVGConversionOptions: Sendable {
    public var targetWidth: Double?
    public var targetHeight: Double?
    public var originX: Double
    public var originY: Double
    public var preserveAspectRatio: Bool
    public var pauseBetweenColors: Bool
    public var homeX: Double
    public var homeY: Double
    public var maxFeedX: Double?
    public var maxFeedY: Double?
    public var maxFeedZ: Double?

    public init(targetWidth: Double? = nil, targetHeight: Double? = nil, originX: Double = 0, originY: Double = 0,
                preserveAspectRatio: Bool = true, pauseBetweenColors: Bool = true, homeX: Double = 0, homeY: Double = 0,
                maxFeedX: Double? = nil, maxFeedY: Double? = nil, maxFeedZ: Double? = nil) {
        self.targetWidth = targetWidth; self.targetHeight = targetHeight; self.originX = originX; self.originY = originY
        self.preserveAspectRatio = preserveAspectRatio; self.pauseBetweenColors = pauseBetweenColors; self.homeX = homeX; self.homeY = homeY
        self.maxFeedX = maxFeedX; self.maxFeedY = maxFeedY; self.maxFeedZ = maxFeedZ
    }
}

public struct SVGConverter: Sendable {
    public init() {}

    public func inspect(data: Data) throws -> SVGInfo {
        let paths = try parse(data)
        guard let bounds = Bounds3D.enclosing(paths.flatMap { $0.points.map { Point3D(x: $0.x, y: $0.y) } }) else { throw SVGConversionError.noPaths }
        var colors = [String]()
        for path in paths where !colors.contains(path.color) { colors.append(path.color) }
        return .init(bounds: bounds, colors: colors)
    }

    public func convert(data: Data, drawZ: Double = 0, travelZ: Double = 5, options: SVGConversionOptions = .init()) throws -> String {
        let paths = try parse(data)
        guard let bounds = Bounds3D.enclosing(paths.flatMap { $0.points.map { Point3D(x: $0.x, y: $0.y) } }) else { throw SVGConversionError.noPaths }
        let sourceWidth = max(bounds.size.x, 0.0001), sourceHeight = max(bounds.size.y, 0.0001)
        var scaleX = (options.targetWidth ?? sourceWidth) / sourceWidth
        var scaleY = (options.targetHeight ?? sourceHeight) / sourceHeight
        if options.preserveAspectRatio { let scale = min(scaleX, scaleY); scaleX = scale; scaleY = scale }
        let actualWidth = sourceWidth * scaleX, actualHeight = sourceHeight * scaleY
        let offsetX = options.originX + ((options.targetWidth ?? actualWidth) - actualWidth) / 2
        let offsetY = options.originY + ((options.targetHeight ?? actualHeight) - actualHeight) / 2
        func transformed(_ point: CGPoint) -> CGPoint {
            .init(x: offsetX + (point.x - bounds.minimum.x) * scaleX, y: offsetY + (point.y - bounds.minimum.y) * scaleY)
        }

        let zFeed = options.maxFeedZ.map { " F\(fmt($0))" } ?? ""
        func xyFeed(from start: CGPoint, to end: CGPoint) -> String {
            let dx = abs(end.x - start.x), dy = abs(end.y - start.y), distance = hypot(dx, dy)
            guard distance > 0 else { return "" }
            var limits = [Double]()
            if let x = options.maxFeedX, dx > 0 { limits.append(x * distance / dx) }
            if let y = options.maxFeedY, dy > 0 { limits.append(y * distance / dy) }
            return limits.min().map { " F\(fmt($0))" } ?? ""
        }
        var currentXY = CGPoint(x: options.homeX, y: options.homeY)
        var output = ["; Generated from SVG", "G21", "G90", "G0 Z\(fmt(travelZ))\(zFeed)"]
        var previousColor: String?
        let colorOrder = paths.reduce(into: [String]()) { if !$0.contains($1.color) { $0.append($1.color) } }
        let orderedPaths = options.pauseBetweenColors ? colorOrder.flatMap { color in paths.filter { $0.color == color } } : paths
        for path in orderedPaths where path.points.count > 1 {
            if options.pauseBetweenColors, let previousColor, previousColor != path.color {
                let home = CGPoint(x: options.homeX, y: options.homeY)
                output += ["G0 Z\(fmt(travelZ))\(zFeed)", "G0 X\(fmt(home.x)) Y\(fmt(home.y))\(xyFeed(from: currentXY, to: home))", "; Change color: \(previousColor) -> \(path.color)", "M0"]
                currentXY = home
            }
            if previousColor != path.color { output.append("; Color: \(path.color)") }
            previousColor = path.color
            let points = path.points.map(transformed)
            output += ["G0 X\(fmt(points[0].x)) Y\(fmt(points[0].y))\(xyFeed(from: currentXY, to: points[0]))", "G1 Z\(fmt(drawZ))\(zFeed)"]
            currentXY = points[0]
            for point in points.dropFirst() {
                output.append("G1 X\(fmt(point.x)) Y\(fmt(point.y))\(xyFeed(from: currentXY, to: point))"); currentXY = point
            }
            output.append("G0 Z\(fmt(travelZ))\(zFeed)")
        }
        return output.joined(separator: "\n") + "\n"
    }

    private func parse(_ data: Data) throws -> [ColoredPath] {
        let delegate = SVGDelegate(), parser = XMLParser(data: data); parser.delegate = delegate
        guard parser.parse() else { throw SVGConversionError.invalidDocument }
        guard !delegate.paths.isEmpty else { throw SVGConversionError.noPaths }
        return delegate.paths
    }
    private func fmt(_ value: Double) -> String { String(format: "%.3f", value) }
}

private struct ColoredPath { let points: [CGPoint]; let color: String }

private final class SVGDelegate: NSObject, XMLParserDelegate {
    var paths = [ColoredPath]()
    private var colorStack = ["black"]

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String: String]) {
        let element = name.lowercased(), color = effectiveColor(a)
        if element == "svg" || element == "g" { colorStack.append(color) }
        func d(_ key: String) -> Double { Double(a[key] ?? "") ?? 0 }
        func add(_ points: [CGPoint]) { if points.count > 1, color != "none" { paths.append(.init(points: points, color: color)) } }
        switch element {
        case "line": add([.init(x: d("x1"), y: d("y1")), .init(x: d("x2"), y: d("y2"))])
        case "rect":
            let x = d("x"), y = d("y"), w = d("width"), h = d("height")
            add([.init(x: x, y: y), .init(x: x+w, y: y), .init(x: x+w, y: y+h), .init(x: x, y: y+h), .init(x: x, y: y)])
        case "polyline", "polygon":
            var p = parsePoints(a["points"] ?? ""); if element == "polygon", let first = p.first { p.append(first) }; add(p)
        case "circle", "ellipse":
            let cx = d("cx"), cy = d("cy"), rx = element == "circle" ? d("r") : d("rx"), ry = element == "circle" ? d("r") : d("ry")
            add((0...48).map { n in let t = Double(n) / 48 * 2 * Double.pi; return CGPoint(x: cx + cos(t)*rx, y: cy + sin(t)*ry) })
        case "path": parsePath(a["d"] ?? "").forEach(add)
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = name.lowercased(); if (element == "svg" || element == "g"), colorStack.count > 1 { colorStack.removeLast() }
    }

    private func effectiveColor(_ a: [String: String]) -> String {
        var style = [String: String]()
        for item in (a["style"] ?? "").split(separator: ";") {
            let p = item.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if p.count == 2 { style[p[0].lowercased()] = p[1] }
        }
        let stroke = a["stroke"] ?? style["stroke"], fill = a["fill"] ?? style["fill"]
        if let stroke, stroke.lowercased() != "none" { return normalized(stroke) }
        if let fill, fill.lowercased() != "none" { return normalized(fill) }
        if stroke?.lowercased() == "none", fill?.lowercased() == "none" { return "none" }
        return colorStack.last ?? "black"
    }
    private func normalized(_ color: String) -> String { color.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private func parsePoints(_ value: String) -> [CGPoint] { let n = numbers(value); return stride(from: 0, to: n.count - 1, by: 2).map { CGPoint(x: n[$0], y: n[$0+1]) } }
    private func numbers(_ value: String) -> [Double] {
        let regex = try! NSRegularExpression(pattern: #"[-+]?(?:\d*\.?\d+)(?:[Ee][-+]?\d+)?"#), ns = value as NSString
        return regex.matches(in: value, range: NSRange(location: 0, length: ns.length)).compactMap { Double(ns.substring(with: $0.range)) }
    }

    private func parsePath(_ data: String) -> [[CGPoint]] {
        let regex = try! NSRegularExpression(pattern: #"[MmLlHhVvZz]|[-+]?(?:\d*\.?\d+)(?:[Ee][-+]?\d+)?"#), ns = data as NSString
        let tokens = regex.matches(in: data, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        var results = [[CGPoint]](), current = [CGPoint](), point = CGPoint(x: 0, y: 0), start = CGPoint(x: 0, y: 0), command: Character = "M", i = 0
        func isCommand(_ s: String) -> Bool { s.count == 1 && s.first!.isLetter }
        while i < tokens.count {
            if isCommand(tokens[i]) { command = tokens[i].first!; i += 1; if command == "Z" || command == "z" { current.append(start); point = start; continue } }
            let relative = command.isLowercase
            switch command.uppercased() {
            case "M", "L":
                guard i + 1 < tokens.count, let x = Double(tokens[i]), let y = Double(tokens[i+1]) else { i += 1; continue }
                let next = CGPoint(x: relative ? point.x+x : x, y: relative ? point.y+y : y); i += 2
                if command == "M" || command == "m" { if !current.isEmpty { results.append(current) }; current = []; start = next; command = relative ? "l" : "L" }
                point = next; current.append(point)
            case "H": guard let x = Double(tokens[i]) else { i += 1; continue }; point.x = relative ? point.x+x : x; current.append(point); i += 1
            case "V": guard let y = Double(tokens[i]) else { i += 1; continue }; point.y = relative ? point.y+y : y; current.append(point); i += 1
            default: while i < tokens.count, !isCommand(tokens[i]) { i += 1 }
            }
        }
        if !current.isEmpty { results.append(current) }
        return results
    }
}
