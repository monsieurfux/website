import Foundation

protocol GestureSink: AnyObject {
    func log(_ m: String)
    func gesture(_ text: String)
    /// Single click with the feature enabled. Android injects a system media key; iOS has no
    /// equivalent, so the app maps this to play/pause of its own recording player.
    func mediaPlayPause()
}

/// Ring button input (ported from `RingGestures.java`).
///
/// Two independent paths:
///  * the 0x26 press stream (a repeating counter while the button is held) becomes
///    PRESSED / SINGLE / DOUBLE / HOLD gestures – a monitor only;
///  * a single click (from 0xf0 / 0x15) optionally triggers play/pause.
final class RingGestures {
    static let holdMs = 700
    static let doubleMs = 400
    static let releaseMs = 300
    static let mediaDebounceMs = 400

    weak var sink: GestureSink?
    private let scheduler: Scheduler

    // 0x26 state machine
    private var lastC26 = -1
    private var lastT26 = 0
    private var pressing = false
    private var pendingSingle = false
    private var pressStart = 0
    private var lastTickT = 0
    private var pressTicks = 0
    private var releaseTask: ScheduledTask?
    private var singleTask: ScheduledTask?

    // play/pause (single click)
    private var mediaToggle = false
    private var lastMediaKey: Int? = nil

    init(scheduler: Scheduler) {
        self.scheduler = scheduler
    }

    func setMediaToggle(_ on: Bool) {
        mediaToggle = on
        sink?.log("play/pause " + (on ? "ON" : "OFF"))
    }

    /// Reset transient state on disconnect.
    func reset() {
        lastC26 = -1
        pressing = false
        pendingSingle = false
        releaseTask?.cancel()
        singleTask?.cancel()
    }

    /// Feed one 0x26 button-pressed tick (payload byte).
    func feed26(_ val: Int) {
        let now = scheduler.nowMs()
        var extra = ""
        if lastC26 >= 0 {
            var dv = val - lastC26
            if dv < 0 { dv += 256 }
            let dt = now - lastT26
            let hz = dt > 0 ? 1000.0 / Double(dt) : 0
            extra = " Δ=\(dv) dt=\(dt)ms ~\(String(format: "%.1f", hz))Hz"
        }
        lastC26 = val
        lastT26 = now
        sink?.log("RX [ctrl] op=0x26 val=\(val) (0x\(String(val, radix: 16)))" + extra)
        trackPress(now)
    }

    private func trackPress(_ t: Int) {
        if !pressing {
            pressing = true
            pressStart = t
            pressTicks = 0
            sink?.gesture("button: PRESSED…")
        }
        pressTicks += 1
        lastTickT = t
        releaseTask?.cancel()
        releaseTask = scheduler.after(ms: RingGestures.releaseMs) { [weak self] in
            self?.onRelease()
        }
    }

    private func onRelease() {
        pressing = false
        let dur = lastTickT - pressStart
        if dur >= RingGestures.holdMs {
            pendingSingle = false
            onGesture("HOLD", "(\(dur)ms, \(pressTicks) ticks)")
        } else if pendingSingle {
            pendingSingle = false
            singleTask?.cancel()
            onGesture("DOUBLE", nil)
        } else {
            pendingSingle = true
            singleTask = scheduler.after(ms: RingGestures.doubleMs) { [weak self] in
                guard let self = self, self.pendingSingle else { return }
                self.pendingSingle = false
                self.onGesture("SINGLE", nil)
            }
        }
    }

    private func onGesture(_ type: String, _ detail: String?) {
        sink?.log("GESTURE(0x26): " + type + (detail.map { " " + $0 } ?? ""))
        sink?.gesture("Last gesture: " + type + (detail.map { "  " + $0 } ?? ""))
    }

    /// A single click (0xf0 / 0x15): fire play/pause when the feature is enabled.
    func singleClick() {
        guard mediaToggle else {
            sink?.log("single click (play/pause feature off)")
            return
        }
        let now = scheduler.nowMs()
        if let last = lastMediaKey, now - last < RingGestures.mediaDebounceMs {
            sink?.log("click ignored (debounce)")
            return
        }
        lastMediaKey = now
        sink?.mediaPlayPause()
        sink?.log("PLAY/PAUSE toggled (single click)")
    }
}
