#!/bin/bash
# Notification delivery: the installer always writes a configuration file, so
# falling back to Container Breakglass must depend on the contents being usable
# rather than on the file merely existing.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOTIFY="$ROOT/src/container-watchdog-notify"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
SENT="$WORK/sent.log"
: > "$SENT"

cat > "$WORK/bin/curl" <<EOF
#!/bin/bash
# Records the resolved endpoint without ever revealing the token.
config=""
while [[ \$# -gt 0 ]]; do
  [[ "\$1" == --config ]] && { config=\$2; shift 2; continue; }
  shift
done
grep -m1 '^url' "\$config" >> "$SENT"
exit 0
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
chmod 0700 "$WORK"/bin/*

export WATCHDOG_RUNTIME_DIR="$WORK/run"
export WATCHDOG_CURL_TOOL="$WORK/bin/curl"
export WATCHDOG_TIMEOUT_TOOL="$WORK/bin/timeout"
export WATCHDOG_NTFY_CONFIG="$WORK/own.conf"
export WATCHDOG_NTFY_FALLBACK_CONFIG="$WORK/fallback.conf"

printf 'a-valid-looking-token-value\n' > "$WORK/own.token"
printf 'a-valid-looking-token-value\n' > "$WORK/fallback.token"

fail() { echo "$1" >&2; exit 1; }
last_sent() { tail -1 "$SENT" 2>/dev/null || true; }

# ── An empty configuration must not shadow the fallback ──
# This is exactly what the installer leaves behind on a fresh host.
cat > "$WATCHDOG_NTFY_CONFIG" <<CONF
NTFY_URL=
NTFY_TOKEN_FILE=$WORK/own.token
CONF
cat > "$WATCHDOG_NTFY_FALLBACK_CONFIG" <<CONF
NTFY_URL=https://ntfy.example.test/fallback-topic
NTFY_TOKEN_FILE=$WORK/fallback.token
CONF
: > "$SENT"
printf 'action=degraded container=demo result=notify-only' | bash "$NOTIFY"
[[ "$(last_sent)" == *fallback-topic* ]] \
  || fail "an empty own configuration did not fall back to Breakglass"

# ── A configured own topic wins ──
cat > "$WATCHDOG_NTFY_CONFIG" <<CONF
NTFY_URL=https://ntfy.example.test/own-topic
NTFY_TOKEN_FILE=$WORK/own.token
CONF
: > "$SENT"
printf 'action=degraded container=demo result=notify-only' | bash "$NOTIFY"
[[ "$(last_sent)" == *own-topic* ]] || fail "a configured own topic was not used"

# ── A missing token file falls through to the fallback ──
cat > "$WATCHDOG_NTFY_CONFIG" <<CONF
NTFY_URL=https://ntfy.example.test/own-topic
NTFY_TOKEN_FILE=$WORK/absent.token
CONF
: > "$SENT"
printf 'action=degraded container=demo result=notify-only' | bash "$NOTIFY"
[[ "$(last_sent)" == *fallback-topic* ]] || fail "a missing token did not fall through"

# ── Plain HTTP and other schemes are refused outright ──
for rejected in 'http://ntfy.example.test/topic' 'ftp://ntfy.example.test/topic' 'https://ntfy.example.test'; do
  cat > "$WATCHDOG_NTFY_CONFIG" <<CONF
NTFY_URL=$rejected
NTFY_TOKEN_FILE=$WORK/own.token
CONF
  : > "$WATCHDOG_NTFY_FALLBACK_CONFIG"
  : > "$SENT"
  printf 'action=degraded container=demo result=notify-only' | bash "$NOTIFY"
  [[ -s "$SENT" ]] && fail "an unusable URL was still contacted: $rejected"
done

# ── A short or malformed token is refused ──
cat > "$WATCHDOG_NTFY_CONFIG" <<CONF
NTFY_URL=https://ntfy.example.test/own-topic
NTFY_TOKEN_FILE=$WORK/short.token
CONF
printf 'short\n' > "$WORK/short.token"
: > "$SENT"
printf 'action=degraded container=demo result=notify-only' | bash "$NOTIFY"
[[ -s "$SENT" ]] && fail "a malformed token was still used"

# ── No message means no request ──
: > "$SENT"
printf '' | bash "$NOTIFY"
[[ -s "$SENT" ]] && fail "an empty message produced a request"

echo "Notifications: usable-configuration fallback, scheme and token validation hold"
