import Foundation

@main
struct WebSocketProbe {
    static func main() {
        let lock = NSLock()
        var states = [String]()
        var messages = 0
        let transport = WebSocketTransport(urlString: CommandLine.arguments.dropFirst().first ?? "ws://fluidnc.lan/")
        transport.onState = { state in lock.lock(); states.append(state); lock.unlock(); print("STATE \(state)") }
        transport.onLine = { line in lock.lock(); messages += 1; lock.unlock(); print("RX \(line)") }
        do { try transport.connect() } catch { print("CONNECT ERROR \(error)"); exit(2) }
        Thread.sleep(forTimeInterval: 15)
        lock.lock()
        let snapshot = states, count = messages
        lock.unlock()
        transport.disconnect()
        let connected = snapshot.filter { $0.hasPrefix("Connected") }.count
        let reconnecting = snapshot.filter { $0.hasPrefix("Reconnecting") }.count
        print("RESULT connected=\(connected) reconnecting=\(reconnecting) messages=\(count)")
        exit(connected == 1 && reconnecting == 0 && count > 0 ? 0 : 1)
    }
}
