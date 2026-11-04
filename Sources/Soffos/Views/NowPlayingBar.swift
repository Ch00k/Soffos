import SonosKit
import SwiftUI

/// The playback footer: a thin seek bar along the top edge, then one row with
/// the track, the transport buttons and the volume.
struct NowPlayingBar: View {
    @Environment(SonosStore.self) private var sonos
    /// Widths of the open side panels, so the seek bar's time labels sit
    /// over the main pane rather than over a panel.
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0

    var body: some View {
        let state = sonos.current
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Artwork(url: state.track?.albumArtURL, cornerRadius: 4)
                    .frame(width: 34, height: 34)
                TrackSummary(state: state)
                AddToPlaylistMenu()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TransportButtons()
                .fixedSize()

            VolumeControl()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 7)
        .background(.bar)
        .overlay(alignment: .top) { SeekBar(leadingInset: leadingInset, trailingInset: trailingInset) }
        .disabled(sonos.selectedGroup == nil)
    }
}

/// The footer's title and artist line. When either is cut off, hovering
/// shows the whole track in a popover.
private struct TrackSummary: View {
    let state: NowPlaying
    @State private var shownWidth: CGFloat = 0
    @State private var fullWidth: CGFloat = 0
    @State private var hovering = false
    @State private var showingDetails = false

    var body: some View {
        lines
            .lineLimit(1)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { shownWidth = $0 }
            .background {
                lines
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fullWidth = $0 }
            }
            .onHover { inside in
                hovering = inside
                guard inside else {
                    showingDetails = false
                    return
                }
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    if hovering && fullWidth > shownWidth + 1 {
                        showingDetails = true
                    }
                }
            }
            .popover(isPresented: $showingDetails, arrowEdge: .top) {
                TrackCard(state: state)
            }
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(state.displayTitle)
                .font(.callout.weight(.semibold))
            Text(state.displaySubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The playing track in full: cover, title, artist and album.
private struct TrackCard: View {
    let state: NowPlaying

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Artwork(url: state.track?.albumArtURL, cornerRadius: 6)
                .frame(width: 64, height: 64)
            // Title, artist and album each get their own weight, size or colour.
            VStack(alignment: .leading, spacing: 3) {
                Text(state.displayTitle)
                    .font(.headline)
                if let artist = nonEmpty(state.track?.artist) {
                    Text(artist)
                }
                if let album = nonEmpty(state.track?.album) {
                    Text(album)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let stream = nonEmpty(state.track?.streamContent) {
                    Text(stream)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    private func nonEmpty(_ text: String?) -> String? {
        text.flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct TransportButtons: View {
    @Environment(SonosStore.self) private var sonos

    var body: some View {
        let state = sonos.current
        HStack(spacing: 14) {
            Button { Task { await sonos.toggleShuffle() } } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(state.playMode.shuffle ? Color.accentColor : .secondary)
            }
            .help("Shuffle")

            Button { Task { await sonos.previous() } } label: {
                Image(systemName: "backward.fill")
            }
            .help("Previous")

            Button { Task { await sonos.togglePlayPause() } } label: {
                Image(systemName: state.transport.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 24))
                    .contentTransition(.symbolEffect(.replace))
            }
            .help(state.transport.isPlaying ? "Pause" : "Play")

            Button { Task { await sonos.next() } } label: {
                Image(systemName: "forward.fill")
            }
            .help("Next")

            Button { Task { await sonos.cycleRepeat() } } label: {
                Image(systemName: state.playMode.repeat == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(state.playMode.repeat == .off ? .secondary : Color.accentColor)
            }
            .help("Repeat")
        }
        .font(.system(size: 13))
        .buttonStyle(.borderless)
    }
}

/// A thin progress line on the footer's top edge. Hovering thickens it and
/// shows the times; click or drag to seek.
struct SeekBar: View {
    @Environment(SonosStore.self) private var sonos
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0
    @State private var hovering = false
    @State private var dragValue: Double?

    var body: some View {
        let state = sonos.current
        let active = hovering || dragValue != nil
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = dragValue ?? state.elapsed(at: context.date)
            let fraction = state.duration > 0 ? min(1, max(0, elapsed / state.duration)) : 0
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.quaternary)
                    Rectangle().fill(Color.accentColor).frame(width: geo.size.width * fraction)
                }
                .frame(height: active ? 5 : 3)
                .frame(maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard state.duration > 0 else { return }
                            dragValue = min(1, max(0, value.location.x / geo.size.width)) * state.duration
                        }
                        .onEnded { _ in
                            guard let target = dragValue else { return }
                            Task {
                                await sonos.seek(to: target)
                                dragValue = nil
                            }
                        }
                )
            }
            .frame(height: 10)
            .overlay(alignment: .bottom) {
                if active && state.duration > 0 {
                    HStack {
                        timeLabel(formatTime(elapsed))
                        Spacer()
                        timeLabel(formatTime(state.duration))
                    }
                    .padding(.leading, leadingInset + 6)
                    .padding(.trailing, trailingInset + 6)
                    .offset(y: -18)
                    .allowsHitTesting(false)
                }
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: active)
    }

    private func timeLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.regularMaterial, in: Capsule())
    }
}

struct VolumeControl: View {
    @Environment(SonosStore.self) private var sonos
    @State private var showMembers = false

    var body: some View {
        let state = sonos.current
        HStack(spacing: 4) {
            Button { Task { await sonos.toggleMute() } } label: {
                Image(systemName: volumeIcon(state))
                    .frame(width: 18)
            }
            .help(state.muted ? "Unmute" : "Mute")

            StepButton(symbol: "minus", help: "Volume down") { sonos.nudgeVolume(by: -1) }
            Slider(value: Binding(
                get: { Double(state.volume) },
                set: { sonos.setGroupVolume(Int($0.rounded())) }
            ), in: 0...100)
            .controlSize(.mini)
            .frame(minWidth: 44, maxWidth: 100)
            StepButton(symbol: "plus", help: "Volume up") { sonos.nudgeVolume(by: 1) }

            Text("\(state.volume)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            if (sonos.selectedGroup?.members.count ?? 0) > 1 {
                Button { showMembers.toggle() } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("Room volumes")
                .popover(isPresented: $showMembers, arrowEdge: .top) {
                    MemberVolumes().padding().frame(width: 300)
                }
            }
        }
        .buttonStyle(.borderless)
    }

    private func volumeIcon(_ state: NowPlaying) -> String {
        if state.muted || state.volume == 0 { return "speaker.slash.fill" }
        return state.volume < 33 ? "speaker.wave.1.fill" : state.volume < 66 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

/// A small -/+ button for one-step volume changes.
private struct StepButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

struct MemberVolumes: View {
    @Environment(SonosStore.self) private var sonos

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(sonos.selectedGroup?.members ?? []) { member in
                let volume = sonos.memberVolumes[member.id] ?? 0
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.roomName).font(.callout)
                    HStack(spacing: 4) {
                        StepButton(symbol: "minus", help: "Volume down") { sonos.setMemberVolume(member, max(0, volume - 1)) }
                        Slider(value: Binding(
                            get: { Double(volume) },
                            set: { sonos.setMemberVolume(member, Int($0.rounded())) }
                        ), in: 0...100)
                        .controlSize(.small)
                        StepButton(symbol: "plus", help: "Volume up") { sonos.setMemberVolume(member, min(100, volume + 1)) }
                        Text("\(volume)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                    }
                }
            }
        }
        .task { await sonos.refreshMemberVolumes() }
    }
}
