import Darwin
import Foundation

/// Finds Sonos players with an SSDP M-SEARCH on 239.255.255.250:1900.
///
/// One responding player is enough: the full household topology is then read
/// from its ZoneGroupTopology service.
///
/// On macOS 15 and later the first multicast send triggers the Local Network
/// privacy prompt. Sends fail until the user allows it.
public enum SonosDiscovery {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Returns the base URLs (`http://ip:1400`) of the players that responded.
    public static func discover(timeout: TimeInterval = 3) async throws -> [URL] {
        try await Task.detached(priority: .userInitiated) {
            try search(timeout: timeout)
        }.value
    }

    private static let request = """
    M-SEARCH * HTTP/1.1\r
    HOST: 239.255.255.250:1900\r
    MAN: "ssdp:discover"\r
    MX: 1\r
    ST: urn:schemas-upnp-org:device:ZonePlayer:1\r
    \r

    """

    private static func search(timeout: TimeInterval) throws -> [URL] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw Failure(message: "Could not open a UDP socket (errno \(errno))") }
        defer { close(fd) }

        var receiveTimeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(1900).bigEndian
        destination.sin_addr.s_addr = inet_addr("239.255.255.250")

        let payload = Array(request.utf8)
        var lastSendError: Int32 = 0
        var sentAny = false

        func send() {
            let sent = withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, payload, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if sent < 0 { lastSendError = errno } else { sentAny = true }
        }

        var found: [URL] = []
        var buffer = [UInt8](repeating: 0, count: 2048)
        let deadline = Date().addingTimeInterval(timeout)
        var nextSend = Date()
        var sends = 0

        while Date() < deadline {
            // UDP is lossy, so send the search three times.
            if sends < 3 && Date() >= nextSend {
                send()
                sends += 1
                nextSend = Date().addingTimeInterval(0.5)
            }
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { continue }
            let response = String(decoding: buffer[0..<count], as: UTF8.self)
            guard response.contains("Sonos") || response.contains("ZonePlayer"),
                  let location = header("LOCATION", in: response),
                  let base = Parsing.baseURL(fromLocation: location),
                  !found.contains(base)
            else { continue }
            found.append(base)
            // We only need one player, but let late responders arrive briefly.
            if found.count == 1 { return found + drain(fd, buffer: &buffer, for: 0.4, excluding: found) }
        }

        if !sentAny {
            throw Failure(message: "Could not send the discovery request (\(String(cString: strerror(lastSendError)))). "
                + "Allow Soffos in System Settings › Privacy & Security › Local Network.")
        }
        return found
    }

    private static func drain(_ fd: Int32, buffer: inout [UInt8], for seconds: TimeInterval, excluding: [URL]) -> [URL] {
        var extra: [URL] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { continue }
            let response = String(decoding: buffer[0..<count], as: UTF8.self)
            if let location = header("LOCATION", in: response),
               let base = Parsing.baseURL(fromLocation: location),
               !excluding.contains(base), !extra.contains(base) {
                extra.append(base)
            }
        }
        return extra
    }

    static func header(_ name: String, in response: String) -> String? {
        for line in response.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
