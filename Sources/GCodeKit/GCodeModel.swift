import Foundation

public struct Point3D: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x; self.y = y; self.z = z
    }
}

public enum MotionKind: String, Codable, Sendable { case rapid, linear, clockwiseArc, counterclockwiseArc }

public struct ToolpathSegment: Identifiable, Sendable {
    public let id: Int
    public let start: Point3D
    public let end: Point3D
    public let kind: MotionKind
    public let sourceLine: Int

    public init(id: Int, start: Point3D, end: Point3D, kind: MotionKind, sourceLine: Int) {
        self.id = id; self.start = start; self.end = end; self.kind = kind; self.sourceLine = sourceLine
    }
}

public struct Bounds3D: Equatable, Sendable {
    public var minimum: Point3D
    public var maximum: Point3D
    public var size: Point3D { .init(x: maximum.x - minimum.x, y: maximum.y - minimum.y, z: maximum.z - minimum.z) }

    public init(minimum: Point3D, maximum: Point3D) { self.minimum = minimum; self.maximum = maximum }

    public static func enclosing(_ points: [Point3D]) -> Bounds3D? {
        guard let first = points.first else { return nil }
        return points.dropFirst().reduce(Bounds3D(minimum: first, maximum: first)) { result, point in
            var result = result
            result.minimum.x = min(result.minimum.x, point.x); result.maximum.x = max(result.maximum.x, point.x)
            result.minimum.y = min(result.minimum.y, point.y); result.maximum.y = max(result.maximum.y, point.y)
            result.minimum.z = min(result.minimum.z, point.z); result.maximum.z = max(result.maximum.z, point.z)
            return result
        }
    }
}

public struct GCodeProgram: Sendable {
    public let source: String
    public let lines: [String]
    public let segments: [ToolpathSegment]
    public let bounds: Bounds3D?
    public let zLevels: [Double]
    public let warnings: [String]

    public init(source: String, lines: [String], segments: [ToolpathSegment], warnings: [String]) {
        self.source = source
        self.lines = lines
        self.segments = segments
        self.bounds = Bounds3D.enclosing(segments.flatMap { [$0.start, $0.end] })
        self.zLevels = Array(Set(segments.flatMap { [$0.start.z, $0.end.z] }.map { ($0 * 1_000).rounded() / 1_000 })).sorted()
        self.warnings = warnings
    }
}

public enum PreviewMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case automatic, twoD, threeD
    public var id: Self { self }
    public var title: String { switch self { case .automatic: "Auto"; case .twoD: "2D"; case .threeD: "3D" } }
}

public enum ConnectionKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case serial, fluidNC
    public var id: Self { self }
    public var title: String { self == .serial ? "USB / Serial" : "FluidNC / WebSocket" }
}

public struct DeviceProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var connection: ConnectionKind
    public var serialPath: String
    public var baudRate: Int
    public var webSocketURL: String
    public var deviceIdentifier: String
    public var minimum: Point3D
    public var maximum: Point3D
    public var previewMode: PreviewMode
    public var zeroIsDraw: Bool
    public var maxFeedX: Double?
    public var maxFeedY: Double?
    public var maxFeedZ: Double?

    public init(id: UUID = UUID(), name: String = "New machine", connection: ConnectionKind = .serial,
                serialPath: String = "", baudRate: Int = 115_200, webSocketURL: String = "ws://fluidnc.local/",
                deviceIdentifier: String = "", minimum: Point3D = .init(), maximum: Point3D = .init(x: 300, y: 300, z: 50),
                previewMode: PreviewMode = .automatic, zeroIsDraw: Bool = true,
                maxFeedX: Double? = nil, maxFeedY: Double? = nil, maxFeedZ: Double? = nil) {
        self.id = id; self.name = name; self.connection = connection; self.serialPath = serialPath
        self.baudRate = baudRate; self.webSocketURL = webSocketURL; self.deviceIdentifier = deviceIdentifier
        self.minimum = minimum; self.maximum = maximum; self.previewMode = previewMode; self.zeroIsDraw = zeroIsDraw
        self.maxFeedX = maxFeedX; self.maxFeedY = maxFeedY; self.maxFeedZ = maxFeedZ
    }
}

