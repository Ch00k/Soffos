import Foundation

/// A UPnP service exposed by every Sonos player on port 1400.
public struct SonosService: Sendable, Hashable {
    public let name: String
    public let controlPath: String

    public var urn: String { "urn:schemas-upnp-org:service:\(name):1" }

    public static let avTransport = SonosService(name: "AVTransport", controlPath: "/MediaRenderer/AVTransport/Control")
    public static let renderingControl = SonosService(name: "RenderingControl", controlPath: "/MediaRenderer/RenderingControl/Control")
    public static let groupRenderingControl = SonosService(name: "GroupRenderingControl", controlPath: "/MediaRenderer/GroupRenderingControl/Control")
    public static let contentDirectory = SonosService(name: "ContentDirectory", controlPath: "/MediaServer/ContentDirectory/Control")
    public static let zoneGroupTopology = SonosService(name: "ZoneGroupTopology", controlPath: "/ZoneGroupTopology/Control")
}

public enum SonosError: Error, LocalizedError, Equatable {
    case upnp(action: String, code: Int)
    case http(action: String, status: Int)
    case invalidResponse(String)
    case noPlayersFound

    public var errorDescription: String? {
        switch self {
        case let .upnp(action, code):
            "Sonos rejected \(action) (UPnP error \(code): \(Self.describe(code)))"
        case let .http(action, status):
            "Sonos returned HTTP \(status) for \(action)"
        case let .invalidResponse(detail):
            "Unexpected response from Sonos: \(detail)"
        case .noPlayersFound:
            "No Sonos players found on the local network"
        }
    }

    public var upnpCode: Int? {
        if case let .upnp(_, code) = self { return code }
        return nil
    }

    static func describe(_ code: Int) -> String {
        switch code {
        case 401: "invalid action"
        case 402: "invalid arguments"
        case 701: "transition not available"
        case 711: "illegal seek target"
        case 714: "illegal MIME type"
        case 800: "the music service refused the item"
        case 804: "the music service refused the item"
        default: "unknown"
        }
    }
}

/// Minimal SOAP client for Sonos UPnP actions.
public struct SOAPClient: Sendable {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Calls `action` on `service` and returns the response's out-arguments by name.
    @discardableResult
    public func call(
        _ base: URL,
        _ service: SonosService,
        _ action: String,
        _ arguments: KeyValuePairs<String, String> = [:],
        timeout: TimeInterval = 6
    ) async throws -> [String: String] {
        var request = URLRequest(url: base.appendingPathComponent(service.controlPath))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(Self.envelope(service: service, action: action, arguments: arguments).utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 500, let code = Self.upnpErrorCode(in: data) {
            throw SonosError.upnp(action: action, code: code)
        }
        guard (200..<300).contains(status) else {
            throw SonosError.http(action: action, status: status)
        }
        return try Self.parseResponse(data, action: action)
    }

    static func envelope(service: SonosService, action: String, arguments: KeyValuePairs<String, String>) -> String {
        let args = arguments.map { "<\($0.key)>\(XML.escape($0.value))</\($0.key)>" }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\
        <u:\(action) xmlns:u="\(service.urn)">\(args)</u:\(action)>\
        </s:Body></s:Envelope>
        """
    }

    static func parseResponse(_ data: Data, action: String) throws -> [String: String] {
        let doc: XMLDocument
        do {
            doc = try XMLDocument(data: data)
        } catch {
            throw SonosError.invalidResponse("\(action): \(error.localizedDescription)")
        }
        let nodes = try doc.nodes(forXPath: "//*[local-name()='\(action)Response']")
        guard let responseElement = nodes.first as? XMLElement else {
            throw SonosError.invalidResponse("\(action): missing \(action)Response")
        }
        var result: [String: String] = [:]
        for child in responseElement.children ?? [] {
            if let name = child.localName {
                result[name] = child.stringValue ?? ""
            }
        }
        return result
    }

    static func upnpErrorCode(in data: Data) -> Int? {
        guard let doc = try? XMLDocument(data: data),
              let node = try? doc.nodes(forXPath: "//*[local-name()='errorCode']").first,
              let text = node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return Int(text)
    }
}

enum XML {
    static func escape(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        for ch in string {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Text of the first descendant whose local name matches (namespace-agnostic).
    static func text(_ node: XMLNode, _ localName: String) -> String? {
        guard let found = try? node.nodes(forXPath: ".//*[local-name()='\(localName)']").first else { return nil }
        let value = found.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }
}
