import AppKit
import Foundation
import GCodeKit
import UniformTypeIdentifiers

struct SVGImportRequest: Identifiable {
    let id = UUID()
    let data: Data
    let name: String
    let sourceWidth: Double
    let sourceHeight: Double
    let colors: [String]
    var targetWidth: Double
    var targetHeight: Double
    var originX: Double
    var originY: Double
    var preserveAspectRatio = true
    var pauseBetweenColors = true
    var maxFeedX: Double
    var maxFeedY: Double
    var maxFeedZ: Double
}

@MainActor
final class AppModel: ObservableObject {
    @Published var profiles: [DeviceProfile] = [] { didSet { saveProfiles() } }
    @Published var selectedProfileID: UUID? { didSet { UserDefaults.standard.set(selectedProfileID?.uuidString, forKey: "selectedProfile") } }
    @Published var program: GCodeProgram?
    @Published var fileName = "No file loaded"
    @Published var isImporterPresented = false
    @Published var connectionState = "Disconnected"
    @Published var machineState = "Unknown"
    @Published var machinePosition: Point3D?
    @Published var console = [String]()
    @Published var progress = 0.0
    @Published var isSending = false
    @Published var isPaused = false
    @Published var svgImportRequest: SVGImportRequest?
    @Published var lastError: String?

    private var transport: MachineTransport?
    private var sendTask: Task<Void, Never>?
    private var acknowledgement: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var pauseContinuation: CheckedContinuation<Bool, Never>?
    private var discoveryProfileID: UUID?
    private var discoveryLines = [String]()
    private var discoveryToken: UUID?
    private var discoveredProfiles = Set<UUID>()

    var selectedProfile: DeviceProfile? {
        get { profiles.first(where: { $0.id == selectedProfileID }) }
        set {
            guard let newValue, let index = profiles.firstIndex(where: { $0.id == newValue.id }) else { return }
            profiles[index] = newValue
        }
    }

    init() {
        loadProfiles()
        if let saved = UserDefaults.standard.string(forKey: "selectedProfile"), let id = UUID(uuidString: saved), profiles.contains(where: { $0.id == id }) { selectedProfileID = id }
        else { selectedProfileID = profiles.first?.id }
        for path in SerialDiscovery.paths() {
            if let saved = UserDefaults.standard.string(forKey: "device.\(path)"), let id = UUID(uuidString: saved), profiles.contains(where: { $0.id == id }) {
                selectedProfileID = id; break
            }
        }
    }

    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            if url.pathExtension.lowercased() == "svg" {
                let p = selectedProfile ?? DeviceProfile()
                let info = try SVGConverter().inspect(data: data)
                let availableWidth = max(1, p.maximum.x - p.minimum.x), availableHeight = max(1, p.maximum.y - p.minimum.y)
                let fitScale = min(availableWidth * 0.8 / max(info.bounds.size.x, 0.001), availableHeight * 0.8 / max(info.bounds.size.y, 0.001))
                svgImportRequest = .init(data: data, name: url.deletingPathExtension().lastPathComponent,
                    sourceWidth: info.bounds.size.x, sourceHeight: info.bounds.size.y, colors: info.colors,
                    targetWidth: info.bounds.size.x * fitScale, targetHeight: info.bounds.size.y * fitScale,
                    originX: p.minimum.x + availableWidth * 0.1, originY: p.minimum.y + availableHeight * 0.1,
                    maxFeedX: p.maxFeedX ?? 6_000, maxFeedY: p.maxFeedY ?? 6_000, maxFeedZ: p.maxFeedZ ?? 1_000)
                return
            } else {
                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                program = GCodeParser().parse(text); fileName = url.lastPathComponent
            }
            progress = 0; lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    func sliceSVG(_ request: SVGImportRequest) {
        guard let p = selectedProfile else { return }
        do {
            let options = SVGConversionOptions(targetWidth: request.targetWidth, targetHeight: request.targetHeight,
                originX: request.originX, originY: request.originY, preserveAspectRatio: request.preserveAspectRatio,
                pauseBetweenColors: request.pauseBetweenColors, homeX: p.minimum.x, homeY: p.minimum.y,
                maxFeedX: request.maxFeedX, maxFeedY: request.maxFeedY, maxFeedZ: request.maxFeedZ)
            let source = try SVGConverter().convert(data: request.data, drawZ: p.plotterDrawZ,
                travelZ: p.plotterPenUpZ, options: options)
            program = GCodeParser().parse(source); fileName = request.name + " (SVG)"; progress = 0; lastError = nil; svgImportRequest = nil
        } catch { lastError = error.localizedDescription }
    }

