import Testing
import Foundation
@testable import GCodeKit

@Test func parsesModalMovesAndUnits() {
    let program = GCodeParser().parse("G21 G90\nG0 X10 Y20 Z5\nG1 Z0\nX20 Y30\n")
    #expect(program.segments.count == 3)
    #expect(program.bounds?.maximum == Point3D(x: 20, y: 30, z: 5))
    #expect(program.zLevels == [0, 5])
}

@Test func resolvesPreviewModes() {
    let two = GCodeParser().parse("G0 Z5\nG1 Z0 X10\n")
    #expect(two.resolvedPreviewMode(for: DeviceProfile()) == .twoD)
    let three = GCodeParser().parse("G1 Z0 X1\nG1 Z1 X2\nG1 Z2 X3\n")
    #expect(three.resolvedPreviewMode(for: DeviceProfile()) == .threeD)
}

@Test func validatesBounds() {
    let program = GCodeParser().parse("G1 X301 Y10\n")
    let report = program.compatibility(with: DeviceProfile(maximum: .init(x: 300, y: 300, z: 10)))
    #expect(!report.canSend)
    #expect(report.errors.first?.contains("X range") == true)
}

@Test func convertsSVGPrimitives() throws {
    let svg = #"<svg xmlns="http://www.w3.org/2000/svg"><rect x="10" y="20" width="30" height="40"/><path d="M 0 0 L 5 5 L 10 0 Z"/></svg>"#
    let gcode = try SVGConverter().convert(data: Data(svg.utf8))
    let program = GCodeParser().parse(gcode)
    #expect(gcode.contains("G0 Z5.0"))
    #expect(program.segments.count > 5)
    #expect(program.bounds?.maximum.x == 40)
}

@Test func plotterCompletionRaisesPenBeforeHome() {
    let program = GCodeParser().parse("G0 Z5\nG1 Z0 X20 Y30\n")
    let profile = DeviceProfile(maximum: .init(x: 300, y: 300, z: 10), previewMode: .twoD, zeroIsDraw: true)
    #expect(program.completionCommands(for: profile) == ["G21", "G90", "G0 Z5.000", "G0 X0.000 Y0.000"])
}

@Test func printerCompletionAddsClampedClearanceBeforeHome() {
    let program = GCodeParser().parse("G1 X20 Y30 Z195\n")
    let profile = DeviceProfile(minimum: .init(x: 0, y: 0, z: 0), maximum: .init(x: 220, y: 220, z: 200), previewMode: .threeD)
    #expect(program.completionCommands(for: profile) == ["G21", "G90", "G0 Z200.000", "G0 X0.000 Y0.000"])
}

@Test func slicesSVGToPhysicalSizeAndPausesBetweenColors() throws {
    let svg = #"<svg><line stroke="red" x1="10" y1="20" x2="30" y2="20"/><line stroke="blue" x1="10" y1="30" x2="30" y2="30"/></svg>"#
    let data = Data(svg.utf8), info = try SVGConverter().inspect(data: data)
    #expect(info.colors == ["red", "blue"])
    let options = SVGConversionOptions(targetWidth: 100, targetHeight: 50, originX: 5, originY: 10,
        preserveAspectRatio: false, pauseBetweenColors: true, homeX: 0, homeY: 0)
    let gcode = try SVGConverter().convert(data: data, options: options)
    #expect(gcode.contains("G0 X5.000 Y10.000"))
    #expect(gcode.contains("G1 X105.000 Y10.000"))
    #expect(gcode.contains("G0 X0.000 Y0.000\n; Change color: red -> blue\nM0"))
}

@Test func limitsDiagonalSVGMoveForIndependentAxisSpeeds() throws {
    let svg = #"<svg><line x1="0" y1="0" x2="100" y2="100"/></svg>"#
    let options = SVGConversionOptions(maxFeedX: 1_000, maxFeedY: 500, maxFeedZ: 100)
    let gcode = try SVGConverter().convert(data: Data(svg.utf8), options: options)
    #expect(gcode.contains("G0 Z5.000 F100.000"))
    #expect(gcode.contains("G1 X100.000 Y100.000 F707.107"))
}

@Test func slicedSVGUsesProfilePenUpEndpoint() throws {
    let profile = DeviceProfile(minimum: .init(x: 0, y: 0, z: 0), maximum: .init(x: 242.5, y: 293, z: 10),
        previewMode: .twoD, zeroIsDraw: true)
    let svg = #"<svg><line x1="0" y1="0" x2="10" y2="10"/><line x1="20" y1="20" x2="30" y2="30"/></svg>"#
    let gcode = try SVGConverter().convert(data: Data(svg.utf8), drawZ: profile.plotterDrawZ, travelZ: profile.plotterPenUpZ)
    #expect(profile.plotterDrawZ == 0)
    #expect(profile.plotterPenUpZ == 10)
    #expect(gcode.components(separatedBy: "G0 Z10.000").count == 4) // initial lift plus one after each path
    #expect(gcode.components(separatedBy: "G1 Z0.000").count == 3)
}
