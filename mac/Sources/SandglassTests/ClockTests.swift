import SandglassCore

func runClockTests() {
    expect(SystemClock().now.timeIntervalSince1970 > 0, "system clock returns a date")
}