    func addProfile() {
        let profile = DeviceProfile(name: "Machine \(profiles.count + 1)")
        profiles.append(profile); selectedProfileID = profile.id
    }

    func deleteSelectedProfile() {
        guard profiles.count > 1, let id = selectedProfileID else { return }
        profiles.removeAll { $0.id == id }; selectedProfileID = profiles.first?.id
    }

    func connect() {
        guard let profile = selectedProfile else { return }
        disconnect()
        do {
            let next: MachineTransport
            if profile.connection == .serial {
                next = SerialTransport(path: profile.serialPath, baudRate: profile.baudRate)
            } else {
                let webSocket = WebSocketTransport(urlString: profile.webSocketURL)
                webSocket.onResolvedURL = { [weak self] resolvedURL in
                    Task { @MainActor in
                        guard let self, let index = self.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
                        self.profiles[index].webSocketURL = resolvedURL
                    }
                }
                next = webSocket
            }
            next.onLine = { [weak self] line in Task { @MainActor in self?.received(line) } }
            next.onState = { [weak self] state in Task { @MainActor in self?.transportStateChanged(state, profileID: profile.id) } }
            try next.connect(); transport = next
            connectionState = "Connecting…"
            let identity = profile.deviceIdentifier.isEmpty ? (profile.connection == .serial ? profile.serialPath : profile.webSocketURL) : profile.deviceIdentifier
            if !identity.isEmpty { UserDefaults.standard.set(profile.id.uuidString, forKey: "device.\(identity)") }
        } catch { lastError = error.localizedDescription; connectionState = "Disconnected" }
    }

    func disconnect() {
        cancelSend(); transport?.disconnect(); transport = nil; connectionState = "Disconnected"; machineState = "Unknown"; machinePosition = nil
    }

    func homeMachine() { sendManualCommand("$H", label: "Homing all axes") }
    func unlockMachine() { sendManualCommand("$X", label: "Unlocking controller") }
    func requestStatus() { sendManualCommand("?", label: nil, newline: false) }

    private func sendManualCommand(_ command: String, label: String?, newline: Bool = true) {
        guard connectionState.hasPrefix("Connected"), !isSending else { return }
        do {
            if let label { console.append("→ \(label)") }
            try transport?.send(command + (newline ? "\n" : ""))
        } catch { lastError = error.localizedDescription }
    }

