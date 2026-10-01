#!/usr/bin/env bash
# What happens when Sandglass goes away — the three things a unit test cannot reach.
#
#   Part 0  the plist, written into a throwaway directory via SANDGLASS_LAUNCH_AGENT_DIR. Nothing
#           is loaded and nothing of the user's is touched, so this half is safe to run anywhere.
#           Thin on purpose now: what the plist holds and when it is rewritten is pinned by the
#           Swift suite (`LaunchAgentTests`), which reaches the manager through the same seam.
#           What is left here is that a real launch of the real binary writes the real file.
#   Part A  SIGTERM: the app is killed the way `launchctl bootout` and `pkill` kill it, and has to
#           exit promptly rather than be killed hard or hang.
#   Part B  the real agent: installed into the REAL ~/Library/LaunchAgents and loaded into the
#           REAL launchd, because there is no other way to prove that launchd accepts the plist.
#           The app is then killed and has to come back on its own, within seconds.
#
# Everything part B touches is removed on every exit path (`trap cleanup EXIT`). The teardown is
# armed only after the preflight has established that no Sandglass and no agent of ours were there
# to begin with: a run that refuses to start must never bootout, delete or kill anything.
#
#   usage: mac/scripts/test-keepalive.sh
set -uo pipefail
cd "$(dirname "$0")/.."

APP="build/Sandglass.app"
BUNDLE="$PWD/$APP"
BINARY="$APP/Contents/MacOS/Sandglass"
# The same executable by absolute path, which is what the agent names: launchd is given a program
# to run, not an app to open.
BINARY_IN_BUNDLE="$BUNDLE/Contents/MacOS/Sandglass"
LABEL="io.github.moritzthln.sandglass.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SERVICE="gui/$(id -u)/$LABEL"
# `mktemp -d` rather than a name built from $$: a pid is reused, so a stale directory from an
# earlier run can be inherited, with whatever it holds, instead of created.
SUPPORT_DIR="$(mktemp -d /tmp/sandglass-keepalive.XXXXXX)"
FAKE_AGENT_DIR="$SUPPORT_DIR/LaunchAgents"
FAKE_PLIST="$FAKE_AGENT_DIR/$LABEL.plist"
# Where the app the AGENT starts keeps its files. launchd passes none of this script's
# environment along, so it uses the real one; removed afterwards only if this run created it.
REAL_SUPPORT_DIR="$HOME/Library/Application Support/Sandglass"
CREATED_REAL_SUPPORT_DIR=0
# Nothing of the user's may be touched until the preflight says none of it is theirs.
PREFLIGHT_PASSED=0
FAILURES=0

cleanup() {
  rm -rf "$SUPPORT_DIR"
  # Before the preflight has passed, a plist or a running app is the USER'S, not ours.
  [ "$PREFLIGHT_PASSED" = "1" ] || return 0
  launchctl bootout "$SERVICE" >/dev/null 2>&1
  rm -f "$PLIST"
  pkill -x Sandglass >/dev/null 2>&1
  # The `$HOME` guard is not paranoia about this script: an empty HOME would make the path
  # "/Library/Application Support/Sandglass", and this line is an `rm -rf`.
  if [ "$CREATED_REAL_SUPPORT_DIR" = "1" ] && [ -n "$HOME" ]; then
    rm -rf "$REAL_SUPPORT_DIR"
  fi
  return 0
}
trap cleanup EXIT

pass() { echo "  ok   — $1"; }
fail() { echo "  FAIL — $1"; FAILURES=$((FAILURES + 1)); }
check() { if [ "$1" = "0" ]; then pass "$2"; else fail "$2"; fi; }
# `check` on a condition rather than an exit status, which reads better than $? gymnastics.
check_true() { if [ "$1" = "true" ]; then pass "$2"; else fail "$2 (got: $1)"; fi; }