public struct CompatibilityReport: Sendable {
    public let errors: [String]
    public let warnings: [String]
    public var canSend: Bool { errors.isEmpty }
}

public extension GCodeProgram {
    func resolvedPreviewMode(for profile: DeviceProfile) -> PreviewMode {
        profile.previewMode == .automatic ? (zLevels.count <= 2 ? .twoD : .threeD) : profile.previewMode
    }

    func isDrawing(_ segment: ToolpathSegment, profile: DeviceProfile) -> Bool {
        guard segment.kind != .rapid else { return false }
        if zLevels.count <= 1 { return true }
        let zero = abs(segment.end.z) < 0.0005
        return profile.zeroIsDraw ? zero : !zero
    }

    func compatibility(with profile: DeviceProfile) -> CompatibilityReport {
        var errors = [String](), notes = warnings
        if let b = bounds {
            if b.minimum.x < profile.minimum.x || b.maximum.x > profile.maximum.x { errors.append("X range \(b.minimum.x.formatted())…\(b.maximum.x.formatted()) mm is outside the machine volume.") }
            if b.minimum.y < profile.minimum.y || b.maximum.y > profile.maximum.y { errors.append("Y range \(b.minimum.y.formatted())…\(b.maximum.y.formatted()) mm is outside the machine volume.") }
            if b.minimum.z < profile.minimum.z || b.maximum.z > profile.maximum.z { errors.append("Z range \(b.minimum.z.formatted())…\(b.maximum.z.formatted()) mm is outside the machine volume.") }
        }
        if segments.isEmpty { errors.append("No supported motion commands were found.") }
        if resolvedPreviewMode(for: profile) == .twoD, zLevels.count > 2 { notes.append("This file has \(zLevels.count) Z levels but the profile forces a 2D preview.") }
        return .init(errors: errors, warnings: notes)
    }

    /// Commands appended after a successfully acknowledged job. Z always moves first so the
    /// tool is clear before X/Y return to the profile's minimum (home) corner.
    func completionCommands(for profile: DeviceProfile) -> [String] {
        let safeZ: Double
        if resolvedPreviewMode(for: profile) == .twoD {
            if profile.zeroIsDraw {
                let nonDrawingLevels = zLevels.filter { abs($0) >= 0.0005 }
                safeZ = nonDrawingLevels.max(by: { abs($0) < abs($1) })
                    ?? min(profile.maximum.z, max(profile.minimum.z, 5))
            } else {
                safeZ = min(profile.maximum.z, max(profile.minimum.z, 0))
            }
        } else {
            let toolpathTop = bounds?.maximum.z ?? profile.minimum.z
            safeZ = min(profile.maximum.z, max(profile.minimum.z, toolpathTop + 10))
        }
        func number(_ value: Double) -> String { String(format: "%.3f", value) }
        let zFeed = profile.maxFeedZ.map { " F\(number($0))" } ?? ""
        let xyFeedValue = [profile.maxFeedX, profile.maxFeedY].compactMap { $0 }.min()
        let xyFeed = xyFeedValue.map { " F\(number($0))" } ?? ""
        return [
            "G21",
            "G90",
            "G0 Z\(number(safeZ))\(zFeed)",
            "G0 X\(number(profile.minimum.x)) Y\(number(profile.minimum.y))\(xyFeed)"
        ]
    }
}

public extension DeviceProfile {
    var plotterZeroZ: Double { min(maximum.z, max(minimum.z, 0)) }
    var plotterDrawZ: Double { zeroIsDraw ? plotterZeroZ : maximum.z }
    var plotterPenUpZ: Double { zeroIsDraw ? maximum.z : plotterZeroZ }
}
