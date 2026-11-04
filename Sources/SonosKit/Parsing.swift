import Foundation

enum Parsing {
    /// Parses the `ZoneGroupState` document returned by ZoneGroupTopology.
    ///
    /// Hidden members (surround speakers, subs, stereo-pair secondaries) and
    /// bridges are skipped; they aren't independently controllable rooms.
    static func zoneGroups(_ xml: String) throws -> [SonosGroup] {
        let doc = try XMLDocument(xmlString: xml)
        var groups: [SonosGroup] = []

        for case let groupElement as XMLElement in try doc.nodes(forXPath: "//ZoneGroup") {
            guard let coordinatorID = groupElement.attribute(forName: "Coordinator")?.stringValue else { continue }

            let members = groupElement.elements(forName: "ZoneGroupMember")
            var speakerURLs: [String: URL] = [:]
            for element in members + members.flatMap({ $0.elements(forName: "Satellite") }) {
                guard let uuid = element.attribute(forName: "UUID")?.stringValue,
                      let location = element.attribute(forName: "Location")?.stringValue,
                      let base = baseURL(fromLocation: location)
                else { continue }
                speakerURLs[uuid] = base
            }

            var players: [SonosPlayer] = []
            for member in members {
                func attr(_ name: String) -> String? { member.attribute(forName: name)?.stringValue }
                if attr("Invisible") == "1" || attr("IsZoneBridge") == "1" { continue }
                guard let uuid = attr("UUID"),
                      let name = attr("ZoneName"),
                      let base = speakerURLs[uuid]
                else { continue }

                var roles = speakerRoles(attr("ChannelMapSet") ?? "") + speakerRoles(attr("HTSatChanMapSet") ?? "")
                if let own = roles.firstIndex(where: { $0.id == uuid }) {
                    roles.insert(roles.remove(at: own), at: 0)
                }
                var speakers: [SonosSpeaker] = []
                for (id, role) in roles where !speakers.contains(where: { $0.id == id }) {
                    guard let url = speakerURLs[id] else { continue }
                    speakers.append(SonosSpeaker(id: id, baseURL: url, role: role))
                }
                if speakers.isEmpty {
                    speakers = [SonosSpeaker(id: uuid, baseURL: base, role: nil)]
                }

                players.append(SonosPlayer(id: uuid, roomName: name, baseURL: base, speakers: speakers))
            }

            guard let coordinator = players.first(where: { $0.id == coordinatorID }) else { continue }
            groups.append(SonosGroup(coordinator: coordinator, members: players))
        }

        return groups.sorted { $0.coordinator.roomName.localizedStandardCompare($1.coordinator.roomName) == .orderedAscending }
    }

    /// Each speaker's role from a `ChannelMapSet` (stereo pairs) or
    /// `HTSatChanMapSet` (home theaters) value, e.g.
    /// `RINCON_A:LF,LF;RINCON_B:RF,RF` -> A is left, B is right.
    static func speakerRoles(_ mapSet: String) -> [(id: String, role: SonosSpeaker.Role?)] {
        mapSet.split(separator: ";").compactMap { entry in
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }

            let channels = Set(parts[1].split(separator: ","))
            let role: SonosSpeaker.Role? = switch channels {
            case _ where channels.contains("SW"): .sub
            case _ where channels.contains("LR"): .surroundLeft
            case _ where channels.contains("RR"): .surroundRight
            case ["LF"]: .left
            case ["RF"]: .right
            default: nil
            }

            return (String(parts[0]), role)
        }
    }

    /// The product name and picture from a speaker's
    /// `/xml/device_description.xml`.
    static func speakerModel(_ xml: String, relativeTo base: URL) throws -> SpeakerModel {
        let doc = try XMLDocument(xmlString: xml)
        guard let device = try doc.nodes(forXPath: "/*[local-name()='root']/*[local-name()='device']").first,
              let name = XML.text(device, "displayName") ?? XML.text(device, "modelName")
        else {
            throw SonosError.invalidResponse("device description had no model name")
        }

        let icon = XML.text(device, "url").flatMap { artURL($0, relativeTo: base) }
        return SpeakerModel(name: name, iconURL: icon)
    }

    /// `http://192.168.1.20:1400/xml/device_description.xml` -> `http://192.168.1.20:1400`
    static func baseURL(fromLocation location: String) -> URL? {
        guard let url = URL(string: location), let scheme = url.scheme, let host = url.host else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return URL(string: "\(scheme)://\(host)\(port)")
    }

    /// Parses all `<item>` elements of a DIDL-Lite document.
    static func didlItems(_ didl: String, relativeTo base: URL) -> [TrackMetadata] {
        guard !didl.isEmpty, didl != "NOT_IMPLEMENTED",
              let root = (try? XMLDocument(xmlString: didl))?.rootElement()
        else { return [] }

        // Items are direct children of <DIDL-Lite> and their fields direct
        // children of <item>. Walking children is far cheaper than XPath,
        // which matters for queue pages with hundreds of items.
        return (root.children ?? []).compactMap { node in
            guard let item = node as? XMLElement, item.localName == "item" else { return nil }
            var fields: [String: String] = [:]
            for case let child as XMLElement in item.children ?? [] {
                guard let name = child.localName, fields[name] == nil,
                      let value = child.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
                else { continue }
                fields[name] = value
            }
            let title = fields["title"] ?? ""
            let stream = fields["streamContent"]
            if title.isEmpty && stream == nil { return nil }
            return TrackMetadata(
                title: title,
                artist: fields["creator"] ?? fields["artist"],
                album: fields["album"],
                albumArtURL: fields["albumArtURI"].flatMap { artURL($0, relativeTo: base) },
                streamContent: stream
            )
        }
    }

    /// Album art is either absolute (e.g. Spotify's CDN) or a path such as
    /// `/getaa?s=1&u=...` served by the player itself.
    static func artURL(_ raw: String, relativeTo base: URL) -> URL? {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return URL(string: raw) }
        return URL(string: base.absoluteString + (raw.hasPrefix("/") ? raw : "/" + raw))
    }

    /// `"0:03:45"` -> 225. Returns 0 for `NOT_IMPLEMENTED` and empty strings.
    static func seconds(_ hms: String?) -> TimeInterval {
        guard let hms else { return 0 }
        let parts = hms.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    /// 225 -> `"0:03:45"`
    static func hms(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
