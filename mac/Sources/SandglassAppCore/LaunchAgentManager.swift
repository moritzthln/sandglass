import Foundation

/// The LaunchAgent that starts Sandglass at login and puts it back after a kill.
///
/// **launchd owns the process.** `ProgramArguments` names the executable inside the bundle,
/// `RunAtLoad` starts it at login, and `KeepAlive` starts it again every time it stops — within
/// seconds. That is the whole point of the shape. The job used to run `/usr/bin/open` on a
/// `StartInterval` of sixty seconds, which left a minute-wide hole after every quit: long enough
/// to drag Sandglass.app to the Trash and have nothing come back. There is no such hole now. The
/// Finder never finds a dead moment.
///
/// **No `-g` any more, and none needed.** The old job re-ran `open` once a minute for as long as
/// Sandglass was installed, and a plain `open` *activates* what it opens — so `-g` was what kept
/// the tick from pulling the front window out from under whatever the user was typing into, once
/// a minute, forever. launchd starts the executable rather than asking LaunchServices to open the
/// app, and it starts it only when its own copy is not running: an accessory app that nothing
/// activates takes no Dock tile and steals no focus. The reason for `-g` went with the tick.
///
/// **`ThrottleInterval` and nothing else.** Ten seconds is launchd's own floor between two starts
/// of one job, and launchd's back-off is what deals with a binary that crashes on launch. Nothing
/// here counts restarts or gives up after some number of them: a keep-alive that decides on its
/// own to stop keeping the app alive is the failure it exists to prevent.
///
/// **What unloading costs.** launchd owning the process cuts both ways: `bootout` terminates what
/// it started, so switching the agent off while launchd is the thing running Sandglass quits
/// Sandglass with it. That is right at the quit dialogue — "Turn off and quit" is exactly that
/// sentence — and it is a surprise from the Settings toggle, where the app disappears a moment
/// after the switch moves. There is no launchd verb that lets go of a job without stopping it, so
/// the alternative would be a keep-alive that says "off" while a live job goes on restarting the
/// app, and that lie is the one thing this file refuses to tell anywhere else.
///
/// It is still deliberately weak, and still on purpose. Anyone who wants Sandglass gone can
/// `launchctl bootout` it in one line, and that is where strict mode ends for a self-control tool:
/// someone who can run a program as this user can also `pkill` the app or edit `config.json` by
/// hand. What the shape buys is that the *forgetful* route — quit it, then delete it before it
/// notices — is no longer a route.
@MainActor
public final class LaunchAgentManager: KeepAliveManaging {

    public static let label = "io.github.moritzthln.sandglass.agent"

    /// Where the agent is written. `~/Library/LaunchAgents` unless overridden.
    ///
    /// The override is the same seam, and exists for the same reason, as `SANDGLASS_SUPPORT_DIR`:
    /// nothing this repository runs may write into the real LaunchAgents folder by accident. A
    /// redirected run writes the plist somewhere throwaway and never asks `launchctl` to load it
    /// — see `talksToLaunchd`, which is what keeps a test run from registering a job that would
    /// outlive it.
    public let directory: URL

    /// The bundle the job starts, and what drift is measured against.
    public let bundleURL: URL

    /// Whether `launchctl` is spoken to at all. False for every redirected run, which is every
    /// run that is not the installed app: a test that loaded a job would leave one behind.
    public let talksToLaunchd: Bool

    /// The app's own: the real LaunchAgents folder and this bundle, unless the environment
    /// redirects it.
    public convenience init() {
        let override = ProcessInfo.processInfo.environment["SANDGLASS_LAUNCH_AGENT_DIR"]
            .flatMap { $0.isEmpty ? nil : $0 }
        let directory = override.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        self.init(
            directory: directory,
            bundleURL: Bundle.main.bundleURL,
            talksToLaunchd: override == nil
        )
    }

    /// The seam a test builds on: a throwaway directory, a bundle path that need not exist, and
    /// `launchctl` left out of it entirely.
    public init(directory: URL, bundleURL: URL, talksToLaunchd: Bool = false) {
        self.directory = directory
        self.bundleURL = bundleURL
        self.talksToLaunchd = talksToLaunchd
    }

    public var plistURL: URL {
        directory.appendingPathComponent("\(Self.label).plist")
    }

    /// Asked of the disk, not of a flag: a plist deleted by hand between two launches has to
    /// read as "off", or the settings toggle lies about what is installed.
    ///
    /// The plist being there is the whole answer, which is only true because `install()` takes
    /// it back off disk when launchd refuses it — see there.
    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    public func setInstalled(_ installed: Bool) -> String? {
        installed ? install() : uninstall()
    }

