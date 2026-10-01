import SandglassAppCore
import AppKit
import SwiftUI

/// One application the user could choose to block.
///
/// No icon. There was one, for the wizard's app column, and loading it cost an
/// `NSWorkspace.icon(forFile:)` per application on a scan that walks three directories — paid on
/// every launch for a list that no longer draws them.
struct InstalledApp: Identifiable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
}

/// Finds the applications on this Mac, for the pickers that offer a list of them.
///
/// Deliberately a plain synchronous scan of three directories rather than a Spotlight query:
/// it cannot be in a state where the list is half there, and it costs 77–114 ms on this Mac
/// for ~110 apps — once per run, because the result is cached. Nested folders are not walked:
/// an app inside
/// `/Applications/Adobe` is missed, and the config file can still name it by hand.
///
/// `@MainActor` because the cache is mutable and both callers are windows.
@MainActor
enum AppScanner {

    /// Held for the life of the process. The window rebuilds its hosting controller on every
    /// open, so an uncached scan would run on every open instead of every launch. The cost is
    /// that an app installed while Sandglass is running does not appear until the next launch,
    /// which is the better of the two staleness problems: the other one is a settings screen
    /// that takes a tenth of a second to appear.
    private static var cached: [InstalledApp]?

    /// `/System/Applications` is in here on purpose. Music, TV, Messages and News all live
    /// there on macOS 14, and a blocker that cannot see the distractions Apple ships would be
    /// missing half the point.
    private static let directories: [URL] = {
        var urls = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
        ]
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        urls.append(home)
        return urls
    }()

    /// Browsers are left out because blocking one would block the web whole, and websites are
    /// blocked one at a time — by the domain list, through the app's own reading of the frontmost
    /// tab. Sandglass itself goes with them; hiding itself would hide the way out.
    ///
    /// The set is `AppChoices`', which is where the running list reads it too: a scan that left
    /// browsers out while the running list offered them would be two answers to one question.
    private static let excludedBundleIDs = AppChoices.excludedBundleIDs

    /// Every installed application, by name.
    static func scan() -> [InstalledApp] {
        if let cached { return cached }
        let apps = walk()
        cached = apps
        return apps
    }

    /// The apps running right now, for the top section of the add-apps sheet.
    ///
    /// **Never cached**, unlike the scan: what is running is the one thing on that sheet that is
    /// different every time it opens, and a remembered answer would be offering the app somebody
    /// quit an hour ago. It costs one array walk of about eighty processes.
    ///
    /// What macOS answers with is everything with a process — agents, helpers, extensions — so
    /// `AppChoices.running` is what narrows it to the ones anybody thinks of as an app.
    static func running() -> [TargetPicker.App] {
        AppChoices.running(
            NSWorkspace.shared.runningApplications.map { app in
                AppChoices.RunningApp(
                    bundleID: app.bundleIdentifier ?? "",
                    name: app.localizedName ?? "",
                    isOrdinary: app.activationPolicy == .regular
                )
            }
        )
    }

    private static func walk() -> [InstalledApp] {
        let fm = FileManager.default
        var found: [String: InstalledApp] = [:]
        for directory in directories {
            let contents = (try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            for url in contents where url.pathExtension == "app" {
                guard let app = read(url), !excludedBundleIDs.contains(app.bundleID) else { continue }
                // First directory wins, so a copy in ~/Applications does not shadow the one in
                // /Applications the user is actually launching.
                if found[app.bundleID] == nil { found[app.bundleID] = app }
            }
        }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func read(_ url: URL) -> InstalledApp? {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
        return InstalledApp(bundleID: bundleID, name: displayName(of: bundle, at: url))
    }

    /// What the Finder calls it: the bundle's own display name where there is one, and the
    /// file name where there is not.
    private static func displayName(of bundle: Bundle, at url: URL) -> String {
        let keys = ["CFBundleDisplayName", "CFBundleName"]
        for key in keys {
            if let name = bundle.localizedInfoDictionary?[key] as? String, !name.isEmpty { return name }
            if let name = bundle.infoDictionary?[key] as? String, !name.isEmpty { return name }
        }
        return url.deletingPathExtension().lastPathComponent
    }
}
