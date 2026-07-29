#!/bin/bash
# The published status must be valid JSON, aggregate-only, and must never leak a
# container name, network, URL, or path to a dashboard consumer.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATUS="$ROOT/src/container-watchdog-status"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export WATCHDOG_CONFIG_DIR="$WORK/config"
export WATCHDOG_CONFIG_FILE="$WORK/config/watch.conf"
export WATCHDOG_STATE_DIR="$WORK/config/state"
export WATCHDOG_RUNTIME_DIR="$WORK/run"
export WATCHDOG_FLOCK_TOOL="$WORK/bin/flock"
mkdir -p "$WATCHDOG_CONFIG_DIR" "$WATCHDOG_STATE_DIR/suspended" "$WORK/run/counters" "$WORK/bin"

cat > "$WORK/bin/flock" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 0700 "$WORK/bin/flock"

STATUS_FILE="$WORK/run/public/status.json"

cat > "$WATCHDOG_CONFIG_FILE" <<'CONFIG'
# A comment must not be counted as a watched container.
container=secret-service action=reattach networks=private-network
container=another-service
container=third-service
CONFIG

printf 'fails=4\nactions=1\nwindow_start=1\nlast_action=1\nlast_verdict=fail\n' \
  > "$WORK/run/counters/secret-service"
printf 'fails=0\nactions=0\nwindow_start=1\nlast_action=1\nlast_verdict=ok\n' \
  > "$WORK/run/counters/another-service"
touch "$WATCHDOG_STATE_DIR/suspended/secret-service"

cat > "$WATCHDOG_STATE_DIR/statistics" <<'STATS'
format=1
checks_failed=7
repairs=4
repairs_failed=1
suspensions=2
last_failure_at=2026-07-29T06:18:02Z
last_repair_at=2026-07-29T06:20:11Z
last_repair_action=reattach
STATS

bash "$STATUS"
[[ -f "$STATUS_FILE" ]] || { echo "status.json was not written" >&2; exit 1; }

python3 - "$STATUS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as handle:
    data = json.load(handle)

expected = {
    'status', 'watched', 'failing', 'suspended', 'checks_failed', 'repairs',
    'repairs_failed', 'suspensions', 'last_failure', 'last_repair',
    'last_repair_action', 'updated_at',
}
assert set(data) == expected, f"unexpected keys: {set(data) ^ expected}"
assert data['watched'] == 3, data['watched']
assert data['failing'] == 1, data['failing']
assert data['suspended'] == 1, data['suspended']
assert data['repairs'] == 4
assert data['repairs_failed'] == 1
assert data['checks_failed'] == 7
assert data['last_repair_action'] == 'reattach'
# A suspension outranks a plain failure in the headline.
assert data['status'] == 'Suspended', data['status']

leaky = ('secret-service', 'another-service', 'third-service', 'private-network',
         '/boot', '/run', 'http')
blob = json.dumps(data)
for needle in leaky:
    assert needle not in blob, f"status.json leaked {needle!r}"
PY

# A corrupted statistics file must degrade visibly instead of publishing nonsense.
printf 'format=99\nchecks_failed=oops\n' > "$WATCHDOG_STATE_DIR/statistics"
bash "$STATUS"
python3 - "$STATUS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as handle:
    data = json.load(handle)
assert data['status'] == 'Unavailable', data['status']
assert data['repairs'] == 0
PY

# With nothing configured the watchdog is idle, not broken.
rm -f "$WATCHDOG_STATE_DIR/statistics"
rm -f "$WATCHDOG_STATE_DIR/suspended/secret-service"
rm -f "$WORK/run/counters"/*
: > "$WATCHDOG_CONFIG_FILE"
bash "$STATUS"
python3 - "$STATUS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as handle:
    data = json.load(handle)
assert data['status'] == 'Idle', data['status']
assert data['watched'] == 0
PY

echo "Published status: valid JSON, aggregate only, no container detail leaked"