    // MARK: - Installing

    private func install() -> String? {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try plistData().write(to: plistURL, options: .atomic)
        } catch {
            return "Couldn't write the startup item — \(error.localizedDescription)"
        }
        guard talksToLaunchd else { return nil }
        // Booted out first so an install over an existing agent re-reads the plist rather than
        // failing with "service already loaded". A job that is not loaded refuses this, which
        // is why the result is ignored.
        _ = Self.launchctl(["bootout", Self.serviceTarget])
        let result = Self.launchctl(["bootstrap", Self.domainTarget, plistURL.path])
        guard result.status != 0 else { return nil }
        // The plist goes back off disk. Leaving it would have `isInstalled` answer yes while
        // launchd knows nothing about the job, and the toggle's entire purpose is to report
        // what is actually true — a keep-alive that says "on" and is not is worse than one
        // that is off. All or nothing, so a second attempt starts from a clean state.
        try? FileManager.default.removeItem(at: plistURL)
        return "Couldn't enable — try again. launchd said: \(result.output)"
    }

    /// The mirror image of `install()`, and it has to be exactly that: the plist stays on disk
    /// whenever launchd is still running the job.
    ///
    /// `bootout` can decline — a job wedged mid-launch, a domain that will not answer — and
    /// deleting the plist anyway would have `isInstalled` say "off" while a live job kept
    /// restarting the app. That is the same lie `install()` refuses to tell, in the other
    /// direction, and the more annoying one: a user who turned it off and watched the app come
    /// back would have no way left to find the thing doing it.
    private func uninstall() -> String? {
        if talksToLaunchd {
            // A plist that was never loaded — written by an earlier run that failed at exactly
            // this step — still has to be removable, so a refusal here is not an error. What is
            // an error is the job still being there afterwards, which is what is checked next.
            _ = Self.launchctl(["bootout", Self.serviceTarget])
            if let alive = Self.loadedJobDescription() {
                return "Couldn't disable — try again. launchd still has the job: \(alive)"
            }
        }
        do {
            if isInstalled { try FileManager.default.removeItem(at: plistURL) }
            return nil
        } catch {
            return "Couldn't remove the startup item — \(error.localizedDescription)"
        }
    }

    /// What launchd says about our job, or `nil` when it has never heard of it.
    ///
    /// `launchctl print` exits non-zero for an unknown service, which is the whole question. Its
    /// output is a page of properties; only the first line is worth showing anyone.
    private static func loadedJobDescription() -> String? {
        let result = launchctl(["print", serviceTarget])
        guard result.status == 0 else { return nil }
        return result.output.split(separator: "\n").first.map(String.init) ?? serviceTarget
    }

    // MARK: - Following the app around

    /// Re-installs the agent whenever what is on disk is not what this build would write.
    ///
    /// **Two things drift, and one comparison catches both.** The app is *expected* to move: it
    /// is built in the checkout and then copied to /Applications, which is the first thing that
    /// happens to it — and the plist names the executable by absolute path, so an agent written
    /// before the move keeps starting the build that was there then, or nothing at all. The
    /// *shape* moves too, once: every Mac that ran an earlier build carries the old
    /// `StartInterval` job, and nothing else would ever replace it. Comparing the whole job
    /// against what `plistData()` holds today covers the path, the shape, and whatever the next
    /// change turns out to be. Both failures are otherwise invisible: the settings toggle still
    /// says "on", and the only symptom is an app that quietly does not come back.
    ///
    /// **And a plist launchd has forgotten is drift as well.** `install.sh` boots the agent out
    /// before it swaps the bundle, so the app it starts afterwards finds a plist that is right
    /// and a launchd that knows nothing — which has to end in a `bootstrap` rather than in
    /// "nothing to do until the next login".
    ///
    /// Three things it will not do. It never *installs* an agent where none is on disk — a user
    /// who has keep-alive off keeps it off. It does nothing unless this build is a real bundle:
    /// under `swift run` there is none, and rewriting the user's agent to point at a checkout
    /// binary is not a reconciliation, it is a downgrade.
    ///
    /// And it does not let a build from the checkout take the agent off the installed copy. The
    /// copy in /Applications is the one `install.sh` puts there and the one the user actually
    /// runs; `mac/build/Sandglass.app` is a thing that exists for ten minutes and is deleted by
    /// the next build. Without this, double-clicking a dev build once would silently point the
    /// user's keep-alive at a directory that is about to disappear. A checkout build claims the
    /// agent only when the program it names is not there any more, which is better than an agent
    /// pointing at nothing.
    @discardableResult
    public func reconcileInstalledAgent() -> String? {
        guard bundleURL.pathExtension == "app", isInstalled else { return nil }
        let drifted = installedJob() != (job() as NSDictionary)
        guard drifted || !isRegistered else { return nil }
        if drifted, !mayClaimAgent() { return nil }
        return install()
    }

    /// Whether this build is allowed to point the agent at itself, which the installed copy
    /// always is and a checkout build only is once what the agent names has gone.
    private func mayClaimAgent() -> Bool {
        if bundleURL.path.hasPrefix("/Applications/") { return true }
        // An unreadable plist counts as naming nothing, so it is claimed: one this app cannot
        // parse is not one it should be trusting to restart it.
        guard let recorded = installedProgramPath() else { return true }
        return !FileManager.default.fileExists(atPath: recorded)
    }

    /// Whether launchd has the job right now.
    ///
    /// A redirected run answers yes without asking anything. It never bootstrapped a job, so the
    /// honest answer would be no — and no would have every such run reinstall on every launch,
    /// which is the one thing the redirect exists to prevent.
    private var isRegistered: Bool {
        guard talksToLaunchd else { return true }
        return Self.loadedJobDescription() != nil
    }

    /// The job on disk, or `nil` when there is no readable plist.
    ///
    /// Compared as a parsed dictionary rather than as bytes: an agent written by an older build
    /// differs in ways that matter, and one written in a different format differs in ways that
    /// do not. `nil` is unequal to every job, which re-installs — a plist this app cannot parse
    /// is not one it should be trusting to restart it.
    private func installedJob() -> NSDictionary? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              )
        else { return nil }
        return plist as? NSDictionary
    }

    /// The program the agent on disk starts, or `nil` if the plist cannot be read.
    ///
    /// The last argument in both shapes: `open -g -a <bundle>` named the bundle, and the job
    /// written today names the executable inside it. Either way it is a path that stops existing
    /// when that copy of Sandglass is deleted, which is the only question `mayClaimAgent` asks
    /// of it.
    private func installedProgramPath() -> String? {
        guard let arguments = installedJob()?["ProgramArguments"] as? [String] else { return nil }
        return arguments.last
    }

    // MARK: - The plist

    /// What launchd is asked to run. One dictionary rather than a literal at the write site,
    /// because `reconcileInstalledAgent` compares the installed job against exactly this.
    public func job() -> [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": [programPath],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
        ]
    }

    /// Serialised rather than written as a string literal: the app's path goes into it, and a
    /// path with an `&` in it would produce XML that launchd rejects at load time — which is
    /// the kind of failure nobody would find until the Mac had rebooted.
    public func plistData() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: job(), format: .xml, options: 0)
    }

    /// The executable launchd starts.
    ///
    /// Inside the bundle, so the agent starts *this* copy of Sandglass rather than whichever one
    /// LaunchServices happens to have registered — two builds on one Mac is the normal case here,
    /// not the exotic one. `Contents/MacOS/Sandglass` is `CFBundleExecutable` in
    /// `scripts/Info.plist`; the two have to say the same thing. Under `swift run` there is no
    /// bundle and the running binary is the only honest answer.
    public var programPath: String {
        guard bundleURL.pathExtension == "app" else {
            return Bundle.main.executableURL?.path ?? bundleURL.path
        }
        return bundleURL.appendingPathComponent("Contents/MacOS/Sandglass").path
    }

    // MARK: - launchctl

    /// `launchctl bootout` of another label in this user's domain, or nothing for a redirected
    /// run. Used by `retireLegacyAgent`, which lives with the migration it belongs to.
    var defaultLegacyBootout: (String) -> Void {
        guard talksToLaunchd else { return { _ in } }
        return { label in _ = Self.launchctl(["bootout", "\(Self.domainTarget)/\(label)"]) }
    }

    private static var domainTarget: String { "gui/\(getuid())" }
    private static var serviceTarget: String { "gui/\(getuid())/\(label)" }

    /// Runs `launchctl` and reports what it said. Failures are returned rather than thrown:
    /// every caller turns them into a line for the settings screen, not into a crash.
    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
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
        return (process.terminationStatus, output.isEmpty ? "launchctl exited \(process.terminationStatus)" : output)
    }
}
