import SandglassAppCore
import Foundation

// The hand-over from an older Sandglass to a new one: asked to go, waited for, and only killed
// when it will not. The new instance reads `state.json` after this returns, so "returned" has to
// mean "the old one has finished writing".

func runInstanceHandoverTests() {
    testTheOldInstanceIsWaitedForUntilItHasGone()
    testAWedgedInstanceIsKilledAtTheDeadline()
    testNothingToRetireWaitsForNothing()
}

/// A fake process table: each pid is still there for a number of looks, then gone.
private final class FakeProcesses {
    var signals: [(pid_t, Int32)] = []
    var looksLeft: [pid_t: Int]
    var paused: TimeInterval = 0
    init(_ looksLeft: [pid_t: Int]) { self.looksLeft = looksLeft }

    var handover: InstanceHandover {
        InstanceHandover(
            send: { [self] pid, signal in signals.append((pid, signal)) },
            isAlive: { [self] pid in
                guard let left = looksLeft[pid], left > 0 else { return false }
                looksLeft[pid] = left - 1
                return true
            },
            pause: { [self] in paused += $0 }
        )
    }
}

private func testTheOldInstanceIsWaitedForUntilItHasGone() {
    let processes = FakeProcesses([41: 5])
    let killed = processes.handover.retire([41])
    expectEqual(killed, [], "it went by itself")
    expectEqual(processes.signals.map(\.1), [SIGTERM], "asked once, never killed")
    expect(processes.paused > 0, "and the hand-over waited for it rather than moving straight on")
}

private func testAWedgedInstanceIsKilledAtTheDeadline() {
    let processes = FakeProcesses([41: Int.max])
    let killed = processes.handover.retire([41], deadline: 1)
    expectEqual(killed, [41], "a process still there at the deadline is wedged")
    expectEqual(processes.signals.map(\.1), [SIGTERM, SIGKILL], "asked first, killed last")
    expect(processes.paused >= 1, "after the whole deadline")
    expect(processes.paused < 1.5, "and not much longer")
}

private func testNothingToRetireWaitsForNothing() {
    let processes = FakeProcesses([:])
    expectEqual(processes.handover.retire([]), [], "no older instance")
    expectEqual(processes.paused, 0, "costs the launch nothing")
}
