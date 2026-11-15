import Foundation

/// The two ways `LaunchAgentManager` talks to `launchctl`: run it and wait for its answer, or
/// start it and let it go.
///
/// A value rather than a static helper so a test can stand in for launchd and see what was asked,
/// in what order, and what was on disk at that moment — which is the whole of the keep-alive's
/// switch-off contract, and the half no unit test could reach while the calls were hard-wired.
public struct Launchctl {
    /// Runs `launchctl` with these arguments and returns its status and what it said.
    public var run: ([String]) -> (status: Int32, output: String)
    /// Starts `launchctl` in a session of its own and does not wait for it.
    ///
    /// For the one call that ends this process: `bootout` of the job Sandglass itself runs as.
    /// Waiting would block the main thread that the `SIGTERM` handler needs, and launchd would
    /// wait out its exit timeout and `SIGKILL` an app that never got to flush. Its own session so
    /// that launchd tearing down this job's process group cannot take `launchctl` with it before
    /// the request is sent.
    public var startDetached: ([String]) -> Bool

    public init(
        run: @escaping ([String]) -> (status: Int32, output: String),
        startDetached: @escaping ([String]) -> Bool
    ) {
        self.run = run
        self.startDetached = startDetached
    }

    public static let system = Launchctl(run: runAndWait, startDetached: spawnDetached)

    private static let path = "/bin/launchctl"

    /// Failures are returned rather than thrown: every caller turns them into a line for the
    /// settings screen, not into a crash.
    private static func runAndWait(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        // Read before waiting: `launchctl` writes little, but a pipe that fills while nobody
        // reads it deadlocks the child, and this one runs on the main thread.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let status = process.terminationStatus
        return (status, output.isEmpty ? "launchctl exited \(status)" : output)
    }

    /// `posix_spawn` with `POSIX_SPAWN_SETSID`, which `Process` cannot ask for.
    private static func spawnDetached(_ arguments: [String]) -> Bool {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return false }
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, path, nil, &attributes, argv, environ) == 0
    }
}
