import Foundation
import CoreBluetooth

/// A ring seen while scanning (iOS identifies peripherals by a per-phone UUID, never by MAC).
struct DiscoveredRing: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var advertisesRingService: Bool
}

/// BLE transport on CoreBluetooth (replaces the Nordic Android-BLE-Library `NordicTransport`).
///
/// Owns all GATT plumbing: connect (with timeout + retries), service/characteristic discovery,
/// notification subscriptions and a serialized write queue. `RingSession` stays the protocol
/// brain: it builds/parses the AA55 frames and drives the auth handshake through the events it
/// receives from here. Everything runs on the main queue.
///
/// What iOS does differently from Android:
///  * no MAC addresses and no "bonded devices" list – a ring is picked from a scan (or found
///    again by its saved peripheral UUID);
///  * the ATT MTU cannot be requested – iOS negotiates it, so frames are re-assembled if split;
///  * pairing/bonding is triggered by the system when an encrypted characteristic is touched.
final class BLETransport: NSObject, RingLink {
    static let svcUUID = CBUUID(string: "b75497db-806e-42b1-9e60-5871ca2e504b")
    static let authUUID = CBUUID(string: "b75497de-806e-42b1-9e60-5871ca2e504b")
    static let ctrlWUUID = CBUUID(string: "b75497dc-806e-42b1-9e60-5871ca2e504b")
    static let ctrlNUUID = CBUUID(string: "b75497dd-806e-42b1-9e60-5871ca2e504b")
    static let dsvcUUID = CBUUID(string: "e49a3001-f69a-11e8-8eb2-f2801f1b9fd1")
    static let dataNUUID = CBUUID(string: "e49a3003-f69a-11e8-8eb2-f2801f1b9fd1")

    private static let connectTimeoutSeconds = 15.0
    private static let fragmentFlushSeconds = 0.15

    weak var session: RingSession?
    var onLog: (String) -> Void = { _ in }
    var onDiscovered: ([DiscoveredRing]) -> Void = { _ in }
    /// A human-readable Bluetooth problem (off / not authorized / unsupported), or nil when fine.
    var onBluetoothProblem: (String?) -> Void = { _ in }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?

    // connection attempt
    private var pendingConnectID: UUID?
    private var waitingForPower = false
    private var retriesLeft = 0
    private var connectTimeout: DispatchWorkItem?
    private var scanningForTarget = false

    // discovery list (Settings ▸ Choose ring)
    private var wantDiscovery = false
    private var discovered: [UUID: DiscoveredRing] = [:]

    // GATT
    private var authCh: CBCharacteristic?
    private var ctrlWCh: CBCharacteristic?
    private var ctrlNCh: CBCharacteristic?
    private var dataNCh: CBCharacteristic?
    private var discoveriesPending = 0
    private var notifyChain: [CBCharacteristic] = []
    private var notifyDone: (() -> Void)?
    private var writeQueue: [(char: CBCharacteristic, data: Data)] = []
    private var writing = false