    func sendProgram() {
        guard let transport, let program, let profile = selectedProfile else { return }
        let report = program.compatibility(with: profile)
        guard report.canSend else { lastError = report.errors.joined(separator: "\n"); return }
        let jobLines = program.lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.hasPrefix(";") }
        let completionLines = program.completionCommands(for: profile)
        let sendable = jobLines + completionLines
        guard !sendable.isEmpty else { return }
        isSending = true; isPaused = false; progress = 0
        sendTask = Task { [weak self] in
            guard let self else { return }
            for (index, line) in sendable.enumerated() {
                if Task.isCancelled { break }
                if index == jobLines.count { self.console.append("→ Job complete; raising tool and returning home") }
                do { try transport.send(line + "\n") }
                catch { self.lastError = error.localizedDescription; break }
                let accepted = await self.waitForAcknowledgement()
                if !accepted { break }
                self.progress = Double(index + 1) / Double(sendable.count)
                let command = line.uppercased().trimmingCharacters(in: .whitespaces)
                if command == "M0" || command == "M1" {
                    self.console.append("→ Color change: machine is home. Change the pen, then press Resume.")
                    self.isPaused = true
                    if !(await self.waitForUserResume()) { break }
                }
            }
            self.isSending = false; self.isPaused = false
        }
    }

    func cancelSend() {
        sendTask?.cancel(); sendTask = nil; timeoutTask?.cancel(); timeoutTask = nil
        acknowledgement?.resume(returning: false); acknowledgement = nil
        pauseContinuation?.resume(returning: false); pauseContinuation = nil
        isSending = false; isPaused = false
    }
    func pauseOrResume() {
        if isPaused {
            try? transport?.send("~"); isPaused = false
            pauseContinuation?.resume(returning: true); pauseContinuation = nil
        } else {
            try? transport?.send("!"); isPaused = true
        }
    }
    func emergencyStop() { cancelSend(); try? transport?.send("\u{18}"); console.append("→ Soft reset sent") }

    private func waitForAcknowledgement() async -> Bool {
        await withCheckedContinuation { continuation in
            acknowledgement = continuation
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.finishAcknowledgement(false, message: "Timed out waiting for the controller.") }
            }
        }
    }

    private func waitForUserResume() async -> Bool {
        await withCheckedContinuation { pauseContinuation = $0 }
    }

    private func received(_ line: String) {
        if discoveryProfileID != nil {
            parseMachineStatus(line)
            if line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ok" { finishDiscovery() }
            else { discoveryLines.append(line) }
            return
        }
        console.append(line); if console.count > 500 { console.removeFirst(console.count - 500) }
        let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        parseMachineStatus(line)
        if normalized == "ok" { finishAcknowledgement(true) }
        else if normalized.hasPrefix("error") || normalized.hasPrefix("alarm") { finishAcknowledgement(false, message: line) }
    }

    private func parseMachineStatus(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">") else { return }
        let fields = trimmed.dropFirst().dropLast().split(separator: "|")
        if let first = fields.first { machineState = String(first) }
        for field in fields where field.hasPrefix("MPos:") || field.hasPrefix("WPos:") {
            let values = field.dropFirst(5).split(separator: ",").compactMap { Double($0) }
            if values.count >= 3 { machinePosition = .init(x: values[0], y: values[1], z: values[2]) }
        }
    }

    private func transportStateChanged(_ state: String, profileID: UUID) {
        connectionState = state
        guard state.hasPrefix("Connected"), !discoveredProfiles.contains(profileID),
              profiles.first(where: { $0.id == profileID })?.connection == .fluidNC else { return }
        discoveredProfiles.insert(profileID); discoveryProfileID = profileID; discoveryLines = []
        let token = UUID(); discoveryToken = token
        do { try transport?.send("$Config/Dump\n") }
        catch { finishDiscovery() }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await MainActor.run { if self?.discoveryToken == token { self?.finishDiscovery() } }
        }
    }

    private func finishDiscovery() {
        guard let profileID = discoveryProfileID, let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            discoveryProfileID = nil; discoveryLines = []; discoveryToken = nil; return
        }
        var axis: Character?, travels = [Character: Double](), rates = [Character: Double]()
        for line in discoveryLines {
            if let match = line.range(of: #"^\s{2}([XYZ]):\s*$"#, options: .regularExpression) {
                axis = line[match].trimmingCharacters(in: .whitespacesAndNewlines).first; continue
            }
            guard let axis else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("max_travel_mm:"), let value = Double(trimmed.dropFirst("max_travel_mm:".count).trimmingCharacters(in: .whitespaces)) { travels[axis] = value }
            if trimmed.hasPrefix("max_rate_mm_per_min:"), let value = Double(trimmed.dropFirst("max_rate_mm_per_min:".count).trimmingCharacters(in: .whitespaces)) { rates[axis] = value }
        }
        if let value = travels["X"] { profiles[index].maximum.x = profiles[index].minimum.x + value }
        if let value = travels["Y"] { profiles[index].maximum.y = profiles[index].minimum.y + value }
        if let value = travels["Z"] { profiles[index].maximum.z = profiles[index].minimum.z + value }
        profiles[index].maxFeedX = rates["X"] ?? profiles[index].maxFeedX
        profiles[index].maxFeedY = rates["Y"] ?? profiles[index].maxFeedY
        profiles[index].maxFeedZ = rates["Z"] ?? profiles[index].maxFeedZ
        if !travels.isEmpty || !rates.isEmpty {
            console.append("→ Profile updated from FluidNC: X \(profiles[index].maximum.x.formatted()) mm, Y \(profiles[index].maximum.y.formatted()) mm, Z \(profiles[index].maximum.z.formatted()) mm")
        }
        discoveryProfileID = nil; discoveryLines = []; discoveryToken = nil
        try? transport?.send("?")
    }

    private func finishAcknowledgement(_ success: Bool, message: String? = nil) {
        guard let pending = acknowledgement else { return }
        acknowledgement = nil; timeoutTask?.cancel(); timeoutTask = nil
        if let message { lastError = message }
        pending.resume(returning: success)
    }

    private func loadProfiles() {
        if let data = UserDefaults.standard.data(forKey: "profiles"), let decoded = try? JSONDecoder().decode([DeviceProfile].self, from: data), !decoded.isEmpty { profiles = decoded }
        else {
            profiles = [
                DeviceProfile(name: "2D Plotter", maximum: .init(x: 300, y: 300, z: 10), previewMode: .twoD, maxFeedX: 6_000, maxFeedY: 6_000, maxFeedZ: 1_000),
                DeviceProfile(name: "3D Printer", baudRate: 250_000, maximum: .init(x: 220, y: 220, z: 250), previewMode: .threeD)
            ]
        }
    }
    private func saveProfiles() { if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: "profiles") } }
}

extension UTType {
    static var gcode: UTType { UTType(filenameExtension: "gcode") ?? .plainText }
}
