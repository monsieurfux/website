import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var engine: RingEngine
    @Environment(\.dismiss) private var dismiss

    @State private var bindKey = ""
    @State private var userId = ""
    @State private var macOverride = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        RingPickerView(connectAfterSelect: false) {}
                    } label: {
                        HStack {
                            Text("Ring")
                            Spacer()
                            Text(engine.configured ? (engine.ringName.isEmpty ? "Selected" : engine.ringName) : "None")
                                .foregroundColor(Theme.muted)
                        }
                    }
                } footer: {
                    Text("iOS cannot list paired devices or show Bluetooth addresses, so the ring is picked from a scan.")
                }

                Section {
                    TextField("BIND KEY", text: $bindKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    TextField("USER ID", text: $userId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Pairing credentials")
                } footer: {
                    Text("Minted by Vocci's servers for your account. Enter the values you obtained for your ring. They are stored in the iOS Keychain on this device only.")
                }

                Section {
                    TextField("AA:BB:CC:DD:EE:FF", text: $macOverride)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    if !engine.ringMacFromDevice.isEmpty {
                        HStack {
                            Text("Reported by ring").foregroundColor(Theme.muted)
                            Spacer()
                            Text(engine.ringMacFromDevice).font(.system(.footnote, design: .monospaced))
                        }
                    }
                } header: {
                    Text("Ring MAC (optional)")
                } footer: {
                    Text("The handshake needs the ring's Bluetooth address, which iOS hides. VoxLibre reads it from the ring's own device-info frame. Only fill this in if authentication fails and you know the address (e.g. from the Android app).")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        engine.saveSettings(bindKey: bindKey, userId: userId, macOverride: macOverride)
                        dismiss()
                    }
                }
            }
            .onAppear {
                bindKey = engine.savedBindKey
                userId = engine.savedUserId
                macOverride = engine.savedMacOverride
            }
        }
    }
}

/// Scan list for choosing the ring. The ring must be advertising (not held by another app or phone).
struct RingPickerView: View {
    @EnvironmentObject var engine: RingEngine
    @Environment(\.dismiss) private var dismiss
    let connectAfterSelect: Bool
    let onDone: () -> Void

    var body: some View {
        List {
            if let problem = engine.bluetoothProblem {
                Section {
                    Text(problem).foregroundColor(Theme.warn)
                }
            }
            Section {
                if engine.discovered.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Scanning…").foregroundColor(Theme.muted)
                    }
                }
                ForEach(engine.discovered) { ring in
                    Button {
                        engine.selectRing(ring, connect: connectAfterSelect)
                        onDone()
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ring.name)
                                Text(ring.id.uuidString)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Theme.muted)
                            }
                            Spacer()
                            if ring.advertisesRingService {
                                Image(systemName: "checkmark.seal.fill").foregroundColor(Theme.lime)
                            }
                            if ring.rssi != 0 {
                                Text("\(ring.rssi) dBm").font(.caption).foregroundColor(Theme.muted)
                            }
                        }
                    }
                }
            } footer: {
                Text("Wake the ring and keep it close. It must not be connected to another phone or app. A seal marks devices that advertise the Vocci ring service.")
            }
        }
        .navigationTitle("Select ring")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { engine.startDiscovery() }
        .onDisappear { engine.stopDiscovery() }
    }
}
