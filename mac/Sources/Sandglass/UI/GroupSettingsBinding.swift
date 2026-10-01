import SandglassAppCore
import SandglassCore
import SwiftUI

/// One group's settings as a single binding: reading is the running configuration, writing is an
/// edit through `AppState.applyConfigEdit` with the preset marker re-derived.
///
/// It exists so the cards that edit those settings — Settings and Time windows — can be written
/// against a `Binding<GroupSettings>` and nothing else. That is what lets the preset editor put
/// the very same Settings card in front of a draft: "edit this preset" and "edit this group" are
/// the same knobs, and a second set of them would be two screens drifting apart from the day
/// they were written.
///
/// Every refusal still comes back the way it did — `problem` is the caller's, and a group its own
/// lock is holding refuses here exactly as the app-wide lock does.
@MainActor
enum GroupSettingsEditing {

    static func binding(
        appState: AppState, groupID: String, problem: Binding<String?>
    ) -> Binding<GroupSettings> {
        Binding(
            get: { appState.config.settings(forGroup: groupID) ?? .standard },
            set: { updated in
                // A group that has no settings at all is `.notManaged`, and inventing some for it
                // here would claim protection that is not there. The editor offers a button for
                // that, and it is the only way one appears.
                guard appState.config.settings(forGroup: groupID) != nil else { return }
                var settings = updated
                settings.presetID = ConfigBuilder.presetID(
                    matching: settings, in: appState.config.presets
                )
                var config = appState.config
                config.groupSettings[groupID] = settings
                problem.wrappedValue = appState.applyConfigEdit(config)
            }
        )
    }
}