wait_for_app() {
  for _ in $(seq 1 "$1"); do
    pgrep -x Sandglass >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

launch_app() {   # launch_app <env assignments…> — always on the throwaway support directory
  env SANDGLASS_SUPPORT_DIR="$SUPPORT_DIR" SANDGLASS_SEED_DEMO=domain "$@" \
    "$BINARY" >/dev/null 2>&1 &
  disown
}

echo "== preflight =="
if [ ! -x "$BINARY" ]; then
  echo "  FAIL — $BINARY is missing. Run mac/scripts/build-app.sh first." && exit 1
fi
if pgrep -x Sandglass >/dev/null 2>&1; then
  # Not only tidiness. Every launch below is a bundled binary with the real bundle identifier, and
  # a launch retires every other instance of it — so starting one here while yours is up would
  # quit yours. See `AppDelegate.retireOlderInstances`.
  echo "  FAIL — an Sandglass is already running. Quit it first; this script kills what it starts." && exit 1
fi
if [ -e "$PLIST" ]; then
  echo "  FAIL — $PLIST already exists. Remove it first; this script will not overwrite yours." && exit 1
fi
# The app's previous name. Part B runs the real app against the real Library, and a real first
# launch migrates: it boots out the old agent and moves the old data into $REAL_SUPPORT_DIR —
# which the teardown would then delete. Migrate first (launch the installed app once).
if [ -e "$HOME/Library/LaunchAgents/com.moritz.appblock.agent.plist" ] \
   || [ -f "$HOME/Library/Application Support/AppBlock/config.json" ]; then
  echo "  FAIL — an AppBlock install is still here. Launch Sandglass once to migrate it first." && exit 1
fi
[ -d "$REAL_SUPPORT_DIR" ] || CREATED_REAL_SUPPORT_DIR=1
PREFLIGHT_PASSED=1
pass "nothing of Sandglass's is running or installed — teardown is armed"

echo
echo "== part 0: the plist, written somewhere throwaway =="
launch_app SANDGLASS_LAUNCH_AGENT_DIR="$FAKE_AGENT_DIR" SANDGLASS_KEEPALIVE=on
wait_for_app 10
sleep 2
check "$([ -f "$FAKE_PLIST" ] && echo 0 || echo 1)" "SANDGLASS_LAUNCH_AGENT_DIR redirects the plist"
check "$([ ! -e "$PLIST" ] && echo 0 || echo 1)" "and the real LaunchAgents directory is untouched"
launchctl print "$SERVICE" >/dev/null 2>&1 && REDIRECTED_LOADED=1 || REDIRECTED_LOADED=0
check "$REDIRECTED_LOADED" "a redirected run never asks launchd to load anything"

if [ -f "$FAKE_PLIST" ]; then
  echo "  --- plist ---"
  plutil -p "$FAKE_PLIST" 2>&1 | sed 's/^/  /'
  plutil -lint "$FAKE_PLIST" >/dev/null 2>&1
  check "$?" "it is a valid property list"
  # `raw`, which is unescaped — `json` renders every slash as \/ and the comparison then depends
  # on how the shell quoted it rather than on what the plist says.
  PROGRAM=$(plutil -extract "ProgramArguments.0" raw -o - "$FAKE_PLIST" 2>/dev/null)
  check_true "$([ "$PROGRAM" = "$BINARY_IN_BUNDLE" ] && echo true || echo false)" \
    "launchd runs the executable in this build's bundle, not \`open\` on the bundle"
  check_true "$(plutil -extract "ProgramArguments.1" raw -o - "$FAKE_PLIST" >/dev/null 2>&1 && echo false || echo true)" \
    "and nothing else — no \`open\`, so no -g to keep a minute tick out of the user's face"
  check_true "$(plutil -extract KeepAlive raw -o - "$FAKE_PLIST" 2>/dev/null | grep -q 'true\|^1$' && echo true || echo false)" \
    "launchd owns the process, so a quit is undone within seconds"
  check_true "$(plutil -extract RunAtLoad raw -o - "$FAKE_PLIST" 2>/dev/null | grep -q 'true\|^1$' && echo true || echo false)" \
    "and it starts at login"
  check_true "$(plutil -extract ThrottleInterval raw -o - "$FAKE_PLIST" 2>/dev/null | grep -q '^10$' && echo true || echo false)" \
    "with launchd's own floor between two starts, and no back-off of our own"
  check_true "$(plutil -extract StartInterval raw -o - "$FAKE_PLIST" >/dev/null 2>&1 && echo false || echo true)" \
    "no minute tick is left — that hole is what this shape closed"
fi

pkill -x Sandglass; sleep 1
launch_app SANDGLASS_LAUNCH_AGENT_DIR="$FAKE_AGENT_DIR" SANDGLASS_KEEPALIVE=off
wait_for_app 10
sleep 2
check "$([ ! -e "$FAKE_PLIST" ] && echo 0 || echo 1)" "turning it off takes the plist away again"
pkill -x Sandglass; sleep 1

echo
echo "== part A: SIGTERM is answered, not survived =="
# It matters more than it used to. SIGTERM is how `launchctl bootout` stops the job, and bootout
# is now what `install.sh` runs before it swaps the bundle and what the settings toggle runs when
# keep-alive goes off — an app that ignored it or hung would leave both of those wedged.
#
# Redirected, though nothing here is about the agent, and *because* nothing here is about it: a
# launch on a fresh support directory installs one on its own now — see `AppState.seedKeepAlive` —
# and the only part of this script allowed to touch the real ~/Library/LaunchAgents is part B.
launch_app SANDGLASS_LAUNCH_AGENT_DIR="$FAKE_AGENT_DIR"
wait_for_app 10
APP_PID=$(pgrep -x Sandglass | head -1)
check "$([ -n "$APP_PID" ] && echo 0 || echo 1)" "the app is running"

kill -TERM "$APP_PID" 2>/dev/null
EXITED=1
for _ in $(seq 1 50); do
  kill -0 "$APP_PID" 2>/dev/null || { EXITED=0; break; }
  sleep 0.1
done
check "$EXITED" "the app exits promptly on SIGTERM (not killed, not hung)"

launch_app SANDGLASS_LAUNCH_AGENT_DIR="$FAKE_AGENT_DIR"
check "$(wait_for_app 10 && echo 0 || echo 1)" "and a relaunch comes up on the same directory"
pkill -x Sandglass; sleep 1

echo
echo "== part B: the real agent brings the app back =="
launch_app SANDGLASS_KEEPALIVE=on
wait_for_app 10
# Long enough for the handover: the app started here installs the agent, launchd bootstraps it and
# starts its own copy of the executable, and that copy retires this one. What is running a few
# seconds from now is launchd's — on the REAL support directory, since launchd passes none of this
# script's environment along.
sleep 5
check "$([ -f "$PLIST" ] && echo 0 || echo 1)" "the agent plist is written to ~/Library/LaunchAgents"
launchctl print "$SERVICE" >/dev/null 2>&1
check "$?" "and launchd accepted it as a loaded job"
check "$(pgrep -x Sandglass >/dev/null 2>&1 && echo 0 || echo 1)" "an Sandglass is running"
RUNNING=$(pgrep -x Sandglass | wc -l | tr -d ' ')
check_true "$([ "$RUNNING" = "1" ] && echo true || echo false)" \
  "and exactly one of them — bootstrapping the job starts a second, and the newest retires the older"

# There is no focus check here any more, and nothing is being skipped. `-g` guarded one thing: a
# minute tick that re-`open`ed an app that was already running, once a minute, forever. launchd
# starts the executable only when its own copy is not running, so there is no tick to steal focus.
# What a restart does with focus is a different question, and not one this script can ask: launchd
# passes none of this environment on, so the copy that comes back reads the real support directory
# and on a Mac with nothing configured there it opens its main window, which activates on purpose.

echo "  killing Sandglass and waiting for the agent (up to 30s)…"
pkill -x Sandglass
sleep 1
START=$(date +%s)
if wait_for_app 30; then
  ELAPSED=$(( $(date +%s) - START ))
  pass "the agent started it again after ~${ELAPSED}s"
  # The number is the point of the change: the old agent took 54–57 s and that minute was long
  # enough to quit Sandglass and drag it to the Trash. ThrottleInterval is 10, so anything past
  # about 15 means launchd is backing off — worth knowing rather than worth passing.
  check_true "$([ "$ELAPSED" -le 20 ] && echo true || echo false)" \
    "within seconds rather than within a minute (${ELAPSED}s)"
else
  fail "the app did not come back within 30s"
fi

echo
echo "== teardown =="
cleanup
check "$([ ! -e "$PLIST" ] && echo 0 || echo 1)" "the plist is gone from ~/Library/LaunchAgents"
launchctl print "$SERVICE" >/dev/null 2>&1 && STILL_LOADED=1 || STILL_LOADED=0
check "$STILL_LOADED" "and launchd no longer knows the job"
sleep 1
check "$(pgrep -x Sandglass >/dev/null 2>&1 && echo 1 || echo 0)" "no Sandglass is left running"

echo
# Nothing is skipped any more. The three checks that used to need a GUI session with another app
# in front were about `-g`, and `-g` is gone with the minute tick it guarded — see part B.
if [ "$FAILURES" -eq 0 ]; then
  echo "all checks passed"
else
  echo "$FAILURES check(s) failed"
fi
exit "$FAILURES"
