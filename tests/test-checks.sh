#!/bin/bash
# Fault detection: each broken state is recognised and mapped to the fault class
# that drives remediation. Uses stubs; no real container is inspected.

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
export WATCHDOG_BREAKGLASS_TOOL="$WORK/absent-breakglass"
export WATCHDOG_GUARD_TOOL="$WORK/absent-guard"
export WATCHDOG_DOCKER_TOOL="$WORK/bin/docker"
export WATCHDOG_SS_TOOL="$WORK/bin/ss"
export WATCHDOG_TIMEOUT_TOOL="$WORK/bin/timeout"
mkdir -p "$WATCHDOG_CONFIG_DIR" "$WORK/bin" "$WORK/fixtures"

# state|health|networks|expected_ports|active_ports|network_mode
printf 'running|healthy|bridge~192.0.2.4 |8091/tcp |8091~8091/tcp |bridge\n' > "$WORK/fixtures/good"
printf 'running|starting|bridge~192.0.2.4 | | |bridge\n' > "$WORK/fixtures/booting"
printf 'running|healthy|| | |redman-docker-api\n' > "$WORK/fixtures/detached"
printf 'running|healthy|bridge~ | | |bridge\n' > "$WORK/fixtures/no-address"
printf 'running|healthy|bridge~192.0.2.4 |8091/tcp | |bridge\n' > "$WORK/fixtures/unpublished"
printf 'running|healthy|bridge~192.0.2.4 |9999/tcp |9999~9999/tcp |bridge\n' > "$WORK/fixtures/silent-port"
printf 'running|healthy|bridge~192.0.2.4 |8080/tcp |8091~8080/tcp |bridge\n' > "$WORK/fixtures/remapped"
printf 'running|healthy|bridge~192.0.2.4 |53/udp |5353~53/udp |bridge\n' > "$WORK/fixtures/udp-only"
printf 'running|unhealthy|bridge~192.0.2.4 | | |bridge\n' > "$WORK/fixtures/sick"
printf 'exited|none|| | |bridge\n' > "$WORK/fixtures/stopped"
printf 'running|healthy|other~192.0.2.20 | | |other\n' > "$WORK/fixtures/wrong-network"
printf 'running|none|| | |host\n' > "$WORK/fixtures/host-mode"

cat > "$WORK/bin/docker" <<EOF
#!/bin/bash
FIXTURES="$WORK/fixtures"
ACTIONS="$WORK/actions.log"
case "\$1" in
  info) exit 0 ;;
  inspect)
    [[ -f "\$FIXTURES/\$2" ]] || exit 1
    cat "\$FIXTURES/\$2"
    exit 0
    ;;
  network)
    printf '%s\n' "network \$2 \$3 \$4" >> "\$ACTIONS"
    [[ "\$2" == inspect && "\$3" != known-network ]] && exit 1
    exit 0
    ;;
  start|restart|stop)
    printf '%s\n' "\$1 \$2" >> "\$ACTIONS"
    exit 0
    ;;
esac
exit 1
EOF
chmod 0700 "$WORK/bin/docker"

cat > "$WORK/bin/ss" <<'EOF'
#!/bin/bash
# Only port 8091 is listening on this fake host.
echo "State  Recv-Q Send-Q Local Address:Port  Peer Address:Port"
echo "LISTEN 0      4096   127.0.0.1:8091   0.0.0.0:*"
EOF
chmod 0700 "$WORK/bin/ss"

# The script hardens PATH, so every helper is injected by name instead. The
# timeout shim keeps these tests runnable on hosts without coreutils.
cat > "$WORK/bin/timeout" <<'EOF'
#!/bin/bash
while [[ "${1:-}" == -* ]]; do
  [[ "$1" == -k ]] && shift
  shift
done
shift
exec "$@"
EOF
chmod 0700 "$WORK/bin/timeout"
export PATH="$WORK/bin:$PATH"

cat > "$WATCHDOG_CONFIG_FILE" <<'CONFIG'
container=good
container=booting
container=detached
container=no-address
container=unpublished
container=silent-port
container=sick
container=stopped
container=wrong-network networks=known-network
container=host-mode
container=remapped
container=udp-only
container=absent
CONFIG

verdict_for() {
  "$WATCHDOG" status "$1" 2>/dev/null | tr '\n' ' '
}

assert_verdict() {
  local name=$1 expected_reason=$2 expected_fault=$3 output
  output=$(verdict_for "$name")
  if [[ -z "$expected_reason" ]]; then
    [[ "$output" == *"verdict=ok"* ]] || { echo "$name should be ok, got: $output" >&2; exit 1; }
    return
  fi
  [[ "$output" == *"reason=$expected_reason"* ]] \
    || { echo "$name expected reason=$expected_reason, got: $output" >&2; exit 1; }
  [[ "$output" == *"fault=$expected_fault"* ]] \
    || { echo "$name expected fault=$expected_fault, got: $output" >&2; exit 1; }
}

assert_verdict good "" ""
# A slow boot must never be mistaken for a fault.
assert_verdict booting "" ""
# Host networking legitimately has no bridge attachment.
assert_verdict host-mode "" ""
# The exact production failure: healthy, but no interface beyond loopback.
assert_verdict detached no-network detached
assert_verdict no-address no-address-bridge detached
# Bindings configured but never published: a restart would not repair this.
assert_verdict unpublished ports-unpublished detached
assert_verdict silent-port port-9999-not-listening unhealthy
# The container port is 8080 but it is published on 8091, which is the one that
# has to be listening. Checking the container port would report a false fault.
assert_verdict remapped "" ""
# Only TCP can be verified with a listening socket table.
assert_verdict udp-only "" ""
assert_verdict sick health-unhealthy unhealthy
assert_verdict stopped state-exited stopped
assert_verdict wrong-network missing-network-known-network detached
assert_verdict absent not-found missing

# Inspection alone must never mutate anything.
[[ ! -s "$WORK/actions.log" ]] || { echo "Checks caused container actions" >&2; exit 1; }

# A dry run reports every fault without repairing.
report=$("$WATCHDOG" check)
[[ "$report" == *"container=detached verdict=fail"* ]]
[[ "$report" == *"container=good verdict=ok"* ]]
[[ ! -s "$WORK/actions.log" ]] || { echo "Dry run caused container actions" >&2; exit 1; }

echo "Fault detection: detachment, unpublished ports, health, and state recognised"
