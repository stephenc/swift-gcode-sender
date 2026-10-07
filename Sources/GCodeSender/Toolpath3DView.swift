import SwiftUI
import SceneKit
import GCodeKit

struct Toolpath3DView: NSViewRepresentable {
    let program: GCodeProgram
    let profile: DeviceProfile

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(); view.backgroundColor = .controlBackgroundColor; view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true; view.antialiasingMode = .multisampling4X; return view
    }
    func updateNSView(_ view: SCNView, context: Context) { view.scene = makeScene() }

    private func makeScene() -> SCNScene {
        let scene = SCNScene(), root = scene.rootNode
        let drawable = program.segments.filter { $0.kind != .rapid }
        let rapid = program.segments.filter { $0.kind == .rapid }
        root.addChildNode(linesNode(drawable, color: .systemBlue))
        root.addChildNode(linesNode(rapid, color: .tertiaryLabelColor))
        let floor = SCNFloor(); floor.reflectivity = 0; floor.firstMaterial?.diffuse.contents = NSColor.gridColor.withAlphaComponent(0.12)
        root.addChildNode(SCNNode(geometry: floor))
        if let b = program.bounds {
            let center = SCNVector3(Float((b.minimum.x+b.maximum.x)/2), Float((b.minimum.z+b.maximum.z)/2), Float((b.minimum.y+b.maximum.y)/2))
            let span = CGFloat(max(b.size.x, b.size.y, b.size.z, 20))
            let camera = SCNNode(); camera.camera = SCNCamera(); camera.position = SCNVector3(center.x + span, center.y + span, center.z + span); camera.look(at: center); root.addChildNode(camera)
        }
        return scene
    }
    private func linesNode(_ segments: [ToolpathSegment], color: NSColor) -> SCNNode {
        let vertices = segments.flatMap { [SCNVector3(Float($0.start.x), Float($0.start.z), Float($0.start.y)), SCNVector3(Float($0.end.x), Float($0.end.z), Float($0.end.y))] }
        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: Array(0..<vertices.count).map(Int32.init), primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element]); geometry.firstMaterial?.diffuse.contents = color; geometry.firstMaterial?.lightingModel = .constant
        return SCNNode(geometry: geometry)
    }
}
