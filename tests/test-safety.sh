#!/bin/bash
# Restraint and deference: the watchdog must respect Breakglass, wait for a
# persistent fault, pick the narrowest repair, and give up rather than loop.

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
export WATCHDOG_BREAKGLASS_TOOL="$WORK/bin/breakglass"
export WATCHDOG_GUARD_TOOL="$WORK/bin/guard"
export WATCHDOG_DOCKER_TOOL="$WORK/bin/docker"
export WATCHDOG_SS_TOOL="$WORK/bin/ss"
export WATCHDOG_TIMEOUT_TOOL="$WORK/bin/timeout"
export WATCHDOG_FLOCK_TOOL="$WORK/bin/flock"
mkdir -p "$WATCHDOG_CONFIG_DIR" "$WORK/bin" "$WORK/fixtures"

ACTIONS="$WORK/actions.log"
NOTICES="$WORK/notices.log"
: > "$ACTIONS"
: > "$NOTICES"

printf 'running|healthy|| | |redman-docker-api\n' > "$WORK/fixtures/detached"
printf 'running|unhealthy|bridge~192.0.2.4 | | |bridge\n' > "$WORK/fixtures/sick"
printf 'exited|none|| | |bridge\n' > "$WORK/fixtures/stopped"

cat > "$WORK/bin/docker" <<EOF
#!/bin/bash
FIXTURES="$WORK/fixtures"
case "\$1" in
  info) [[ -f "$WORK/docker-down" ]] && exit 1; exit 0 ;;
  inspect)
    [[ -f "\$FIXTURES/\$2" ]] || exit 1
    cat "\$FIXTURES/\$2"
    exit 0
    ;;
  network)
    [[ "\$2" == connect ]] && printf 'network-connect %s %s\n' "\$3" "\$4" >> "$ACTIONS"
    exit 0
    ;;
  start|restart|stop)
    printf '%s %s\n' "\$1" "\$2" >> "$ACTIONS"
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
cat >> "$NOTICES"
EOF

cat > "$WORK/bin/breakglass" <<EOF
#!/bin/bash
# status CONTAINER
if [[ -f "$WORK/latched-\$2" ]]; then
  printf 'container=%s\nstate=exited\nrestart_policy=no\nlatched=yes\n' "\$2"
else
  printf 'container=%s\nstate=running\nrestart_policy=unless-stopped\nlatched=no\n' "\$2"
fi
EOF

cat > "$WORK/bin/guard" <<EOF
#!/bin/bash
if [[ -f "$WORK/guarded-\$2" ]]; then
  printf 'container=%s\narmed=yes\n' "\$2"
else
  printf 'container=%s\narmed=no\n' "\$2"
fi
EOF

chmod 0700 "$WORK"/bin/*
export PATH="$WORK/bin:$PATH"

cat > "$WATCHDOG_CONFIG_FILE" <<'CONFIG'
container=detached action=reattach networks=redman-docker-api threshold=3 cooldown=60 max_actions=2 window=3600
container=sick action=restart threshold=1 cooldown=60 max_actions=2 window=3600
container=stopped action=restart threshold=1 cooldown=60 max_actions=2 window=3600
CONFIG

age_last_action() {
  # Pretend the previous repair happened long enough ago to clear the cooldown.
  local file="$WORK/run/counters/$1"
  [[ -f "$file" ]] || return 0
  sed -i.bak "s/^last_action=.*/last_action=1/" "$file" && rm -f "$file.bak"
}

fail() { echo "$1" >&2; exit 1; }
refute() {
  # Asserts absence without letting a non-matching grep abort the script.
  local pattern=$1 file=$2 message=$3
  if grep -q "$pattern" "$file"; then fail "$message"; fi
}
assert() {
  local pattern=$1 file=$2 message=$3
  if ! grep -q "$pattern" "$file"; then fail "$message"; fi
}

# ── A container below its threshold is only observed ──
: > "$ACTIONS"
"$WATCHDOG" run >/dev/null
refute '^stop detached' "$ACTIONS" "acted on first failure, below threshold"
assert '^restart sick' "$ACTIONS" "threshold=1 should have acted on sick"
assert '^start stopped' "$ACTIONS" "a stopped container should be started, not restarted"

# ── The narrowest repair is chosen per fault ──
: > "$ACTIONS"
age_last_action sick
age_last_action stopped
"$WATCHDOG" run >/dev/null    # second failure for detached
"$WATCHDOG" run >/dev/null    # third failure reaches the threshold
assert '^stop detached' "$ACTIONS" "detached container was not reattached"
assert '^network-connect redman-docker-api detached' "$ACTIONS" \
  "reattach did not connect the declared network"
assert '^start detached' "$ACTIONS" "reattach did not start the container again"

# Reattach must stop before connecting, otherwise ports stay unpublished.
stop_line=$(grep -n '^stop detached' "$ACTIONS" | head -1 | cut -d: -f1)
connect_line=$(grep -n '^network-connect' "$ACTIONS" | head -1 | cut -d: -f1)
(( stop_line < connect_line )) || fail "reattach connected the network before stopping"

# ── A Breakglass latch is absolute ──
: > "$ACTIONS"
: > "$NOTICES"
touch "$WORK/latched-sick"
age_last_action sick
"$WATCHDOG" run >/dev/null
refute 'sick' "$ACTIONS" "a latched container was repaired"
assert 'action=blocked container=sick result=latched' "$NOTICES" \
  "a latched container was not reported"
rm -f "$WORK/latched-sick"

# ── An armed deployment guard is absolute ──
: > "$ACTIONS"
touch "$WORK/guarded-sick"
age_last_action sick
"$WATCHDOG" run >/dev/null
refute 'sick' "$ACTIONS" "a guarded container was repaired"
rm -f "$WORK/guarded-sick"

# ── A dead Docker daemon must not look like every container failing ──
: > "$ACTIONS"
touch "$WORK/docker-down"
age_last_action sick
# A cycle that could not run at all reports failure to its caller.
if "$WATCHDOG" run >/dev/null 2>&1; then
  fail "a skipped cycle should exit non-zero"
fi
if [[ -s "$ACTIONS" ]]; then fail "acted while the Docker daemon was unavailable"; fi
rm -f "$WORK/docker-down"

# ── The repair budget is finite ──
: > "$ACTIONS"
: > "$NOTICES"
for _ in 1 2 3 4 5; do
  age_last_action sick
  "$WATCHDOG" run >/dev/null
done
[[ "$(grep -c '^restart sick' "$ACTIONS")" -le 2 ]] \
  || fail "exceeded max_actions=2 within the window"
assert 'action=suspended container=sick' "$NOTICES" \
  "repeated failures did not suspend the container"
if [[ ! -f "$WATCHDOG_STATE_DIR/suspended/sick" ]]; then fail "suspension was not persisted"; fi

# ── A suspended container is watched but never touched ──
: > "$ACTIONS"
age_last_action sick
"$WATCHDOG" run >/dev/null
refute '^restart sick' "$ACTIONS" "a suspended container was repaired"

# ── Resuming clears the suspension and the counters ──
"$WATCHDOG" resume sick >/dev/null
if [[ -f "$WATCHDOG_STATE_DIR/suspended/sick" ]]; then fail "resume did not clear the suspension"; fi
if [[ -f "$WORK/run/counters/sick" ]]; then fail "resume did not clear the counters"; fi

echo "Restraint: threshold, narrowest repair, latch and guard deference, and repair budget hold"
