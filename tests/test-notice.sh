#!/bin/bash
# Notification damping: a fault that persists for hours is one problem, not one
# per cycle. The syslog line is still written every time; only the push is
# damped, and anything that changes must still get through immediately.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WATCHDOG="$ROOT/src/container-watchdog"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export WATCHDOG_CONFIG_DIR="$WORK/config"
export WATCHDOG_CONFIG_FILE="$WORK/config/watch.conf"
export WATCHDOG_STATE_DIR="$WORK/config/state"
export WATCHDOG_RUNTIME_DIR="$WORK/run"
export WATCHDOG_NOTIFY_TOOL="$WORK/bin/notify"
export WATCHDOG_STATUS_TOOL="$WORK/absent-status"
export WATCHDOG_BREAKGLASS_TOOL="$WORK/absent-breakglass"
export WATCHDOG_GUARD_TOOL="$WORK/absent-guard"
export WATCHDOG_DOCKER_TOOL="$WORK/bin/docker"
export WATCHDOG_SS_TOOL="$WORK/bin/ss"
export WATCHDOG_TIMEOUT_TOOL="$WORK/bin/timeout"
export WATCHDOG_FLOCK_TOOL="$WORK/bin/flock"
mkdir -p "$WATCHDOG_CONFIG_DIR" "$WORK/bin"

PUSHED="$WORK/pushed.log"
: > "$PUSHED"

# The container exists only while the marker file does, which lets a single
# stub cover both the broken and the recovered state.
cat > "$WORK/bin/docker" <<EOF
#!/bin/bash
case "\$1" in
  info) exit 0 ;;
  inspect)
    [[ -f "$WORK/present" ]] || exit 1
    if [[ -f "$WORK/stopped" ]]; then
      printf 'exited|none|bridge~192.0.2.7 | | |bridge\n'
    else
      printf 'running|healthy|bridge~192.0.2.7 | | |bridge\n'
    fi
    exit 0
    ;;
esac
exit 1
EOF

cat > "$WORK/bin/timeout" <<'EOF'
#!/bin/bash
while [[ "${1:-}" == -* ]]; do
  [[ "$1" == -k ]] && shift
  shift
done
shift
exec "$@"
EOF

cat > "$WORK/bin/ss" <<'EOF'
#!/bin/bash
echo "State Recv-Q Send-Q Local Address:Port Peer"
EOF

cat > "$WORK/bin/flock" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$WORK/bin/notify" <<EOF
#!/bin/bash
cat >> "$PUSHED"
printf '\n' >> "$PUSHED"
EOF

chmod 0700 "$WORK"/bin/*

cat > "$WATCHDOG_CONFIG_FILE" <<'CONFIG'
container=ghost action=notify checks=running threshold=1
CONFIG

fail() { echo "$1" >&2; exit 1; }
pushes() { grep -c . "$PUSHED" 2>/dev/null || true; }
cycles() { local i; for ((i = 0; i < ${1:-1}; i++)); do bash "$WATCHDOG" run >/dev/null 2>&1 || true; done; }

# ── A persistent fault is pushed once, not once per cycle ──
: > "$PUSHED"
rm -f "$WORK/present"
export WATCHDOG_NOTIFY_REPEAT=3600
cycles 5
damped=$(pushes)
[[ "$damped" -eq 1 ]] \
  || fail "five cycles of the same fault produced $damped pushes, expected 1"

# ── Control: without the repeat window every cycle would push again ──
# Proves the assertion above measures the damping rather than a stub that never
# fires. A zero window means no situation is ever too recent to repeat.
: > "$PUSHED"
rm -rf "$WORK/run"
WATCHDOG_NOTIFY_REPEAT=0 bash -c 'for i in 1 2 3 4 5; do bash "$0" run >/dev/null 2>&1 || true; done' "$WATCHDOG"
undamped=$(pushes)
[[ "$undamped" -eq 5 ]] \
  || fail "the control produced $undamped pushes, expected 5: the damping test proves nothing"

# ── Recovery still gets through immediately ──
# The situation changed, so it must not wait for the repeat window.
: > "$PUSHED"
rm -rf "$WORK/run"
cycles 3                      # settles into a damped, degraded state
[[ "$(pushes)" -eq 1 ]] || fail "the degraded state did not settle to a single push"
touch "$WORK/present"         # the container comes back
cycles 1
[[ "$(pushes)" -eq 2 ]] \
  || fail "recovery was swallowed by the repeat window"
grep -q 'action=recovered' "$PUSHED" \
  || fail "the second push was not the recovery"

# ── A fault after a recovery is new information again ──
: > "$PUSHED"
rm -f "$WORK/present"
cycles 2
[[ "$(pushes)" -eq 1 ]] \
  || fail "a fresh fault after a recovery did not push exactly once"

# ── Resetting a container re-arms its notifications ──
: > "$PUSHED"
cycles 2
[[ "$(pushes)" -eq 0 ]] || fail "the damped state did not hold before the reset"
bash "$WATCHDOG" reset ghost >/dev/null 2>&1 || true
cycles 1
[[ "$(pushes)" -eq 1 ]] \
  || fail "a reset did not re-arm the notification"

# ── The damping state lives on tmpfs, never on the flash device ──
[[ -d "$WORK/run/notices" ]] \
  || fail "the notice state was not written under the runtime directory"
if [[ -d "$WATCHDOG_STATE_DIR" ]] && grep -rlq 'ghost' "$WATCHDOG_STATE_DIR" 2>/dev/null; then
  find "$WATCHDOG_STATE_DIR" -name '*notice*' | grep -q . \
    && fail "notice state was written to the flash-backed state directory"
fi

# ── A fault that changes shape is new information, not a repeat ──
# The action and result are identical in both cycles; only the reason differs.
# An escalating problem looks exactly like this, so it must not be swallowed.
: > "$PUSHED"
rm -rf "$WORK/run"
rm -f "$WORK/present" "$WORK/stopped"
cycles 2                                  # reason=not-found, damped after one push
[[ "$(pushes)" -eq 1 ]] || fail "the first fault did not settle to a single push"
touch "$WORK/present" "$WORK/stopped"     # now present but not running
cycles 1
[[ "$(pushes)" -eq 2 ]] \
  || fail "a fault that changed from not-found to state-exited was swallowed"
grep -q 'state-exited' "$PUSHED" \
  || fail "the second push did not carry the new fault signature"

# ── A dry run leaves no trace, including the damping state ──
# The web interface presents this as an operation that changes nothing, so it
# must not be able to swallow a later genuine push. The container has to be in a
# failing state first, otherwise there is no recovery to report and the check
# below would pass without proving anything.
rm -rf "$WORK/run"
rm -f "$WORK/present" "$WORK/stopped"
cycles 1                                  # records a failing verdict
before=$(cat "$WORK/run/notices/ghost")
: > "$PUSHED"
touch "$WORK/present"                     # healthy again: a recovery is now due
bash "$WATCHDOG" check >/dev/null 2>&1 || true
[[ "$(pushes)" -eq 0 ]] || fail "a dry run sent a notification"
[[ "$(cat "$WORK/run/notices/ghost")" == "$before" ]] \
  || fail "a dry run changed the damping state"

echo "Notification damping: a lasting fault pushes once, changes still arrive at once"
