import SandglassAppCore
import SandglassCore
import Foundation

/// The app's half of a dated block: what a real save does to a day already past, and what a lock
/// standing over the group makes of the two directions.
///
/// `DatedBlockTests` is the pure half — the day, the arithmetic and the engine's answer.
/// `EditDirectionTests` is the table. This is the layer where the two meet the disk, on the one
/// path every screen writes through: `AppState.applyConfigEdit`.
@MainActor
func runDatedBlockEditTests() {
    testAPastDayIsDroppedOnTheWayToDisk()
    testALockHoldsTheDateComingInAndNotGoingOut()
    testRemovingADayAlreadyPastIsNotHeld()
}

/// The other half of "a past day reads as absent": it stops being written down.
///
/// Pure first, then through the real save, because they are two different failures — the rule
/// being wrong, and the rule not being asked.
@MainActor
private func testAPastDayIsDroppedOnTheWayToDisk() {
    var config = twoGroupConfig()
    config.groupSettings[youtubeGroup]?.blockedUntilDay = "2026-08-09"
    config.groupSettings[redditGroup]?.blockedUntilDay = "2026-08-24"

    let swept = ConfigBuilder.droppingPastBlocks(in: config, onDay: "2026-08-10")
    expectNil(
        swept.groupSettings[youtubeGroup]?.blockedUntilDay,
        "a day that has already begun is taken out"
    )
    expectEqual(
        swept.groupSettings[redditGroup]?.blockedUntilDay, "2026-08-24",
        "and one still ahead is left exactly where it is"
    )
    expectEqual(
        ConfigBuilder.droppingPastBlocks(in: swept, onDay: "2026-08-10"), swept,
        "a configuration with nothing to drop comes back unchanged, byte for byte"
    )

    withTempDir { dir in
        // `noon` is Monday 2026-08-10 at 12:00, so the day key is 2026-08-10 either way.
        let state = makeState(dir, clock: FakeClock(noon))
        expectNil(state.applyConfigEdit(config), "the edit itself goes through")
        expectNil(
            state.config.groupSettings[youtubeGroup]?.blockedUntilDay,
            "and the save takes the dead day out on the way past"
        )
        expectEqual(
            state.config.groupSettings[redditGroup]?.blockedUntilDay, "2026-08-24",
            "while the one that is still blocking survives the write"
        )
    }
}

/// The whole of the commitment machinery this feature needed, and none of it is new: **later is
/// stricter**, so setting or extending a date passes whatever is standing and cutting or removing
/// one waits the lock out.
@MainActor
private func testALockHoldsTheDateComingInAndNotGoingOut() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(
            state.applyConfigEdit(locked(twoGroupConfig(), group: youtubeGroup, minutes: 10)),
            "the group is given a lock while nothing is holding it"
        )
        state.settingsWindowOpened()

        var dated = state.config
        dated.groupSettings[youtubeGroup]?.blockedUntilDay = "2026-08-24"
        expectNil(
            state.applyConfigEdit(dated),
            "shutting the group until a day is somebody making their own commitment harder"
        )
        expectEqual(
            state.config.groupSettings[youtubeGroup]?.blockedUntilDay, "2026-08-24",
            "so the lock lets it through and the date lands"
        )

        var later = state.config
        later.groupSettings[youtubeGroup]?.blockedUntilDay = "2026-08-31"
        expectNil(state.applyConfigEdit(later), "and moving it further out is more of the same")

        var earlier = state.config
        earlier.groupSettings[youtubeGroup]?.blockedUntilDay = "2026-08-24"
        expectEqual(
            state.applyConfigEdit(earlier), "Held by the lock on Social",
            "pulling it back in hands a week back, which the wait refuses"
        )

        var removed = state.config
        removed.groupSettings[youtubeGroup]?.blockedUntilDay = nil
        expectEqual(
            state.applyConfigEdit(removed), "Held by the lock on Social",
            "and so does taking it off altogether"
        )
        expectEqual(
            state.config.groupSettings[youtubeGroup]?.blockedUntilDay, "2026-08-31",
            "nothing moved"
        )
    }
}

/// The case the day is threaded through the direction table for: once the block is over, taking the
/// key out is housekeeping. A lock that refused it would be defending a block that has already let
/// go — and the user would be stuck with a dead row on the card until the wait ran out.
@MainActor
private func testRemovingADayAlreadyPastIsNotHeld() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        // A wait measured in days, so it is still standing on the far side of the block it
        // outlives — the whole case is a lock that is running when the date is not.
        var dated = locked(twoGroupConfig(), group: youtubeGroup, minutes: 3 * 24 * 60)
        dated.groupSettings[youtubeGroup]?.blockedUntilDay = "2026-08-11"
        expectNil(state.applyConfigEdit(dated), "a group is shut until tomorrow, behind a lock")
        state.settingsWindowOpened()

        // Tuesday: the block let go at 03:00, and the lock is still running.
        clock.now = august(11, 12)
        var removed = state.config
        removed.groupSettings[youtubeGroup]?.blockedUntilDay = nil
        expectNil(
            state.applyConfigEdit(removed),
            "the day having arrived, removing the key gives nothing back and is not refused"
        )
        expectNil(
            state.config.groupSettings[youtubeGroup]?.blockedUntilDay, "and the key is gone"
        )

        var loosened = state.config
        loosened.groupSettings[youtubeGroup]?.pauseSeconds = 3
        expectEqual(
            state.applyConfigEdit(loosened), "Held by the lock on Social",
            "while the lock itself is still standing over everything that does hand something back"
        )
    }
}
