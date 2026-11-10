import Foundation

/// Reports a delayed main queue without trying to recover from fatal signals.
final class MainRunLoopWatchdog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.sanbu3.droppoint.watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pendingAt: TimeInterval?
    private var reported = false

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.sample() }
            self.timer = timer
            timer.resume()
        }
    }
    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            pendingAt = nil
        }
    }
    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        if let pendingAt {
            if now - pendingAt > 4, !reported {
                reported = true
                AppDiagnostics.record("main-loop-delay", fields: ["seconds": String(Int(now - pendingAt))])
            }
            return
        }
        pendingAt = now
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queue.async { [self] in
                if self.reported, let pendingAt = self.pendingAt {
                    AppDiagnostics.record("main-loop-responsive", fields: ["seconds": String(Int(ProcessInfo.processInfo.systemUptime - pendingAt))])
                }
                self.pendingAt = nil
                self.reported = false
            }
        }
    }
}
