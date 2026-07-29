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
# A peer that can never match is worse than no check: it would report a fault
# every cycle and drive a repair loop. All of these must be refused outright.
container=peer-by-name checks=running,peer peer=tunnel.example.test:443
container=peer-without-target checks=running,peer
container=peer-no-port checks=running,peer peer=203.0.113.9
container=peer-port-zero checks=running,peer peer=203.0.113.9:0
container=peer-port-huge checks=running,peer peer=203.0.113.9:70000
container=peer-octet-overflow checks=running,peer peer=203.0.113.999:443
# A padded number is printed plainly by the socket table, so it could never
# match either. Accepting it would restart a container that is working.
container=peer-padded-port checks=running,peer peer=203.0.113.9:0443
container=peer-padded-octet checks=running,peer peer=203.0.113.09:443
CONFIG

listed=$("$WATCHDOG" list)

[[ "$listed" == *"redman action=reattach checks=running,health,network,ports networks=redman-docker-api"* ]]
[[ "$listed" == *"homepage action=restart checks=running,health networks=-"* ]]
[[ "$listed" == *"watch-only action=notify checks=running,health,network,ports networks=-"* ]]

# Exactly the three valid records survive.
[[ "$(printf '%s\n' "$listed" | grep -c .)" == 3 ]]

for rejected in bad name has space destroy telepathy reattach-without-networks \
  threshold-too-high cooldown-too-low window-too-short max-actions-zero \
  bad-url bad-status unknown-key leading-dash \
  peer-by-name peer-without-target peer-no-port peer-port-zero peer-port-huge \
  peer-octet-overflow peer-padded-port peer-padded-octet; do
  if printf '%s\n' "$listed" | grep -q -- "$rejected"; then
    echo "Malformed record was accepted: $rejected" >&2
    exit 1
  fi
done

# A well formed peer record is accepted, so the rejections above are proven to
# be about the fault and not about the field being unsupported.
printf 'container=tunnel checks=running,peer peer=203.0.113.9:443\n' > "$WATCHDOG_CONFIG_FILE"
[[ "$("$WATCHDOG" list)" == *"tunnel action=notify checks=running,peer"* ]] \
  || { echo "A valid peer record was rejected" >&2; exit 1; }

# A bracketed IPv6 peer is the first configuration value that can contain glob
# metacharacters. Parsing splits the line on whitespace, so without pathname
# expansion disabled a file in the working directory could rewrite the value:
# [2001:db8::1]:443 would collapse to 0:443 if such a file existed. The decoy
# below makes that failure real rather than theoretical.
printf 'container=six checks=running,peer peer=[2001:db8::1]:443\n' > "$WATCHDOG_CONFIG_FILE"
# The decoy has to be named for the whole word, because that is what expansion
# would rewrite: peer=[2001:db8::1]:443 collapses to peer=0:443.
: > "$WORK/peer=0:443"
listed_six=$(cd "$WORK" && "$WATCHDOG" report)
[[ "$listed_six" == *"peer=[2001:db8::1]:443"* ]] \
  || { echo "An IPv6 peer was mangled by pathname expansion: $listed_six" >&2; exit 1; }

# A configuration file that does not exist yields no records and no error.
rm -f "$WATCHDOG_CONFIG_FILE"
[[ -z "$("$WATCHDOG" list)" ]]

# A symlinked configuration is refused, so a swapped file cannot inject records.
printf 'container=injected action=restart\n' > "$WORK/elsewhere.conf"
ln -s "$WORK/elsewhere.conf" "$WATCHDOG_CONFIG_FILE"
[[ -z "$("$WATCHDOG" list)" ]]

echo "Configuration parsing: valid records accepted, malformed records skipped"
