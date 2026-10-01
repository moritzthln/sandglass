import SandglassAppCore
import Foundation
import UserNotifications

/// Delivers Sandglass's one notification through the system's notification centre.
///
/// This is the whole of `UserNotifications` in the app: `SandglassAppCore` knows only that
/// something can be told "this group relocks in n seconds", which is what keeps the loop and
/// its rules testable without a notification centre or an app bundle.
@MainActor
final class UserNotificationPresenter: NotificationPresenting {

    /// `UNUserNotificationCenter.current()` raises an Objective-C exception — not catchable in
    /// Swift — in a process without a bundle identifier. The app has to survive being run as a
    /// bare binary during development, so the centre is only touched inside a real app bundle.
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier == nil ? nil : .current()

    /// Authorization is asked for once, at construction, which is app launch.
    init() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func deliverRelockWarning(groupName: String, secondsLeft: Int) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        // No title: the notification already carries the app's name, and a second heading
        // above one short sentence reads as shouting.
        content.body = "\(groupName) relocks in \(secondsLeft) seconds"
        content.sound = .default
        center.add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
