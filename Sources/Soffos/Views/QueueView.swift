import SonosKit
import SwiftUI

struct QueueView: View {
    @Environment(SonosStore.self) private var sonos
    @State private var confirmClear = false

    var body: some View {
        let marker = sonos.queueMarker
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Queue").font(.headline)
                    HStack(spacing: 4) {
                        if sonos.queueingTitle != nil {
                            ProgressView().controlSize(.mini)
                        }
                        Text(queueSummary).lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear") { confirmClear = true }
                    .controlSize(.small)
                    .disabled(sonos.queue.isEmpty)
                    .confirmationDialog("Clear the queue?", isPresented: $confirmClear) {
                        Button("Clear Queue", role: .destructive) { Task { await sonos.clearQueue() } }
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            if sonos.queue.isEmpty {
                Group {
                    if sonos.queueingTitle != nil {
                        ProgressView()
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "list.bullet")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                                .padding(.bottom, 4)
                            Text("Queue Is Empty").font(.headline)
                            Text("Play an album or playlist to fill it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Starts at the current track; no auto-scrolling.
                List(sonos.queue) { item in
                    QueueRow(item: item, isCurrent: item.position == marker.position, isPlaying: marker.playing)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { Task { await sonos.playQueue(at: item.position) } }
                        .contextMenu {
                            Button("Play") { Task { await sonos.playQueue(at: item.position) } }
                            Button("Remove from Queue", role: .destructive) { Task { await sonos.removeFromQueue(item.position) } }
                        }
                }
                .listStyle(.plain)
            }
        }
        .onAppear { sonos.queueVisible = true }
        .onDisappear { sonos.queueVisible = false }
    }
}

extension QueueView {
    private var queueSummary: String {
        if let title = sonos.queueingTitle { return "Adding “\(title)”" }
        let total = sonos.queueTotal
        guard let first = sonos.queue.first?.position, let last = sonos.queue.last?.position,
              sonos.queue.count < total
        else { return total == 1 ? "1 track" : "\(total) tracks" }
        return "\(first)-\(last) of \(total) tracks"
    }
}

private struct QueueRow: View, Equatable {
    let item: QueueItem
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 8) {
            Artwork(url: item.metadata.albumArtURL, cornerRadius: 3)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.metadata.title)
                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(1)
                if let artist = item.metadata.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 1)
    }
}
