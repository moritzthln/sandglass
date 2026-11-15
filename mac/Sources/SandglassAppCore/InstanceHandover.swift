import Foundation

/// Retiring an older Sandglass so this one can take over, and waiting until it has gone.
///
/// The old instance is sent `SIGTERM`, which its signal handler answers by flushing the usage
/// the coalescing was holding back and exiting. Sending it and moving on was a race: the new
/// instance read `state.json` before the old one had written its last fifteen seconds, the old
/// one's final write could then land over the new one's first, and for a moment two 1 Hz loops
/// hid apps and navigated tabs side by side. So the hand-over waits for the old process to be
/// gone before anything reads a file.
///
/// The wait is bounded. A process that has not gone by the deadline is wedged rather than
/// flushing, and is killed outright: what it was holding back is lost either way, and two loops
/// writing the same files would lose more. The deadline is short because this runs on the main
/// thread before anything is on screen, and the flush it waits for takes milliseconds.
///
/// A value with its three effects injected, so a test can drive it without a second process.
public struct InstanceHandover {
    /// Sends a signal to a process.
    public var send: (pid_t, Int32) -> Void
    /// Whether a process is still running.
    public var isAlive: (pid_t) -> Bool
    /// Waits a moment between two looks.
    public var pause: (TimeInterval) -> Void

    public static let deadline: TimeInterval = 3
    public static let interval: TimeInterval = 0.05

    public init(
        send: @escaping (pid_t, Int32) -> Void,
        isAlive: @escaping (pid_t) -> Bool,
        pause: @escaping (TimeInterval) -> Void
    ) {
        self.send = send
        self.isAlive = isAlive
        self.pause = pause
    }

    /// The real thing: `kill(2)`, and `kill(pid, 0)` as the question of whether a process is there.
    public static let system = InstanceHandover(
        send: { pid, signal in _ = kill(pid, signal) },
        isAlive: { pid in kill(pid, 0) == 0 || errno == EPERM },
        pause: { Thread.sleep(forTimeInterval: $0) }
    )

    /// Asks every process in `pids` to go, waits up to `deadline` for them to have gone, and
    /// kills whatever is left. Returns the processes that had to be killed.
    @discardableResult
    public func retire(_ pids: [pid_t], deadline: TimeInterval = Self.deadline) -> [pid_t] {
        guard !pids.isEmpty else { return [] }
        for pid in pids { send(pid, SIGTERM) }
        var waited: TimeInterval = 0
        var left = pids.filter(isAlive)
        while !left.isEmpty, waited < deadline {
            pause(Self.interval)
            waited += Self.interval
            left = left.filter(isAlive)
        }
        for pid in left { send(pid, SIGKILL) }
        return left
    }
}
