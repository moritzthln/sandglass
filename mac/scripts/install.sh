#!/usr/bin/env bash
# Builds Sandglass and puts it in /Applications, replacing whatever is there.
#
# Beside the other scripts rather than at the repository root: everything it drives —
# `build-app.sh`, `mac/build/Sandglass.app` — lives here, and one `mac/scripts` is easier to
# remember than two places that both hold scripts.
#
# Order matters and each step is here for a reason:
#
#   1. build first, so a broken build leaves the installed copy alone
#   2. bootout the keep-alive agent. launchd owns the Sandglass process now — `KeepAlive` on the
#      executable itself — so this both stops the running app and stops it coming back. Without
#      it every step below would race a respawn: the quit would be undone within seconds, and
#      the bundle would be swapped underneath a live app
#   2b. retire the app under its previous name, AppBlock: its agent, its process and its bundle
#   3. quit whatever is still running, with SIGTERM. Deliberately *not* the quit policy — an
#      installer must not be refused by a strict window, and the app is coming straight back
#   4. stage the new bundle inside /Applications and swap it in, so a copy that fails halfway
#      never leaves half an app where the whole one was
#   5. launch the new app. It writes and bootstraps its own agent — the plist it finds names the
#      right path but launchd is no longer holding it, and that counts as drift. See
#      `LaunchAgentManager.reconcileInstalledAgent`. launchd then starts its own copy, which
#      retires the one this script opened; from there the keep-alive is back in charge
#
# No sudo: /Applications is group-writable by admin users, and an app installed as root is one
# the user cannot update.
#
#   usage: mac/scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

BUILT="build/Sandglass.app"
DESTINATION="/Applications/Sandglass.app"
# A dot-prefixed sibling of the destination: same filesystem, so the swap is a rename, and
# hidden so a half-copied bundle never shows up in Finder or Spotlight.
STAGING="/Applications/.Sandglass.app.incoming"
AGENT_SERVICE="gui/$(id -u)/io.github.moritzthln.sandglass.agent"
# The app's previous name. Its KeepAlive agent names /Applications/AppBlock.app, and if it stays
# loaded launchd starts the old app beside this one every time it stops — forever. The app retires
# it as well on first launch (`LegacyMigration`); doing it here too means nothing old is running
# while the bundle is swapped. Data is not touched here: the app moves it, once, on first launch.
LEGACY_LABEL="com.moritz.appblock.agent"
LEGACY_SERVICE="gui/$(id -u)/$LEGACY_LABEL"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
LEGACY_APP="/Applications/AppBlock.app"
# How long the running app gets to answer SIGTERM. It exits in milliseconds; anything near this
# means something is wrong, and killing harder would skip its shutdown entirely.
QUIT_TIMEOUT=10

# Tolerant of the agent not being loaded: a first install has none, and a user who turned the
# toggle off has none either. Neither is a reason to stop.
release_keepalive_agent() {
  echo "   releasing the keep-alive agent…"
  launchctl bootout "$AGENT_SERVICE" >/dev/null 2>&1 || true
}

# Tolerant of every piece being absent, which is every Mac that never ran the old app.
retire_legacy_appblock() {
  launchctl bootout "$LEGACY_SERVICE" >/dev/null 2>&1 || true
  [ -n "$HOME" ] && rm -f "$LEGACY_PLIST"
  pkill -x AppBlockApp >/dev/null 2>&1 || true
  if [ -d "$LEGACY_APP" ]; then
    echo "   removing the old $LEGACY_APP…"
    rm -rf "$LEGACY_APP"
  fi
}

quit_running_sandglass() {
  pgrep -x Sandglass >/dev/null 2>&1 || return 0
  echo "   quitting the running Sandglass…"
  pkill -x Sandglass || true
  for _ in $(seq 1 "$QUIT_TIMEOUT"); do
    pgrep -x Sandglass >/dev/null 2>&1 || return 0
    sleep 1
  done
  echo "FAIL: Sandglass is still running after ${QUIT_TIMEOUT}s. Quit it by hand and run this again." >&2
  exit 1
}

echo "== building =="
scripts/build-app.sh

if [ ! -d "$BUILT" ]; then
  echo "FAIL: $BUILT was not produced by the build." >&2
  exit 1
fi
if [ ! -w /Applications ]; then
  echo "FAIL: /Applications is not writable by $(whoami). Install by hand, or fix its permissions." >&2
  exit 1
fi

echo "== installing to $DESTINATION =="
# Before the quit, not after: booting the agent out is usually what ends the process, since
# launchd is the thing running it. The quit below then finds nothing left to do, and only earns
# its keep for a copy somebody started by hand.
release_keepalive_agent
retire_legacy_appblock
quit_running_sandglass

rm -rf "$STAGING"
# `ditto` rather than `cp -R`: it keeps the code signature and the bundle's extended attributes
# intact, which a plain copy can quietly drop.
ditto "$BUILT" "$STAGING"

# The one moment the destination does not exist. Nothing is watching it: the agent was booted out
# above, so no restart can land in the gap and find half a bundle.
rm -rf "$DESTINATION"
mv "$STAGING" "$DESTINATION"
echo "   installed"

# Belt and braces. Nothing should be running — the agent is released and the app was quit — but a
# copy somebody double-clicked while the files were moving is not the app that was just installed.
quit_running_sandglass

echo "== starting =="
open -a "$DESTINATION"

cat <<'NEXT'

Done. What happens now:

  • Sandglass is in your menu bar. Click the hourglass and the window opens.
  • It writes its own start-at-login agent again and hands itself over to it —
    nothing to do. From then on a quit is undone within seconds.
  • Check Settings → Protection → Accessibility now. This install just took the
    grant away: macOS drops it every time an ad-hoc signed app is replaced, and
    goes on showing the old entry with its switch still on. If the row says it
    is missing, remove Sandglass in System Settings with "−" and add it again
    with "+". Without it a blocked app in fullscreen ignores being hidden and
    Firefox cannot be read at all.
  • Each browser also asks once for Automation the first time Sandglass reads its
    address bar.
NEXT
