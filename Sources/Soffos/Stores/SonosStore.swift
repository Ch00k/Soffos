import Foundation
import Observation
import SonosKit

/// Live state of one group, refreshed by polling its coordinator.
struct NowPlaying: Equatable {
    var transport: TransportState = .unknown
    var track: TrackMetadata?
    var trackNumber = 0
    var duration: TimeInterval = 0
    var elapsed: TimeInterval = 0
    var sampledAt = Date()
    var playMode = PlayMode()
    var volume = 0
    var muted = false
    var sourceURI = ""
    var trackURI = ""

    /// `spotify:track:...` when the current track comes from Spotify.
    var spotifyTrackURI: String? { SpotifyOnSonos.spotifyTrackURI(fromSonosURI: trackURI) }

    var isQueue: Bool { sourceURI.hasPrefix("x-rincon-queue:") }

    /// True when `other` adds nothing the UI doesn't already show: same
    /// metadata and settings, and a position that matches what local
    /// interpolation predicts (within a second).
    func isEquivalent(to other: NowPlaying) -> Bool {
        var a = self, b = other
        let drift = abs(a.elapsed(at: b.sampledAt) - b.elapsed)
        a.elapsed = 0; a.sampledAt = .distantPast
        b.elapsed = 0; b.sampledAt = .distantPast
        return a == b && drift < 1.0
    }

    /// Playback position interpolated from the last poll.
    func elapsed(at date: Date) -> TimeInterval {
        guard transport == .playing else { return elapsed }
        let value = elapsed + date.timeIntervalSince(sampledAt)
        return duration > 0 ? min(duration, value) : value
    }

    /// A label for sources that aren't the queue.
    var sourceLabel: String? {
        switch sourceURI {
        case let s where s.hasPrefix("x-sonos-htastream:"): "TV"
        case let s where s.hasPrefix("x-rincon-stream:"): "Line-In"
        case let s where s.hasPrefix("x-sonos-vli:"): "Spotify Connect / AirPlay"
        case let s where s.hasPrefix("x-sonosapi-stream:") || s.hasPrefix("x-rincon-mp3radio:") || s.hasPrefix("aac:"): "Radio"
        default: nil
        }
    }

    var displayTitle: String {
        if let title = track?.title, !title.isEmpty { return title }
        return sourceLabel ?? "Nothing playing"
    }

    var displaySubtitle: String {
        if let stream = track?.streamContent { return stream }
        return [track?.artist, track?.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
    }
}

@Observable
@MainActor
final class SonosStore {
    enum Status: Equatable {
        case idle, searching, ready, failed(String)
    }

    private(set) var groups: [SonosGroup] = []
    private(set) var status: Status = .idle
    private(set) var nowPlaying: [String: NowPlaying] = [:] {
        didSet { updateQueueMarker() }
    }
    /// The queue position playing in the selected group (0 when the queue
    /// isn't the source) and whether it's playing. Kept separate from
    /// `nowPlaying` and only written on change, so the queue list doesn't
    /// re-render for volume or position updates.
    private(set) var queueMarker = QueueMarker()

    struct QueueMarker: Equatable {
        var position = 0
        var playing = false
    }

    private func updateQueueMarker() {
        let state = current
        let marker = QueueMarker(position: state.isQueue ? state.trackNumber : 0, playing: state.transport.isPlaying)
        if marker != queueMarker { queueMarker = marker }
    }
    private(set) var queue: [QueueItem] = []
    private(set) var queueTotal = 0
    private(set) var memberVolumes: [String: Int] = [:]
    var lastError: String?

    var selectedGroupID: String? {
        didSet {
            guard oldValue != selectedGroupID else { return }
            settings.lastGroupID = selectedGroupID
            queue = []
            queueTotal = 0
            queueUpdateID = nil
            Task {
                await refreshSelected(includeQueue: true)
                await syncSubscriptions()
            }
        }
    }

    var selectedGroup: SonosGroup? { groups.first { $0.id == selectedGroupID } }
    var current: NowPlaying { selectedGroupID.flatMap { nowPlaying[$0] } ?? NowPlaying() }
    var allPlayers: [SonosPlayer] {
        groups.flatMap(\.members).sorted { $0.roomName.localizedStandardCompare($1.roomName) == .orderedAscending }
    }

