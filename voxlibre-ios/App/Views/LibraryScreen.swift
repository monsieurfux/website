import SwiftUI

struct LibraryScreen: View {
    @EnvironmentObject var engine: RingEngine
    @State private var filter = 0   // 0 = all, 1 = on ring, 2 = on phone

    private var items: [Rec] {
        return engine.recordings.filter { r in
            switch filter {
            case 1: return r.onRing
            case 2: return r.savedLocal
            default: return true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if items.isEmpty {
                    Text(engine.recordings.isEmpty ? "No recordings yet" : "Nothing in this filter")
                        .foregroundColor(Theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { r in
                                RecordingRow(rec: r)
                                Divider()
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack(spacing: 8) {
                Picker("Filter", selection: $filter) {
                    Text("All").tag(0)
                    Text("On ring").tag(1)
                    Text("Local").tag(2)
                }
                .pickerStyle(.segmented)
                Button {
                    engine.manualRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!engine.connected)
                .accessibilityLabel("Refresh")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.bgFilter)
        }
        .background(Theme.bgContent.ignoresSafeArea())
    }
}

struct RecordingRow: View {
    @EnvironmentObject var engine: RingEngine
    let rec: Rec

    private var status: String {
        if rec.onRing && rec.savedLocal { return "Synced" }
        return rec.onRing ? "On ring" : "On phone only"
    }

    private var color: Color {
        if rec.onRing && rec.savedLocal { return Theme.info }
        return rec.onRing ? Theme.lime : Theme.muted
    }

    private var isCurrent: Bool { return engine.playingName == rec.name }

    private var detailText: String {
        var s = rec.sizeOpus >= 0 ? "\(rec.sizeOpus) B" : "—"
        if let ms = rec.durationMs { s += " · " + Fmt.duration(ms) }
        return s
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: rec.savedLocal ? "checkmark.circle.fill" : "mic")
                .foregroundColor(color)
                .font(.system(size: 20))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.uppercased())
                    .font(.system(size: 11))
                    .tracking(0.5)
                    .foregroundColor(color)
                Text(Fmt.recordingTime(rec.id)).font(.system(size: 15))
                Text(detailText)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
            }
            Spacer()
            if rec.savedLocal {
                Button {
                    if isCurrent && engine.isPlaying { engine.stopPlay() } else { engine.play(rec.name) }
                } label: {
                    Image(systemName: isCurrent && engine.isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 18))
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(isCurrent && engine.isPlaying ? "Stop" : "Play")
            } else {
                Button {
                    if !engine.connected {
                        engine.showToast("connect the ring")
                    } else if engine.isDownloading {
                        engine.showToast("download in progress")
                    } else {
                        engine.download(rec.name)
                    }
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 20))
                        .foregroundColor(engine.connected ? Theme.lime : Theme.muted)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Download")
            }
            Menu {
                if rec.onRing {
                    Button(role: .destructive) { engine.deleteRing(rec.id) } label: {
                        Label("Delete from ring", systemImage: "trash")
                    }
                    .disabled(!engine.connected)
                }
                if rec.savedLocal {
                    Button(role: .destructive) { engine.deleteLocal(rec.id) } label: {
                        Label("Delete from phone", systemImage: "iphone.slash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 32, height: 36)
                    .foregroundColor(Theme.muted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
