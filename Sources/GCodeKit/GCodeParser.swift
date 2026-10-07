import Foundation

public struct GCodeParser: Sendable {
    public init() {}

    public func parse(_ source: String) -> GCodeProgram {
        let lines = source.components(separatedBy: .newlines)
        var position = Point3D(), absolute = true, scale = 1.0
        var modalMotion: Int? = nil
        var segments = [ToolpathSegment](), warnings = [String]()

        for (index, raw) in lines.enumerated() {
            let clean = Self.stripComments(raw).uppercased()
            let words = Self.words(in: clean)
            guard !words.isEmpty else { continue }
            let codes = words.filter { $0.0 == "G" }.map { Int($0.1.rounded()) }
            if codes.contains(90) { absolute = true }
            if codes.contains(91) { absolute = false }
            if codes.contains(20) { scale = 25.4 }
            if codes.contains(21) { scale = 1 }
            if let motion = codes.last(where: { (0...3).contains($0) }) { modalMotion = motion }
            guard let motion = modalMotion, words.contains(where: { "XYZ".contains($0.0) }) else { continue }

            var destination = position
            func value(_ letter: Character) -> Double? { words.last(where: { $0.0 == letter })?.1 }
            if let x = value("X") { destination.x = absolute ? x * scale : position.x + x * scale }
            if let y = value("Y") { destination.y = absolute ? y * scale : position.y + y * scale }
            if let z = value("Z") { destination.z = absolute ? z * scale : position.z + z * scale }
            let kind: MotionKind = [0: .rapid, 1: .linear, 2: .clockwiseArc, 3: .counterclockwiseArc][motion] ?? .linear

            if motion == 2 || motion == 3 {
                let i = (value("I") ?? 0) * scale, j = (value("J") ?? 0) * scale
                if i != 0 || j != 0 {
                    let center = Point3D(x: position.x + i, y: position.y + j, z: position.z)
                    let radius = hypot(position.x - center.x, position.y - center.y)
                    let startAngle = atan2(position.y - center.y, position.x - center.x)
                    var sweep = atan2(destination.y - center.y, destination.x - center.x) - startAngle
                    if motion == 2, sweep >= 0 { sweep -= 2 * .pi }
                    if motion == 3, sweep <= 0 { sweep += 2 * .pi }
                    let steps = max(8, Int(abs(sweep) * radius / 1.5))
                    var previous = position
                    for step in 1...steps {
                        let t = Double(step) / Double(steps), angle = startAngle + sweep * t
                        let next = Point3D(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius, z: position.z + (destination.z - position.z) * t)
                        segments.append(.init(id: segments.count, start: previous, end: next, kind: kind, sourceLine: index + 1)); previous = next
                    }
                } else {
                    warnings.append("Line \(index + 1): R-form arcs are shown as straight lines.")
                    segments.append(.init(id: segments.count, start: position, end: destination, kind: kind, sourceLine: index + 1))
                }
            } else if destination != position {
                segments.append(.init(id: segments.count, start: position, end: destination, kind: kind, sourceLine: index + 1))
            }
            position = destination
        }
        return GCodeProgram(source: source, lines: lines, segments: segments, warnings: Array(Set(warnings)).sorted())
    }

    private static func stripComments(_ line: String) -> String {
        var result = "", depth = 0
        for c in line {
            if c == ";", depth == 0 { break }
            if c == "(" { depth += 1; continue }
            if c == ")" { depth = max(0, depth - 1); continue }
            if depth == 0 { result.append(c) }
        }
        return result
    }

    private static func words(in line: String) -> [(Character, Double)] {
        let pattern = #"([A-Z])\s*([-+]?(?:\d*\.?\d+)(?:[Ee][-+]?\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let letter = ns.substring(with: match.range(at: 1)).first,
                  let number = Double(ns.substring(with: match.range(at: 2))) else { return nil }
            return (letter, number)
        }
    }
}
