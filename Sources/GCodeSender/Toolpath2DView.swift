import SwiftUI
import GCodeKit

struct Toolpath2DView: View {
    let program: GCodeProgram
    let profile: DeviceProfile
    @State private var zoom = 1.0
    @State private var steadyZoom = 1.0
    @State private var offset = CGSize.zero
    @State private var steadyOffset = CGSize.zero

    var body: some View {
        Canvas { context, size in
            guard let bounds = program.bounds else { return }
            let width = max(bounds.size.x, 1), height = max(bounds.size.y, 1)
            let fit = min((size.width - 48) / width, (size.height - 48) / height)
            var transform = CGAffineTransform(translationX: size.width / 2 + offset.width, y: size.height / 2 + offset.height)
            transform = transform.scaledBy(x: fit * zoom, y: -fit * zoom)
            transform = transform.translatedBy(x: -(bounds.minimum.x + width / 2), y: -(bounds.minimum.y + height / 2))

            var travel = Path(), draw = Path()
            for segment in program.segments {
                let a = CGPoint(x: segment.start.x, y: segment.start.y).applying(transform)
                let b = CGPoint(x: segment.end.x, y: segment.end.y).applying(transform)
                if program.isDrawing(segment, profile: profile) { draw.move(to: a); draw.addLine(to: b) }
                else { travel.move(to: a); travel.addLine(to: b) }
            }
            context.stroke(travel, with: .color(.secondary.opacity(0.25)), style: .init(lineWidth: 1, dash: [4, 4]))
            context.stroke(draw, with: .color(.accentColor), lineWidth: 1.5)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottomTrailing) { Text("Pinch to zoom · Drag to pan").font(.caption).foregroundStyle(.secondary).padding(10) }
        .gesture(MagnificationGesture().onChanged { zoom = min(max(steadyZoom * $0, 0.2), 20) }.onEnded { _ in steadyZoom = zoom })
        .simultaneousGesture(DragGesture().onChanged { offset = CGSize(width: steadyOffset.width + $0.translation.width, height: steadyOffset.height + $0.translation.height) }.onEnded { _ in steadyOffset = offset })
    }
}
