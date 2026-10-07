import Foundation
import Darwin
import Network

protocol MachineTransport: AnyObject {
    var onLine: ((String) -> Void)? { get set }
    var onState: ((String) -> Void)? { get set }
    func connect() throws
    func disconnect()
    func send(_ text: String) throws
}

enum TransportError: LocalizedError {
    case invalidURL, openFailed(String), configurationFailed(Int), notConnected
    var errorDescription: String? {
        switch self { case .invalidURL: "The WebSocket URL is invalid."; case .openFailed(let path): "Could not open \(path)."; case .configurationFailed(let baud): "The serial port could not be configured for \(baud) baud."; case .notConnected: "The machine is not connected." }
    }
}

final class SerialTransport: MachineTransport, @unchecked Sendable {
    var onLine: ((String) -> Void)?
    var onState: ((String) -> Void)?
    private let path: String, baudRate: Int
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var buffer = Data()

    init(path: String, baudRate: Int) { self.path = path; self.baudRate = baudRate }
    func connect() throws {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw TransportError.openFailed(path) }
        var settings = termios(); tcgetattr(fd, &settings); cfmakeraw(&settings)
        let speed: speed_t = [9_600: speed_t(B9600), 57_600: speed_t(B57600), 115_200: speed_t(B115200), 230_400: speed_t(B230400)][baudRate] ?? speed_t(B115200)
        cfsetispeed(&settings, speed); cfsetospeed(&settings, speed); settings.c_cflag |= tcflag_t(CLOCAL | CREAD); tcsetattr(fd, TCSANOW, &settings)
        // IOSSIOSPEED is macOS's supported route for non-POSIX rates such as Marlin's common 250000 baud.
        var exactSpeed = speed_t(baudRate)
        if ioctl(fd, 0x80085402, &exactSpeed) == -1 { Darwin.close(fd); throw TransportError.configurationFailed(baudRate) }
        descriptor = fd
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        readSource.setEventHandler { [weak self] in self?.readAvailable() }
        readSource.setCancelHandler { Darwin.close(fd) }
        source = readSource; readSource.resume(); onState?("Connected to \(path)")
    }
    func disconnect() { source?.cancel(); source = nil; descriptor = -1 }
    func send(_ text: String) throws {
        guard descriptor >= 0 else { throw TransportError.notConnected }
        let bytes = Array(text.utf8); let result = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        if result < 0 { throw TransportError.notConnected }
    }
    private func readAvailable() {
        guard descriptor >= 0 else { return }; var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(descriptor, &bytes, bytes.count); guard count > 0 else { return }
        buffer.append(contentsOf: bytes[0..<count])
        while let newline = buffer.firstIndex(of: 10) {
            let data = buffer[..<newline]; buffer.removeSubrange(...newline)
            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines), !line.isEmpty { onLine?(line) }
        }
    }
}

final class WebSocketTransport: MachineTransport, @unchecked Sendable {
    var onLine: ((String) -> Void)?
    var onState: ((String) -> Void)?
    var onResolvedURL: ((String) -> Void)?
    private let urlString: String
    private let queue = DispatchQueue(label: "com.stephenc.gcodesender.websocket", qos: .userInitiated)
    private var connection: NWConnection?
    private var attemptedPort80Fallback = false
    private var shouldReconnect = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var activeURL: URL?
    private var generation = 0
    private var ready = false

    init(urlString: String) { self.urlString = urlString }

    func connect() throws {
        guard let url = normalizedURL(urlString) else { throw TransportError.invalidURL }
        attemptedPort80Fallback = false
        shouldReconnect = true
        open(url)
    }

    func disconnect() {
        shouldReconnect = false; reconnectWorkItem?.cancel(); reconnectWorkItem = nil
        generation += 1; ready = false; connection?.cancel(); connection = nil
    }

