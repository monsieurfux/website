import Foundation

/// Handle for a delayed task (stands in for Android's `Handler.removeCallbacks`).
final class ScheduledTask {
    private(set) var isCancelled = false
    private var onCancel: (() -> Void)?

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        onCancel?()
        onCancel = nil
    }
}

/// Time + delayed execution, injected so the gesture/library logic is testable with virtual time.
protocol Scheduler: AnyObject {
    func nowMs() -> Int
    /// Runs `work` after `ms` milliseconds. `ms == 0` means "post to run soon".
    @discardableResult
    func after(ms: Int, _ work: @escaping () -> Void) -> ScheduledTask
}

/// Production scheduler: the main queue (all BLE callbacks are delivered there too).
final class MainScheduler: Scheduler {
    func nowMs() -> Int {
        return Int(Date().timeIntervalSince1970 * 1000)
    }

    @discardableResult
    func after(ms: Int, _ work: @escaping () -> Void) -> ScheduledTask {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: item)
        return ScheduledTask(onCancel: { item.cancel() })
    }
}
