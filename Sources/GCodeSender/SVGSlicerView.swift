import SwiftUI
import GCodeKit

struct SVGSlicerView: View {
    @State var request: SVGImportRequest
    let profile: DeviceProfile
    let onCancel: () -> Void
    let onSlice: (SVGImportRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "scalemass").font(.title)
                VStack(alignment: .leading) {
                    Text("SVG Slicer").font(.title2.bold())
                    Text("Size and prepare \(request.name) for \(profile.name)").foregroundStyle(.secondary)
                }
            }
            Form {
                Section("Physical size (mm)") {
                    HStack {
                        TextField("Width", value: $request.targetWidth, format: .number.precision(.fractionLength(1))).frame(width: 120)
                        Text("×")
                        TextField("Height", value: $request.targetHeight, format: .number.precision(.fractionLength(1))).frame(width: 120)
                        Spacer()
                        Button("Fit workspace") { fitWorkspace() }
                    }
                    Toggle("Preserve aspect ratio", isOn: $request.preserveAspectRatio)
                    Text("Original artwork: \(request.sourceWidth.formatted()) × \(request.sourceHeight.formatted()) units")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Placement (mm)") {
                    HStack {
                        TextField("X origin", value: $request.originX, format: .number.precision(.fractionLength(1))).frame(width: 140)
                        TextField("Y origin", value: $request.originY, format: .number.precision(.fractionLength(1))).frame(width: 140)
                    }
                }
                Section("Colors") {
                    Toggle("Return home and pause between colors", isOn: $request.pauseBetweenColors)
                    HStack(spacing: 7) {
                        ForEach(request.colors, id: \.self) { color in
                            Text(color).font(.caption.monospaced()).padding(.horizontal, 7).padding(.vertical, 4).background(.quaternary, in: Capsule())
                        }
                    }
                    Text("\(request.colors.count) color\(request.colors.count == 1 ? "" : "s") detected")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Maximum feed (mm/min)") {
                    HStack {
                        TextField("X", value: $request.maxFeedX, format: .number.precision(.fractionLength(0...1)))
                        TextField("Y", value: $request.maxFeedY, format: .number.precision(.fractionLength(0...1)))
                        TextField("Z", value: $request.maxFeedZ, format: .number.precision(.fractionLength(0...1)))
                    }
                    Text("Diagonal feed is limited so neither X nor Y exceeds its maximum; Z uses its own rate.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Slice SVG") { onSlice(request) }.buttonStyle(.borderedProminent)
                    .disabled(request.targetWidth <= 0 || request.targetHeight <= 0)
            }
        }.padding(22).frame(width: 560, height: 620)
    }

    private func fitWorkspace() {
        let width = max(1, profile.maximum.x - profile.minimum.x), height = max(1, profile.maximum.y - profile.minimum.y)
        request.targetWidth = width * 0.8; request.targetHeight = height * 0.8
        request.originX = profile.minimum.x + width * 0.1; request.originY = profile.minimum.y + height * 0.1
    }
}