    func send(_ text: String) throws {
        guard let connection, ready else { throw TransportError.notConnected }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "gcode", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if let error { self?.scheduleReconnect(after: 1.5, error: error) }
        })
    }

    private func normalizedURL(_ value: String) -> URL? {
        guard var components = URLComponents(string: value) else { return nil }
        if components.scheme?.lowercased() == "http" { components.scheme = "ws" }
        if components.scheme?.lowercased() == "https" { components.scheme = "wss" }
        guard ["ws", "wss"].contains(components.scheme?.lowercased() ?? ""), components.host != nil else { return nil }
        if components.path.isEmpty { components.path = "/" }
        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "independent_session" }) {
            queryItems.append(URLQueryItem(name: "independent_session", value: "1"))
        }
        components.queryItems = queryItems
        return components.url
    }

    private func open(_ url: URL) {
        guard shouldReconnect else { return }
        guard let hostname = url.host, NWEndpoint.Port(rawValue: UInt16(url.port ?? (url.scheme == "wss" ? 443 : 80))) != nil else {
            onLine?(TransportError.invalidURL.localizedDescription); return
        }
        reconnectWorkItem?.cancel(); reconnectWorkItem = nil; activeURL = url; ready = false
        generation += 1; let thisGeneration = generation
        connection?.cancel()

        let webSocket = NWProtocolWebSocket.Options(); webSocket.autoReplyPing = true
        webSocket.setAdditionalHeaders([("Host", url.port.map { "\(hostname):\($0)" } ?? hostname)])
        let parameters = NWParameters(tls: url.scheme == "wss" ? NWProtocolTLS.Options() : nil, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        let connection = NWConnection(to: .url(url), using: parameters)
        self.connection = connection
        onState?("Connecting to \(url.host ?? url.absoluteString)…")
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            self.handle(state, connection: connection, url: url, generation: thisGeneration)
        }
        connection.start(queue: queue)
    }

    private func handle(_ state: NWConnection.State, connection: NWConnection, url: URL, generation: Int) {
        guard generation == self.generation, connection === self.connection, shouldReconnect else { return }
        switch state {
        case .ready:
            ready = true; reconnectWorkItem?.cancel(); reconnectWorkItem = nil
            let resolved = websocketURL(from: url); onResolvedURL?(resolved.absoluteString)
            onState?("Connected to \(resolved.host ?? urlString)\(resolved.port.map { ":\($0)" } ?? "")")
            receive(on: connection, generation: generation)
        case .failed(let error):
            ready = false
            if let fallback = port80FallbackURL(), !attemptedPort80Fallback {
                attemptedPort80Fallback = true; onLine?("Port 81 did not answer; trying FluidNC on port 80…"); open(fallback)
            } else { scheduleReconnect(after: 1.5, error: error) }
        case .waiting(let error):
            ready = false; scheduleReconnect(after: 1.5, error: error)
        case .cancelled: ready = false
        default: break
        }
    }

    private func receive(on connection: NWConnection, generation: Int) {
        connection.receiveMessage { [weak self, weak connection] data, context, _, error in
            guard let self, let connection, generation == self.generation, connection === self.connection, self.shouldReconnect else { return }
            if let error { self.ready = false; self.scheduleReconnect(after: 1.5, error: error); return }
            if let data, !data.isEmpty {
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .close { self.ready = false; self.scheduleReconnect(after: 1.5, error: nil); return }
                let text = String(decoding: data, as: UTF8.self)
                if text.trimmingCharacters(in: .whitespacesAndNewlines) == "PING" { /* FluidNC text heartbeat; no reply required. */ }
                else { text.components(separatedBy: .newlines).filter { !$0.isEmpty }.forEach { self.onLine?($0) } }
            }
            self.receive(on: connection, generation: generation)
        }
    }

    private func port80FallbackURL() -> URL? {
        guard let current = activeURL, current.port == 81, var components = URLComponents(url: current, resolvingAgainstBaseURL: false) else { return nil }
        components.port = nil
        return components.url
    }

    private func scheduleReconnect(after delay: TimeInterval, error: Error?) {
        guard shouldReconnect, reconnectWorkItem == nil, let url = activeURL else { return }
        onState?("Reconnecting to \(url.host ?? urlString)…")
        if let error { onLine?("Connection interrupted; retrying… (\(error.localizedDescription))") }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shouldReconnect else { return }
            self.reconnectWorkItem = nil; self.open(url)
        }
        reconnectWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func websocketURL(from requestURL: URL) -> URL {
        guard var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) else { return requestURL }
        if components.scheme == "http" { components.scheme = "ws" }
        if components.scheme == "https" { components.scheme = "wss" }
        if components.port == 80, components.scheme == "ws" { components.port = nil }
        return components.url ?? requestURL
    }

}

enum SerialDiscovery {
    static func paths() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.") && !$0.contains("Bluetooth-Incoming-Port") }.map { "/dev/\($0)" }.sorted()
    }
}