    let client = SonosClient()
    private let settings: AppSettings
    private let log: AppLog
    private var anchor: URL?
    private var pollTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    private var userEditingUntil = Date.distantPast
    private var lastQueueTrack = -1

    init(settings: AppSettings, log: AppLog) {
        self.settings = settings
        self.log = log
    }

    // MARK: Lifecycle

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.discover()
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                tick += 1
                if self.groups.isEmpty {
                    if tick % 10 == 0 { await self.discover() }
                    continue
                }
                if tick % 10 == 0 { await self.maintainSubscriptions() }
                if self.eventsActive {
                    // Speakers push changes; this is only a safety net for
                    // missed events (position is interpolated locally).
                    if tick % 30 == 0 { await self.refreshSelected() }
                    if tick % 60 == 0 { await self.refreshOthers() }
                    if tick % 120 == 0 { await self.refreshTopology() }
                } else {
                    if tick % 15 == 0 { await self.refreshTopology() }
                    await self.refreshSelected(includeQueue: tick % 30 == 0, full: tick % 3 == 0)
                    if tick % 4 == 0 { await self.refreshOthers() }
                }
            }
        }
    }

    func discover() async {
        status = .searching
        do {
            var candidates: [URL] = []
            let manual = settings.manualPlayerHost.trimmingCharacters(in: .whitespaces)
            if !manual.isEmpty, let url = URL(string: manual.contains(":") ? "http://\(manual)" : "http://\(manual):1400") {
                candidates.append(url)
            }
            if let anchor { candidates.append(anchor) }
            var anchorWorks = false
            if let first = candidates.first {
                anchorWorks = (try? await client.groups(via: first)) != nil
            }
            if !anchorWorks {
                candidates += try await SonosDiscovery.discover()
            }
            guard !candidates.isEmpty else { throw SonosError.noPlayersFound }

            var lastError: Error = SonosError.noPlayersFound
            for candidate in candidates {
                do {
                    let found = try await client.groups(via: candidate)
                    anchor = candidate
                    apply(groups: found)
                    status = .ready
                    log.info("Found \(found.flatMap(\.members).count) rooms in \(found.count) groups via \(candidate.host ?? "?")")
                    await syncSubscriptions()
                    await refreshSelected(includeQueue: true)
                    await refreshOthers()
                    return
                } catch {
                    lastError = error
                }
            }
            throw lastError
        } catch {
            status = .failed(error.localizedDescription)
            log.error("Discovery failed: \(error.localizedDescription)")
        }
    }

    func refreshTopology() async {
        guard let anchor else { return await discover() }
        do {
            apply(groups: try await client.groups(via: anchor))
            await syncSubscriptions()
        } catch {
            log.error("Topology refresh failed, rediscovering: \(error.localizedDescription)")
            self.anchor = nil
            await discover()
        }
    }

    private func apply(groups new: [SonosGroup]) {
        let previousSelection = selectedGroupID
        groups = new
        nowPlaying = nowPlaying.filter { key, _ in new.contains { $0.id == key } }

        if let previousSelection, new.contains(where: { $0.id == previousSelection }) { return }
        // The selected coordinator may have joined another group. Follow it.
        let preferred = previousSelection ?? settings.lastGroupID
        if let preferred, let containing = new.first(where: { $0.members.contains { $0.id == preferred } }) {
            selectedGroupID = containing.id
        } else {
            selectedGroupID = new.first(where: { nowPlaying[$0.id]?.transport == .playing })?.id ?? new.first?.id
        }
    }

    // MARK: Polling

    /// Polls the selected group. Transport state and position are read on
    /// every call; the rarely-changing rest (source, play mode, volume, mute)
    /// only when `full` is set, which the poll loop does every third second.
    func refreshSelected(includeQueue: Bool = false, full: Bool = true) async {
        guard let group = selectedGroup else { return }
        let coordinator = group.coordinator
        do {
            async let transport = client.transportState(coordinator)
            async let position = client.positionInfo(coordinator)

            var state = nowPlaying[group.id] ?? NowPlaying()
            let p = try await position
            state.transport = try await transport
            state.track = p.metadata
            state.trackNumber = p.trackNumber
            state.trackURI = p.trackURI
            state.duration = p.duration
            state.elapsed = p.elapsed
            state.sampledAt = Date()

            if full || nowPlaying[group.id] == nil {
                async let source = client.currentSourceURI(coordinator)
                async let mode = client.playMode(coordinator)
                async let volume = client.groupVolume(coordinator)
                async let muted = client.groupMute(coordinator)
                state.sourceURI = try await source
                state.playMode = try await mode
                let v = try await volume
                let m = try await muted
                if Date() > userEditingUntil {
                    state.volume = v
                    state.muted = m
                }
            }
            // While the user is dragging the volume, keep their value.
            if Date() <= userEditingUntil, let previous = nowPlaying[group.id] {
                state.volume = previous.volume
                state.muted = previous.muted
            }
            guard selectedGroupID == group.id else { return }
            // Publishing re-renders every view showing playback state, so
            // skip polls that only confirm what's already displayed.
            if nowPlaying[group.id].map({ !$0.isEquivalent(to: state) }) ?? true {
                nowPlaying[group.id] = state
            }

            if includeQueue || state.trackNumber != lastQueueTrack {
                lastQueueTrack = state.trackNumber
                await refreshQueue()
            }
        } catch {
            log.error("\(group.name): \(error.localizedDescription)")
        }
    }

    private func refreshOthers() async {
        for group in groups where group.id != selectedGroupID {
            await refreshOther(group)
        }
    }

    private func refreshOther(_ group: SonosGroup) async {
        do {
                async let transport = client.transportState(group.coordinator)
                async let position = client.positionInfo(group.coordinator)
                var state = nowPlaying[group.id] ?? NowPlaying()
                state.transport = try await transport
                let p = try await position
                state.track = p.metadata
                state.elapsed = p.elapsed
                state.duration = p.duration
                state.sampledAt = Date()
                if nowPlaying[group.id].map({ !$0.isEquivalent(to: state) }) ?? true {
                    nowPlaying[group.id] = state
                }
            } catch {
                // Players briefly go away while regrouping; the next topology refresh will sort it out.
            }
    }

    /// Set by the queue panel; the queue isn't fetched while it's hidden.
    var queueVisible = false {
        didSet { if queueVisible && !oldValue { Task { await refreshQueue() } } }
    }
    @ObservationIgnored private var queueUpdateID: String?

    /// Reloads the visible queue window, but only when the queue changed or
    /// the current track left the loaded window. A 1-item probe returns the
    /// queue's change counter cheaply.
    func refreshQueue() async {
        guard queueVisible, let coordinator = selectedGroup?.coordinator else { return }
        do {
            let current = self.current.trackNumber
            let probe = try await client.queue(coordinator, start: 0, count: 1)
            // The list starts at the current track, so reload when the queue
            // changed or playback moved on.
            if probe.updateID == queueUpdateID, queue.first?.position == max(1, current) {
                log.debug("Queue: unchanged (update \(probe.updateID), track \(current))")
                return
            }
            let detail = "update \(queueUpdateID ?? "-") -> \(probe.updateID), track \(current)"
            log.debug("Queue: reload (\(detail))")
            // Show the current track and what's coming up, not the whole
            // (often thousands of tracks long) queue.
            let page = try await client.queue(coordinator, start: max(0, current - 1), count: 50)
            queueUpdateID = page.updateID
            if page.items != queue { queue = page.items }
            if page.totalMatches != queueTotal { queueTotal = page.totalMatches }
        } catch {
            log.error("Queue: \(error.localizedDescription)")
        }
    }

    func refreshMemberVolumes() async {
        guard let group = selectedGroup else { return }
        for member in group.members {
            if let v = try? await client.volume(member) { memberVolumes[member.id] = v }
        }
    }

    // MARK: Events

    private struct SubscriptionKey: Hashable {
        let playerID: String
        let service: String
    }

    private struct Subscription {
        let player: SonosPlayer
        let service: SonosService
        var sid: String
        var renewAt: Date
    }

    @ObservationIgnored private var eventListener: SonosEventListener?
    @ObservationIgnored private var listenerFailed = false
    @ObservationIgnored private var subscriptions: [SubscriptionKey: Subscription] = [:]
    @ObservationIgnored private var keyForSID: [String: SubscriptionKey] = [:]
    @ObservationIgnored private var pendingEventWork: Set<String> = []
    /// True while every wanted subscription is live; polling then drops to a
    /// slow safety net.
    @ObservationIgnored private(set) var eventsActive = false

    /// The subscriptions we want: every group's transport (for the sidebar),
    /// plus volume, queue and topology for the selected group.
    private func wantedSubscriptions() -> [(SonosPlayer, SonosService)] {
        var wanted = groups.map { ($0.coordinator, SonosService.avTransport) }
        if let selected = selectedGroup?.coordinator {
            wanted += [(selected, .groupRenderingControl), (selected, .contentDirectory), (selected, .zoneGroupTopology)]
        }
        return wanted
    }

    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var resyncRequested = false

    /// Brings subscriptions in line with the current groups and selection.
    /// Runs one pass at a time; a request during a pass triggers another.
    private func syncSubscriptions() async {
        guard !syncing else { resyncRequested = true; return }
        syncing = true
        defer { syncing = false }
        repeat {
            resyncRequested = false
            await syncSubscriptionsPass()
        } while resyncRequested
    }

    private func syncSubscriptionsPass() async {
        if eventListener == nil && !listenerFailed {
            do {
                eventListener = try await SonosEventListener.start { [weak self] sid in
                    Task { @MainActor in self?.handleEvent(sid: sid) }
                }
                log.info("Listening for Sonos events on port \(eventListener?.port ?? 0)")
            } catch {
                listenerFailed = true
                log.error("Event listener failed, falling back to polling: \(error.localizedDescription)")
            }
        }
        guard let listener = eventListener else { eventsActive = false; return }

        let wanted = wantedSubscriptions()
        let wantedKeys = Set(wanted.map { SubscriptionKey(playerID: $0.0.id, service: $0.1.name) })

        for (key, sub) in subscriptions where !wantedKeys.contains(key) {
            subscriptions[key] = nil
            keyForSID[sub.sid] = nil
            await client.unsubscribe(sub.player.baseURL, sub.service, sid: sub.sid)
        }

        var allLive = true
        for (player, service) in wanted {
            let key = SubscriptionKey(playerID: player.id, service: service.name)
            guard subscriptions[key] == nil else { continue }
            guard let local = SonosEventListener.localAddress(toward: player.host),
                  let callback = URL(string: "http://\(local):\(listener.port)/notify") else {
                allLive = false
                continue
            }
            do {
                let result = try await client.subscribe(player.baseURL, service, callback: callback)
                subscriptions[key] = Subscription(player: player, service: service, sid: result.sid,
                                                  renewAt: Date().addingTimeInterval(result.timeout / 2))
                keyForSID[result.sid] = key
            } catch {
                allLive = false
                log.error("Subscribe \(service.name) on \(player.roomName): \(error.localizedDescription)")
            }
        }
        let wasActive = eventsActive
        eventsActive = allLive && !wanted.isEmpty
        if eventsActive != wasActive {
            log.info(eventsActive ? "Using Sonos events (\(subscriptions.count) subscriptions)" : "Sonos events unavailable, polling")
        }
    }

    /// Cancels all event subscriptions so the speakers stop calling this
    /// app (called on quit; otherwise they'd keep trying for up to 30 minutes).
    func unsubscribeAll() async {
        let all = subscriptions.values
        subscriptions = [:]
        keyForSID = [:]
        eventsActive = false
        await withTaskGroup(of: Void.self) { group in
            for sub in all {
                group.addTask { await self.client.unsubscribe(sub.player.baseURL, sub.service, sid: sub.sid) }
            }
        }
        eventListener?.stop()
        log.info("Cancelled \(all.count) event subscriptions")
    }

    /// Renews subscriptions halfway through their lifetime and retries
    /// missing ones.
    private func maintainSubscriptions() async {
        guard eventListener != nil else { return }
        for (key, sub) in subscriptions where sub.renewAt < Date() {
            do {
                let result = try await client.renew(sub.player.baseURL, sub.service, sid: sub.sid)
                subscriptions[key]?.renewAt = Date().addingTimeInterval(result.timeout / 2)
            } catch {
                // Expired or the player restarted: drop it so the sync below resubscribes.
                subscriptions[key] = nil
                keyForSID[sub.sid] = nil
            }
        }
        if !eventsActive || subscriptions.count != wantedSubscriptions().count {
            await syncSubscriptions()
        }
    }

    /// A player reported a change. Coalesce bursts, then re-read only the
    /// affected state.
    private func handleEvent(sid: String) {
        guard let key = keyForSID[sid] else { return }
        let room = groups.flatMap(\.members).first { $0.id == key.playerID }?.roomName ?? key.playerID
        log.debug("Event: \(key.service) from \(room)")
        let selectedCoordinator = selectedGroup?.coordinator.id
        let work: String
        switch key.service {
        case SonosService.zoneGroupTopology.name: work = "topology"
        case SonosService.contentDirectory.name: work = "queue"
        case SonosService.groupRenderingControl.name: work = "selected"
        default: work = key.playerID == selectedCoordinator ? "selected" : "other:\(key.playerID)"
        }
        guard pendingEventWork.insert(work).inserted else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            pendingEventWork.remove(work)
            switch work {
            case "topology": await refreshTopology()
            case "queue": await refreshQueue()
            case "selected": await refreshSelected()
            default:
                if let group = groups.first(where: { "other:\($0.id)" == work }) { await refreshOther(group) }
            }
        }
    }

    // MARK: Transport

    private func perform(_ label: String, _ operation: (SonosPlayer) async throws -> Void) async {
        guard let coordinator = selectedGroup?.coordinator else { return }
        do {
            try await operation(coordinator)
        } catch {
            report("\(label) failed", error)
        }
        await refreshSelected()
    }

    func togglePlayPause() async {
        let playing = current.transport.isPlaying
        mutateCurrent {
            $0.elapsed = $0.elapsed(at: Date())
            $0.sampledAt = Date()
            $0.transport = playing ? .paused : .playing
        }
        await perform(playing ? "Pause" : "Play") { playing ? try await client.pause($0) : try await client.play($0) }
    }

    func next() async { await perform("Next") { try await client.next($0) } }
    func previous() async { await perform("Previous") { try await client.previous($0) } }

    func seek(to seconds: TimeInterval) async {
        mutateCurrent { $0.elapsed = seconds; $0.sampledAt = Date() }
        await perform("Seek") { try await client.seek($0, to: seconds) }
    }

    func toggleShuffle() async {
        var mode = current.playMode
        mode.shuffle.toggle()
        mutateCurrent { $0.playMode = mode }
        await perform("Shuffle") { try await client.setPlayMode($0, mode) }
    }

    func cycleRepeat() async {
        var mode = current.playMode
        mode.repeat = switch mode.repeat { case .off: .all; case .all: .one; case .one: .off }
        mutateCurrent { $0.playMode = mode }
        await perform("Repeat") { try await client.setPlayMode($0, mode) }
    }

    // MARK: Volume

    /// Updates the slider immediately and sends the change after a short
    /// debounce so dragging doesn't flood the player.
    func setGroupVolume(_ volume: Int) {
        userEditingUntil = Date().addingTimeInterval(2)
        mutateCurrent { $0.volume = volume }
        guard let coordinator = selectedGroup?.coordinator else { return }
        volumeTask?.cancel()
        volumeTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            do { try await client.setGroupVolume(coordinator, volume) } catch { report("Volume", error) }
        }
    }

    func nudgeVolume(by delta: Int) {
        setGroupVolume(min(100, max(0, current.volume + delta)))
    }

    func setMemberVolume(_ player: SonosPlayer, _ volume: Int) {
        userEditingUntil = Date().addingTimeInterval(2)
        memberVolumes[player.id] = volume
        volumeTask?.cancel()
        volumeTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            do { try await client.setVolume(player, volume) } catch { report("Volume", error) }
        }
    }

    func toggleMute() async {
        let muted = !current.muted
        userEditingUntil = Date().addingTimeInterval(2)
        mutateCurrent { $0.muted = muted }
        await perform("Mute") { try await client.setGroupMute($0, muted) }
    }

    // MARK: Queue

    func playQueue(at position: Int) async {
        await perform("Play from queue") { try await client.playFromQueue($0, position: position) }
    }

    func removeFromQueue(_ position: Int) async {
        await perform("Remove from queue") { try await client.removeFromQueue($0, position: position) }
        await refreshQueue()
    }

    func clearQueue() async {
        await perform("Clear queue") { try await client.clearQueue($0) }
        await refreshQueue()
    }

    // MARK: Spotify

    /// Replaces the queue with a Spotify album or playlist and plays it,
    /// either in order from the first track or shuffled from a random track.
    func playCollection(uri: String, title: String, shuffled: Bool) async {
        guard let coordinator = selectedGroup?.coordinator else {
            lastError = "Pick a room first."
            return
        }
        do {
            try await client.clearQueue(coordinator)
            let result = try await client.enqueueSpotify(uri, title: title, on: coordinator, preferredRegion: settings.spotifyRegion)
            remember(result.region)
            try await applyShuffle(shuffled, on: coordinator)
            let start = shuffled
                ? result.firstPosition + Int.random(in: 0..<max(1, result.count))
                : result.firstPosition
            try await client.playFromQueue(coordinator, position: start)
            log.info("\(shuffled ? "Shuffle" : "Play") \(title) (\(result.count) tracks) on \(selectedGroup?.name ?? "?")")
        } catch let error as SonosError where error.upnpCode == 800 || error.upnpCode == 804 {
            report("Couldn't play \"\(title)\"", error, hint: "Check that Spotify is added in the Sonos app (Settings › Services & Voice) and that the item is available in your region.")
        } catch {
            report("Couldn't play \"\(title)\"", error)
        }
        await refreshSelected(includeQueue: true)
    }

    /// Replaces the queue with individual tracks (for lists Sonos can't expand
    /// itself, like Liked Songs). Starts playing after the first one is queued.
    func playTracks(_ tracks: [(uri: String, title: String)], shuffled: Bool) async {
        guard let coordinator = selectedGroup?.coordinator, !tracks.isEmpty else { return }
        let ordered = shuffled ? tracks.shuffled() : tracks
        var region = settings.spotifyRegion
        do {
            try await client.clearQueue(coordinator)
            try await applyShuffle(shuffled, on: coordinator)
            for (index, track) in ordered.enumerated() {
                let result = try await client.enqueueSpotify(track.uri, title: track.title, on: coordinator, preferredRegion: region)
                region = result.region
                if index == 0 { try await client.playFromQueue(coordinator, position: result.firstPosition) }
            }
            remember(region)
            log.info("Queued \(ordered.count) tracks on \(selectedGroup?.name ?? "?")")
        } catch {
            report("Couldn't queue tracks", error)
        }
        await refreshSelected(includeQueue: true)
    }

    /// Sets shuffle on or off, keeping the current repeat setting.
    private func applyShuffle(_ shuffled: Bool, on coordinator: SonosPlayer) async throws {
        var mode = current.playMode
        mode.shuffle = shuffled
        try await client.setPlayMode(coordinator, mode)
        mutateCurrent { $0.playMode = mode }
    }

    private func remember(_ region: SpotifyOnSonos.Region) {
        guard region != settings.spotifyRegion else { return }
        log.info("Spotify service \(settings.spotifyRegion.rawValue) was rejected; \(region.rawValue) worked, so using it from now on")
        settings.spotifyRegion = region
    }

    // MARK: Helpers

    private func mutateCurrent(_ change: (inout NowPlaying) -> Void) {
        guard let id = selectedGroupID else { return }
        var state = nowPlaying[id] ?? NowPlaying()
        change(&state)
        nowPlaying[id] = state
    }

    private func report(_ context: String, _ error: Error, hint: String? = nil) {
        let message = "\(context): \(error.localizedDescription)"
        log.error(message)
        lastError = [message, hint].compactMap { $0 }.joined(separator: "\n\n")
    }
}
