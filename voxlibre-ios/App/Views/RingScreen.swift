import SwiftUI

struct RingScreen: View {
    @EnvironmentObject var engine: RingEngine

    var body: some View {
        Group {
            if engine.connected {
                connectedBody
            } else {
                EmptyStateView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgContent.ignoresSafeArea())
    }

    private struct Chip: Identifiable {
        let text: String
        let icon: String
        var id: String { return text }
    }

    private var chips: [Chip] {
        var list: [Chip] = []
        if engine.battSt != 0 { list.append(Chip(text: "Charging", icon: "bolt.fill")) }
        if engine.rssiHost > 0 {
            let q = engine.rssiHost <= 60 ? "Strong signal" : (engine.rssiHost <= 75 ? "Medium signal" : "Weak signal")
            list.append(Chip(text: "-\(engine.rssiHost) dBm · \(q)", icon: "cellularbars"))
        }
        if engine.battVolt > 0 {
            list.append(Chip(text: String(format: "%.2f V", Double(engine.battVolt) / 1000.0), icon: "bolt.fill"))
        }
        return list
    }

    private var battColor: Color {
        if engine.battPct <= 15 { return Theme.danger }
        if engine.battPct <= 35 { return Theme.warn }
        return Theme.lime
    }

    private var connectedBody: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // ---- Device ----
                    Text(engine.model.isEmpty ? "Ring" : engine.model)
                        .font(.system(size: 26, weight: .medium))
                        .padding(.bottom, 10)
                    if !engine.sn.isEmpty { KeyValueRow(key: "SN", value: engine.sn) }
                    if !engine.fw.isEmpty { KeyValueRow(key: "Firmware", value: engine.fw) }
                    if !engine.hw.isEmpty { KeyValueRow(key: "Hardware", value: engine.hw) }

                    // ---- Telemetry ----
                    if engine.battPct >= 0 || engine.storTot > 0 || engine.rssiHost > 0 {
                        SectionDivider()
                        if !chips.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8, alignment: .leading)],
                                      alignment: .leading, spacing: 8) {
                                ForEach(chips) { c in
                                    Label(c.text, systemImage: c.icon)
                                        .font(.footnote)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Theme.bgFilter)
                                        .clipShape(Capsule())
                                }
                            }
                            .padding(.bottom, 10)
                        }
                        HStack(alignment: .top, spacing: 16) {
                            MetricView(
                                icon: "battery.100", label: "Battery",
                                value: engine.battPct >= 0 ? "\(engine.battPct)" : "—", unit: "%",
                                valueColor: engine.battPct < 0 ? Theme.text : battColor,
                                progress: engine.battPct >= 0 ? Double(engine.battPct) / 100.0 : nil)
                            MetricView(
                                icon: "internaldrive", label: "Free",
                                value: engine.storTot > 0 ? String(format: "%.1f", Double(engine.storFree) / 1048576.0) : "—",
                                unit: "MB", valueColor: Theme.text,
                                progress: engine.storTot > 0 ? Double(engine.storFree) / Double(engine.storTot) : nil)
                        }
                    }

                    // ---- Events / Gestures ----
                    if !engine.eventText.isEmpty || !engine.gestureText.isEmpty { SectionDivider() }
                    if !engine.eventText.isEmpty { LabeledText(label: "Event", value: engine.eventText) }
                    if !engine.gestureText.isEmpty { LabeledText(label: "Gesture", value: engine.gestureText) }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // ---- Media (pinned to the bottom, above the tab bar) ----
            Divider()
            Toggle("Single click → play/pause recording", isOn: Binding(
                get: { engine.mediaToggle },
                set: { engine.setMedia($0) }))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Theme.bgFilter)
        }
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack {
            Text(key).foregroundColor(Theme.muted)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 3)
    }
}

struct LabeledText: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 11))
                .tracking(1)
                .foregroundColor(Theme.muted)
            Text(value)
        }
        .padding(.vertical, 6)
    }
}

struct SectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(height: 1)
            .padding(.vertical, 14)
    }
}

struct MetricView: View {
    let icon: String
    let label: String
    let value: String
    let unit: String
    let valueColor: Color
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13)).foregroundColor(Theme.muted)
                Text(label.uppercased()).font(.system(size: 11)).tracking(0.5).foregroundColor(Theme.muted)
            }
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 28, weight: .bold)).foregroundColor(valueColor)
                Text(unit).font(.system(size: 12)).foregroundColor(Theme.muted)
            }
            if let p = progress {
                ProgressView(value: min(max(p, 0), 1))
                    .tint(valueColor)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "No ring selected" / "Ring disconnected".
struct EmptyStateView: View {
    @EnvironmentObject var engine: RingEngine
    @State private var picking = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 48))
                .foregroundColor(Theme.muted)
            if engine.configured {
                Text("Ring disconnected").font(.system(size: 18))
                Text("Tap Connect to see the ring data")
                    .font(.footnote)
                    .foregroundColor(Theme.muted)
                    .multilineTextAlignment(.center)
            } else {
                Text("No ring selected").font(.system(size: 18))
                Text("Choose your ring from the Bluetooth scan")
                    .font(.footnote)
                    .foregroundColor(Theme.muted)
                    .multilineTextAlignment(.center)
                Button("Select ring") { picking = true }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
            if let problem = engine.bluetoothProblem {
                Text(problem)
                    .font(.footnote)
                    .foregroundColor(Theme.warn)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 32)
        .sheet(isPresented: $picking) {
            NavigationStack {
                RingPickerView(connectAfterSelect: true) { picking = false }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { picking = false }
                        }
                    }
            }
        }
    }
}
