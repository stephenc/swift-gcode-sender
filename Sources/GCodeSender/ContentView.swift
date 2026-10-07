import SwiftUI
import GCodeKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var inspectorVisible = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedProfileID) {
                Section("Machines") {
                    ForEach(model.profiles) { profile in
                        Label(profile.name, systemImage: profile.connection == .serial ? "cable.connector" : "wifi")
                            .tag(profile.id)
                    }
                }
            }
            .navigationTitle("G-code Sender")
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button(action: model.addProfile) { Image(systemName: "plus") }
                    Button(action: model.deleteSelectedProfile) { Image(systemName: "minus") }.disabled(model.profiles.count <= 1)
                    Spacer()
                    SettingsLink { Image(systemName: "gear") }
                }.buttonStyle(.borderless).padding(10)
            }
            .frame(minWidth: 190)
        } detail: {
            VStack(spacing: 0) {
                ConnectionBar()
                Divider()
                if let program = model.program, let profile = model.selectedProfile {
                    PreviewArea(program: program, profile: profile)
                } else {
                    EmptyState()
                }
                Divider()
                JobBar()
            }
            .navigationTitle(model.fileName)
            .toolbar {
                ToolbarItemGroup {
                    Button { model.isImporterPresented = true } label: { Label("Open", systemImage: "folder") }
                    Button { inspectorVisible.toggle() } label: { Label("Console", systemImage: "terminal") }
                }
            }
            .inspector(isPresented: $inspectorVisible) { ConsoleView().inspectorColumnWidth(min: 240, ideal: 300, max: 420) }
        }
        .fileImporter(isPresented: $model.isImporterPresented, allowedContentTypes: [.gcode, .plainText, .svg], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { model.importFile(url) }
            else if case .failure(let error) = result { model.lastError = error.localizedDescription }
        }
        .sheet(item: $model.svgImportRequest) { request in
            SVGSlicerView(request: request, profile: model.selectedProfile ?? DeviceProfile(),
                onCancel: { model.svgImportRequest = nil }, onSlice: model.sliceSVG)
        }
        .alert("G-code Sender", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: { Text(model.lastError ?? "") }
    }
}

private struct ConnectionBar: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmHome = false
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(model.connectionState == "Disconnected" ? Color.secondary : Color.green).frame(width: 9, height: 9)
            Text(model.selectedProfile?.name ?? "No machine").fontWeight(.semibold)
            Text(model.connectionState).foregroundStyle(.secondary).lineLimit(1)
            if model.connectionState.hasPrefix("Connected") {
                Divider().frame(height: 20)
                Text(statusText).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.connectionState == "Disconnected" {
                Button("Connect", action: model.connect).buttonStyle(.borderedProminent)
            } else {
                ControlGroup {
                    Button { confirmHome = true } label: { Label("Home", systemImage: "house") }
                        .help("Home all axes")
                    Button(action: model.unlockMachine) { Label("Unlock", systemImage: "lock.open") }
                        .help("Clear the controller alarm lock")
                    Button(action: model.requestStatus) { Label("Refresh status", systemImage: "arrow.clockwise") }
                        .help("Request current machine status")
                }.disabled(model.isSending || !model.connectionState.hasPrefix("Connected"))
                Button("Disconnect", action: model.disconnect)
            }
        }.padding(.horizontal, 16).frame(height: 52)
        .confirmationDialog("Home this machine?", isPresented: $confirmHome) {
            Button("Home All Axes") { model.homeMachine() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The machine will move toward its homing switches. Make sure the workspace is clear.") }
    }

    private var statusText: String {
        guard let p = model.machinePosition else { return model.machineState }
        return "\(model.machineState)  X\(p.x.formatted(.number.precision(.fractionLength(2))))  Y\(p.y.formatted(.number.precision(.fractionLength(2))))  Z\(p.z.formatted(.number.precision(.fractionLength(2))))"
    }
}

private struct EmptyState: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ContentUnavailableView {
            Label("Open a toolpath", systemImage: "scribble.variable")
        } description: {
            Text("Preview .gcode files or turn an SVG into a ready-to-send plot.")
        } actions: {
            Button("Open G-code or SVG…") { model.isImporterPresented = true }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PreviewArea: View {
    let program: GCodeProgram
    let profile: DeviceProfile
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(program.resolvedPreviewMode(for: profile) == .twoD ? "2D plot preview" : "3D toolpath preview",
                      systemImage: program.resolvedPreviewMode(for: profile) == .twoD ? "square" : "cube")
                Spacer()
                Text("\(program.segments.count) moves · \(program.zLevels.count) Z level\(program.zLevels.count == 1 ? "" : "s")").foregroundStyle(.secondary)
            }.font(.callout).padding(.horizontal, 16).frame(height: 42).background(.bar)
            if program.resolvedPreviewMode(for: profile) == .twoD { Toolpath2DView(program: program, profile: profile) }
            else { Toolpath3DView(program: program, profile: profile) }
        }
    }
}

private struct JobBar: View {
    @EnvironmentObject private var model: AppModel
    var report: CompatibilityReport? { guard let p = model.program, let profile = model.selectedProfile else { return nil }; return p.compatibility(with: profile) }
    var body: some View {
        VStack(spacing: 8) {
            if let report, let message = report.errors.first ?? report.warnings.first {
                HStack { Image(systemName: report.errors.isEmpty ? "exclamationmark.triangle" : "xmark.octagon"); Text(message).lineLimit(2); Spacer() }
                    .font(.caption).foregroundStyle(report.errors.isEmpty ? .orange : .red)
            }
            HStack {
                ProgressView(value: model.progress).frame(maxWidth: 280)
                Text(model.progress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Stop", role: .destructive, action: model.emergencyStop).disabled(model.connectionState == "Disconnected")
                Button(model.isSending ? (model.isPaused ? "Resume" : "Pause") : "Send", action: model.isSending ? model.pauseOrResume : model.sendProgram)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.program == nil || !model.connectionState.hasPrefix("Connected") || report?.canSend == false)
            }
        }.padding(12)
    }
}

private struct ConsoleView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Controller console").font(.headline); Spacer(); Button("Clear") { model.console.removeAll() }.buttonStyle(.plain) }.padding()
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.console.enumerated()), id: \.offset) { index, line in Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(index) }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }.onChange(of: model.console.count) { _, count in if count > 0 { proxy.scrollTo(count - 1) } }
            }
        }
    }
}