    private final class Channel {
        var assembler = FrameAssembler()
        var flushItem: DispatchWorkItem?
    }
    private let authChannel = Channel()
    private let ctrlChannel = Channel()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: nil)
    }

    private func log(_ m: String) {
        onLog("[ble] " + m)
    }

    // MARK: - RingLink

    func connect(peripheralID: String) {
        guard let uuid = UUID(uuidString: peripheralID) else {
            log("invalid peripheral id \(peripheralID)")
            session?.onDisconnected()
            return
        }
        pendingConnectID = uuid
        retriesLeft = 2
        armTimeout()
        attemptConnect()
    }

    func disconnect() {
        connectTimeout?.cancel()
        pendingConnectID = nil
        waitingForPower = false
        if scanningForTarget {
            scanningForTarget = false
            updateScan()
        }
        guard let p = peripheral else {
            session?.onDisconnected()
            return
        }
        if p.state == .connected {
            central.cancelPeripheralConnection(p)   // didDisconnectPeripheral → session.onDisconnected
        } else {
            // still connecting: iOS does not reliably call back for a cancelled attempt
            resetLinkState()
            central.cancelPeripheralConnection(p)
            session?.onDisconnected()
        }
    }

    func writeAuth(_ frame: [UInt8]) {
        if let ch = authCh { enqueueWrite(ch, frame) }
    }

    func writeCtrl(_ frame: [UInt8]) {
        if let ch = ctrlWCh { enqueueWrite(ch, frame) }
    }

    /// After auth: subscribe CTRL-notify (+ DATA when present), then signal `onControlReady`.
    func enableControlChannels() {
        guard let n = ctrlNCh else { return }
        var chars = [n]
        if let d = dataNCh { chars.append(d) }
        enableNotifications(chars) { [weak self] in self?.session?.onControlReady() }
    }

    // MARK: - discovery (for choosing a ring)

    func startDiscovery() {
        wantDiscovery = true
        discovered = [:]
        if central.state == .poweredOn {
            for p in central.retrieveConnectedPeripherals(withServices: [BLETransport.svcUUID]) {
                discovered[p.identifier] = DiscoveredRing(
                    id: p.identifier, name: p.name ?? "(unnamed)", rssi: 0, advertisesRingService: true)
            }
        }
        publishDiscovered()
        updateScan()
    }

    func stopDiscovery() {
        wantDiscovery = false
        updateScan()
    }

    private func publishDiscovered() {
        let list = discovered.values.sorted { a, b in
            if a.advertisesRingService != b.advertisesRingService { return a.advertisesRingService }
            return a.rssi > b.rssi
        }
        onDiscovered(list)
    }

    private func updateScan() {
        guard central.state == .poweredOn else { return }
        if wantDiscovery || scanningForTarget {
            central.scanForPeripherals(withServices: nil, options: nil)
        } else if central.isScanning {
            central.stopScan()
        }
    }

    // MARK: - connecting

    private func attemptConnect() {
        switch central.state {
        case .poweredOn:
            break
        case .unknown, .resetting:
            log("Bluetooth not ready yet – waiting")
            waitingForPower = true
            return
        default:
            log("Bluetooth unavailable (state \(central.state.rawValue))")
            failConnect()
            return
        }
        guard let uuid = pendingConnectID else { return }
        if let p = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            start(p)
        } else {
            log("ring not known to this iPhone yet – scanning for it")
            scanningForTarget = true
            updateScan()
        }
    }

    private func start(_ p: CBPeripheral) {
        resetGattState()
        peripheral = p
        p.delegate = self
        log("connecting \(p.name ?? "?") \(p.identifier.uuidString)")
        central.connect(p, options: nil)
        armTimeout()
    }

    private func armTimeout() {
        connectTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.log("connect timeout")
            self?.failConnect()
        }
        connectTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + BLETransport.connectTimeoutSeconds, execute: item)
    }

    /// Gives up on the current attempt (or a half-set-up link) and tells the session.
    private func failConnect() {
        connectTimeout?.cancel()
        pendingConnectID = nil
        waitingForPower = false
        if scanningForTarget {
            scanningForTarget = false
            updateScan()
        }
        let p = peripheral
        resetLinkState()
        if let p = p { central.cancelPeripheralConnection(p) }
        session?.onDisconnected()
    }

    private func resetLinkState() {
        peripheral = nil
        resetGattState()
    }

    /// Everything tied to one GATT session (characteristics, queues, partial frames) — not the peripheral itself.
    private func resetGattState() {
        authCh = nil
        ctrlWCh = nil
        ctrlNCh = nil
        dataNCh = nil
        discoveriesPending = 0
        notifyChain = []
        notifyDone = nil
        writeQueue = []
        writing = false
        authChannel.assembler.reset()
        ctrlChannel.assembler.reset()
        authChannel.flushItem?.cancel()
        ctrlChannel.flushItem?.cancel()
    }

    // MARK: - notifications + writes (serialized, like the Nordic library's request queue)

    private func enableNotifications(_ chars: [CBCharacteristic], done: @escaping () -> Void) {
        notifyChain = chars
        notifyDone = done
        pumpNotify()
    }

    private func pumpNotify() {
        guard let p = peripheral else { return }
        if let next = notifyChain.first {
            p.setNotifyValue(true, for: next)
        } else if let done = notifyDone {
            notifyDone = nil
            done()
        }
    }

    private func enqueueWrite(_ ch: CBCharacteristic, _ frame: [UInt8]) {
        writeQueue.append((char: ch, data: Data(frame)))
        pumpWrite()
    }

    private func pumpWrite() {
        guard !writing, let p = peripheral, !writeQueue.isEmpty else { return }
        let item = writeQueue.removeFirst()
        if item.char.properties.contains(.write) {
            writing = true
            p.writeValue(item.data, for: item.char, type: .withResponse)   // = Android WRITE_TYPE_DEFAULT
        } else if item.char.properties.contains(.writeWithoutResponse) {
            p.writeValue(item.data, for: item.char, type: .withoutResponse)
            pumpWrite()
        } else {
            log("characteristic \(item.char.uuid) is not writable")
            pumpWrite()
        }
    }

    // MARK: - receiving

    private func receive(_ bytes: [UInt8], on channel: Channel, from p: CBPeripheral,
                         handler: @escaping ([UInt8]) -> Void) {
        channel.flushItem?.cancel()
        // A sender only splits a frame when it ran out of room, i.e. the chunk used the whole payload.
        let payload = max(p.maximumWriteValueLength(for: .withoutResponse), 20)
        for frame in channel.assembler.feed(bytes, maybeFragment: bytes.count >= payload) {
            handler(frame)
        }
        if channel.assembler.hasPartial {
            let item = DispatchWorkItem { [weak channel] in
                if let channel = channel, let frame = channel.assembler.flush() { handler(frame) }
            }
            channel.flushItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + BLETransport.fragmentFlushSeconds, execute: item)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            onBluetoothProblem(nil)
            if waitingForPower {
                waitingForPower = false
                attemptConnect()
            }
            updateScan()
        case .poweredOff:
            onBluetoothProblem("Bluetooth is turned off.")
            dropLinkIfActive()
        case .unauthorized:
            onBluetoothProblem("Bluetooth access is denied. Enable it in Settings ▸ VoxLibre.")
            dropLinkIfActive()
        case .unsupported:
            onBluetoothProblem("This device does not support Bluetooth LE.")
        default:
            break
        }
    }

    /// iOS does not reliably deliver `didDisconnectPeripheral` when Bluetooth goes away; make sure the
    /// session never stays "active" on a link that no longer exists.
    private func dropLinkIfActive() {
        if peripheral != nil || session?.isActive == true { failConnect() }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if scanningForTarget, p.identifier == pendingConnectID {
            scanningForTarget = false
            updateScan()
            start(p)
            return
        }
        guard wantDiscovery else { return }
        let adName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = p.name ?? adName ?? ""
        let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        discovered[p.identifier] = DiscoveredRing(
            id: p.identifier,
            name: name.isEmpty ? "(unnamed)" : name,
            rssi: RSSI.intValue,
            advertisesRingService: uuids.contains(BLETransport.svcUUID))
        publishDiscovered()
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        guard p.identifier == peripheral?.identifier else { return }
        connectTimeout?.cancel()
        pendingConnectID = nil
        log("connected, MTU payload ≈ \(p.maximumWriteValueLength(for: .withoutResponse)) B")
        session?.onConnected()
        p.discoverServices([BLETransport.svcUUID, BLETransport.dsvcUUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        log("connect failed: \(error?.localizedDescription ?? "unknown")")
        if retriesLeft > 0 {
            retriesLeft -= 1
            peripheral = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.attemptConnect()
            }
            return
        }
        failConnect()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        log("disconnected" + (error.map { ": " + $0.localizedDescription } ?? ""))
        connectTimeout?.cancel()
        resetLinkState()
        session?.onDisconnected()
    }
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }   // late callback of a dead link
        if let e = error {
            log("service discovery failed: \(e.localizedDescription)")
            failConnect()
            return
        }
        let services = p.services ?? []
        guard !services.isEmpty else {
            log("service not found")
            failConnect()
            return
        }
        discoveriesPending = services.count
        for s in services { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }   // late callback of a dead link
        if let e = error { log("characteristic discovery failed for \(service.uuid): \(e.localizedDescription)") }
        discoveriesPending -= 1
        guard discoveriesPending <= 0 else { return }

        let main = p.services?.first { $0.uuid == BLETransport.svcUUID }
        authCh = main?.characteristics?.first { $0.uuid == BLETransport.authUUID }
        ctrlWCh = main?.characteristics?.first { $0.uuid == BLETransport.ctrlWUUID }
        ctrlNCh = main?.characteristics?.first { $0.uuid == BLETransport.ctrlNUUID }
        let ds = p.services?.first { $0.uuid == BLETransport.dsvcUUID }
        dataNCh = ds?.characteristics?.first { $0.uuid == BLETransport.dataNUUID }

        guard let auth = authCh, ctrlWCh != nil, ctrlNCh != nil else {
            log("service not found")
            failConnect()
            return
        }
        enableNotifications([auth]) { [weak self] in self?.session?.onAuthReady() }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }   // late callback of a dead link
        if let e = error {
            log("enabling notifications failed for \(ch.uuid): \(e.localizedDescription)")
            failConnect()
            return
        }
        guard let first = notifyChain.first, first.uuid == ch.uuid else { return }
        notifyChain.removeFirst()
        pumpNotify()
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }   // late callback of a dead link
        if let e = error { log("write failed for \(ch.uuid): \(e.localizedDescription)") }
        writing = false
        pumpWrite()
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }   // late callback of a dead link
        if let e = error {
            log("notification error for \(ch.uuid): \(e.localizedDescription)")
            return
        }
        guard let value = ch.value else { return }
        let bytes = [UInt8](value)
        if ch.uuid == BLETransport.authUUID {
            receive(bytes, on: authChannel, from: p) { [weak self] f in self?.session?.onAuthFrame(f) }
        } else if ch.uuid == BLETransport.ctrlNUUID {
            receive(bytes, on: ctrlChannel, from: p) { [weak self] f in self?.session?.onCtrlFrame(f) }
        } else if ch.uuid == BLETransport.dataNUUID {
            session?.onData(bytes)   // raw file stream, not AA55 framed
        }
    }
}
