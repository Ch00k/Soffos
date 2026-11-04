import Darwin
import Foundation
import Network

/// Receives UPnP event notifications (GENA `NOTIFY` requests) from Sonos
/// players, so the app can react to changes instead of polling for them.
///
/// Only the subscription ID of each notification is reported; callers treat
/// a notification as "this service changed" and re-read what they need.
public final class SonosEventListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "soffos.sonos.events")
    private let onNotify: @Sendable (_ sid: String) -> Void

    private init(listener: NWListener, onNotify: @escaping @Sendable (String) -> Void) {
        self.listener = listener
        self.onNotify = onNotify
    }

    /// The TCP port the listener accepts notifications on.
    public var port: UInt16 { listener.port?.rawValue ?? 0 }

    /// Starts listening on an ephemeral port on all interfaces.
    public static func start(onNotify: @escaping @Sendable (_ sid: String) -> Void) async throws -> SonosEventListener {
        let nw = try NWListener(using: .tcp)
        let listener = SonosEventListener(listener: nw, onNotify: onNotify)
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            nw.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume() }
                case let .failed(error): once.run { continuation.resume(throwing: error) }
                case .cancelled: once.run { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            nw.newConnectionHandler = { [weak listener] connection in listener?.handle(connection) }
            nw.start(queue: listener.queue)
        }
        return listener
    }

    public func stop() {
        listener.cancel()
    }

    // MARK: Connections

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                let length = Int(Self.header("CONTENT-LENGTH", in: header) ?? "") ?? 0
                let bodyReceived = buffer.count - headerEnd.upperBound
                if bodyReceived >= length || isComplete || error != nil {
                    self.respond(connection)
                    if header.hasPrefix("NOTIFY"), let sid = Self.header("SID", in: header) {
                        self.onNotify(sid)
                    }
                    return
                }
            }
            if isComplete || error != nil || buffer.count > 4_000_000 {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }

    private func respond(_ connection: NWConnection) {
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    static func header(_ name: String, in header: String) -> String? {
        SonosDiscovery.header(name, in: header + "\r\n")
    }

    /// The local IP address this Mac uses to reach `host`, i.e. the address
    /// a player must call back to.
    public static func localAddress(toward host: String) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = in_port_t(1400).bigEndian
        guard inet_pton(AF_INET, host, &remote.sin_addr) == 1 else { return nil }
        // Connecting a UDP socket sends nothing; it just picks the route.
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &local.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Runs a closure at most once, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

// MARK: - Subscriptions

public struct EventSubscription: Sendable {
    public let sid: String
    /// Seconds until the subscription expires unless renewed.
    public let timeout: TimeInterval
}

extension SonosService {
    /// Where to SUBSCRIBE for this service's events.
    public var eventPath: String {
        controlPath.replacingOccurrences(of: "/Control", with: "/Event")
    }
}

extension SonosClient {
    /// Subscribes to a service's events, delivered to `callback`.
    public func subscribe(_ base: URL, _ service: SonosService, callback: URL, timeout: Int = 1800) async throws -> EventSubscription {
        try await eventRequest(base, service, method: "SUBSCRIBE", headers: [
            "CALLBACK": "<\(callback.absoluteString)>",
            "NT": "upnp:event",
            "TIMEOUT": "Second-\(timeout)",
        ])
    }

    /// Extends an existing subscription.
    public func renew(_ base: URL, _ service: SonosService, sid: String, timeout: Int = 1800) async throws -> EventSubscription {
        try await eventRequest(base, service, method: "SUBSCRIBE", headers: ["SID": sid, "TIMEOUT": "Second-\(timeout)"])
    }

    public func unsubscribe(_ base: URL, _ service: SonosService, sid: String) async {
        _ = try? await eventRequest(base, service, method: "UNSUBSCRIBE", headers: ["SID": sid])
    }

    private func eventRequest(_ base: URL, _ service: SonosService, method: String, headers: [String: String]) async throws -> EventSubscription {
        var request = URLRequest(url: base.appendingPathComponent(service.eventPath))
        request.httpMethod = method
        request.timeoutInterval = 6
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (_, response) = try await soap.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SonosError.invalidResponse("\(method) \(service.name)") }
        guard (200..<300).contains(http.statusCode) else { throw SonosError.http(action: "\(method) \(service.name)", status: http.statusCode) }
        let sid = http.value(forHTTPHeaderField: "SID") ?? headers["SID"] ?? ""
        let timeout = (http.value(forHTTPHeaderField: "TIMEOUT") ?? "")
            .replacingOccurrences(of: "Second-", with: "", options: .caseInsensitive)
        return EventSubscription(sid: sid, timeout: TimeInterval(timeout) ?? 1800)
    }
}
