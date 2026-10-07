import SwiftUI
import GCodeKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    private var profile: Binding<DeviceProfile>? {
        guard let id = model.selectedProfileID, let index = model.profiles.firstIndex(where: { $0.id == id }) else { return nil }
        return $model.profiles[index]
    }

    var body: some View {
        Form {
            if let profile {
                Section("Machine") {
                    TextField("Name", text: profile.name)
                    Picker("Connection", selection: profile.connection) { ForEach(ConnectionKind.allCases) { Text($0.title).tag($0) } }
                    if profile.wrappedValue.connection == .serial {
                        Picker("Serial port", selection: profile.serialPath) {
                            Text("Choose a port").tag("")
                            ForEach(SerialDiscovery.paths(), id: \.self) { Text($0).tag($0) }
                            if !profile.wrappedValue.serialPath.isEmpty, !SerialDiscovery.paths().contains(profile.wrappedValue.serialPath) { Text(profile.wrappedValue.serialPath).tag(profile.wrappedValue.serialPath) }
                        }
                        TextField("Baud rate", value: profile.baudRate, format: .number)
                    } else {
                        TextField("WebSocket URL", text: profile.webSocketURL).textContentType(.URL)
                        Text("FluidNC 4 uses ws://hostname/ (port 80). Older port-81 profiles automatically fall back to port 80.").font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Device identity (optional)", text: profile.deviceIdentifier)
                }
                Section("Workspace (mm)") {
                    HStack { Text("Minimum"); Spacer(); AxisField(label: "X", value: profile.minimum.x); AxisField(label: "Y", value: profile.minimum.y); AxisField(label: "Z", value: profile.minimum.z) }
                    HStack { Text("Maximum"); Spacer(); AxisField(label: "X", value: profile.maximum.x); AxisField(label: "Y", value: profile.maximum.y); AxisField(label: "Z", value: profile.maximum.z) }
                }
                Section("Maximum feed (mm/min)") {
                    HStack {
                        OptionalNumberField(label: "X", value: profile.maxFeedX)
                        OptionalNumberField(label: "Y", value: profile.maxFeedY)
                        OptionalNumberField(label: "Z", value: profile.maxFeedZ)
                    }
                }
                Section("Preview") {
                    Picker("Device type", selection: profile.previewMode) { ForEach(PreviewMode.allCases) { Text($0.title).tag($0) } }
                    Toggle("Z = 0 means drawing", isOn: profile.zeroIsDraw)
                    Text("Auto uses 2D for one or two distinct Z heights, and 3D for more.").font(.caption).foregroundStyle(.secondary)
                }
            } else { ContentUnavailableView("No machine selected", systemImage: "printer") }
        }.formStyle(.grouped).padding(.top, 8)
    }
}

private struct OptionalNumberField: View {
    let label: String
    @Binding var value: Double?
    var body: some View {
        HStack { Text(label).foregroundStyle(.secondary); TextField("Feed", value: $value, format: .number.precision(.fractionLength(0...1))).textFieldStyle(.roundedBorder) }
    }
}

private struct AxisField: View {
    let label: String
    @Binding var value: Double
    var body: some View { TextField(label, value: $value, format: .number.precision(.fractionLength(0...3))).frame(width: 70).textFieldStyle(.roundedBorder) }
}
