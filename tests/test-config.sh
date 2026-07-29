#!/bin/bash
# Configuration parsing: valid records are accepted exactly, malformed records
# are skipped rather than guessed at.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WATCHDOG="$ROOT/src/container-watchdog"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export WATCHDOG_CONFIG_DIR="$WORK/config"
export WATCHDOG_CONFIG_FILE="$WORK/config/watch.conf"
export WATCHDOG_STATE_DIR="$WORK/config/state"
export WATCHDOG_RUNTIME_DIR="$WORK/run"
export WATCHDOG_NOTIFY_TOOL="$WORK/absent-notify"
export WATCHDOG_STATUS_TOOL="$WORK/absent-status"
mkdir -p "$WATCHDOG_CONFIG_DIR"

cat > "$WATCHDOG_CONFIG_FILE" <<'CONFIG'
# Comments and blank lines are ignored.

container=redman action=reattach networks=redman-docker-api

   container=homepage    action=restart   checks=running,health
container=watch-only

# Malformed records below must all be skipped.
container=bad name
container=has space action=restart
action=restart
container=reattach-without-networks action=reattach
container=unknown-check checks=running,telepathy
container=bad-action action=destroy
container=threshold-too-high threshold=101
container=cooldown-too-low cooldown=10
container=window-too-short window=60
container=max-actions-zero max_actions=0
container=bad-url checks=http http=ftp://example.test/probe
container=bad-status http_status=999
container=unknown-key colour=blue
container=-leading-dash
CONFIG

listed=$("$WATCHDOG" list)

[[ "$listed" == *"redman action=reattach checks=running,health,network,ports networks=redman-docker-api"* ]]
[[ "$listed" == *"homepage action=restart checks=running,health networks=-"* ]]
[[ "$listed" == *"watch-only action=notify checks=running,health,network,ports networks=-"* ]]

# Exactly the three valid records survive.
[[ "$(printf '%s\n' "$listed" | grep -c .)" == 3 ]]

for rejected in bad name has space destroy telepathy reattach-without-networks \
  threshold-too-high cooldown-too-low window-too-short max-actions-zero \
  bad-url bad-status unknown-key leading-dash; do
  if printf '%s\n' "$listed" | grep -q -- "$rejected"; then
    echo "Malformed record was accepted: $rejected" >&2
    exit 1
  fi
done

# A configuration file that does not exist yields no records and no error.
rm -f "$WATCHDOG_CONFIG_FILE"
[[ -z "$("$WATCHDOG" list)" ]]

# A symlinked configuration is refused, so a swapped file cannot inject records.
printf 'container=injected action=restart\n' > "$WORK/elsewhere.conf"
ln -s "$WORK/elsewhere.conf" "$WATCHDOG_CONFIG_FILE"
[[ -z "$("$WATCHDOG" list)" ]]

echo "Configuration parsing: valid records accepted, malformed records skipped"
