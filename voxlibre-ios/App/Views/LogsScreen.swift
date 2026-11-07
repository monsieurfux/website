import SwiftUI

/// Real-time TX/RX of the BLE protocol. Unlike Android, the log is also shown while disconnected:
/// on iOS the interesting failures (wrong MAC, no auth reply) happen before "authenticated".
struct LogsScreen: View {
    @ObservedObject var logs: LogStore
    @EnvironmentObject var engine: RingEngine

    private var shown: [LogLine] {
        return engine.onlyUnmapped ? logs.lines.filter { $0.unmapped } : logs.lines
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                let axes: Axis.Set = engine.wordWrap ? [.vertical] : [.vertical, .horizontal]
                ScrollView(axes) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(line.unmapped ? Theme.lime : Color(hex: 0xB0B6BD))
                                .lineLimit(engine.wordWrap ? nil : 1)
                                .fixedSize(horizontal: !engine.wordWrap, vertical: false)
                                .id(line.id)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: logs.lines.count) { _ in
                    if let last = shown.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            Divider()
            VStack(spacing: 0) {
                Toggle("Unmapped interactions only", isOn: $engine.onlyUnmapped)
                Toggle("Word wrap", isOn: $engine.wordWrap)
                HStack {
                    ShareLink(item: logs.joined) {
                        Label("Share log", systemImage: "square.and.arrow.up")
                    }
                    Spacer()
                    Button(role: .destructive) { logs.clear() } label: {
                        Label("Clear", systemImage: "trash")
                    }
                }
                .font(.subheadline)
                .padding(.top, 6)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.bgFilter)
        }
        .background(Theme.bgContent.ignoresSafeArea())
    }
}
