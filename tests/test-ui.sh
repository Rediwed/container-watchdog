#!/bin/bash
# The web interface is privileged PHP running as root inside emhttp. These are
# static guarantees about what it may and may not do; they hold even on hosts
# where no PHP binary is available to lint with.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACTION="$ROOT/plugin/php/watchdog_action.php"
MAIN="$ROOT/plugin/php/watchdog_main.php"
PAGE="$ROOT/plugin/container-watchdog.page"

fail() { echo "$1" >&2; exit 1; }
assert() {
  local pattern=$1 file=$2 message=$3
  if ! grep -qE "$pattern" "$file"; then fail "$message"; fi
}
refute() {
  local pattern=$1 file=$2 message=$3
  if grep -qE "$pattern" "$file"; then fail "$message"; fi
}

# ── The page hooks into the existing web server ──
assert '^Type="php"' "$PAGE" "the page must declare its type"
assert '^Menu="Utilities"' "$PAGE" "the page must appear under Utilities"

# ── Every request is authenticated against the host CSRF token ──
assert 'hash_equals' "$ACTION" "CSRF comparison must be constant time"
assert "parse_ini_file\('/var/local/emhttp/var.ini'\)" "$ACTION" \
  "the CSRF token must come from the host state file"
# Unraid's auto_prepend_file validates and then strips the token, so requiring
# POST is what puts the request through that gate at all.
assert "REQUEST_METHOD.*!== 'POST'" "$ACTION" "mutations must require POST"
assert 'csrfSatisfied' "$ACTION" "the token must still be checked defensively"
assert 'HTTP_X_CSRF_TOKEN' "$ACTION" "the header form of the token must be handled"
# The page is an included file, so an ambient \$var is not in scope there.
assert "parse_ini_file\('/var/local/emhttp/var.ini'\)" "$MAIN" \
  "the page must read the CSRF token itself"
refute '\$var\[' "$MAIN" "the page must not rely on an ambient \$var"

# ── Nothing reaches a shell unescaped ──
assert 'escapeshellarg' "$ACTION" "arguments must be escaped"
assert 'escapeshellcmd' "$ACTION" "the command path must be escaped"
# A concatenated variable inside an exec call would defeat the escaping above.
if grep -nE '(exec|shell_exec|system|passthru|popen|proc_open)\s*\(\s*["'\'']?[^)]*\$\{?[A-Za-z_]' "$ACTION" \
  | grep -vE '\$command|\$output|\$exitCode'; then
  fail "an exec call interpolates a variable directly"
fi
refute 'shell_exec|passthru|proc_open|`' "$ACTION" "only exec may be used, and only via the helper"
# The rendering page contains JavaScript template literals, so the backtick
# operator cannot be screened here; the PHP shell functions are what matter.
refute 'shell_exec|system\s*\(|passthru|proc_open|[^a-z]exec\s*\(' "$MAIN" \
  "the rendering page must not run commands"

# ── The interface owns no state of its own ──
refute 'file_put_contents|fopen|fwrite|unlink|rename|mkdir' "$ACTION" \
  "the interface must not write configuration or state directly"
refute 'watch\.conf' "$ACTION" "the interface must not address the configuration file"

# ── It cannot express more than the command line allows ──
assert "'notify', 'restart', 'reattach'" "$ACTION" "the action level must be an allowlist"
assert "\['running', 'health', 'network', 'ports', 'http', 'peer'\]" "$ACTION" \
  "the check list must be an allowlist"
assert '\^\[A-Za-z0-9\]\[A-Za-z0-9_\.\\?-\]\{0,127\}\$' "$ACTION" \
  "container names must match the command line pattern"
for forbidden in 'docker[[:space:]]+rm' 'docker[[:space:]]+exec' 'docker[[:space:]]+kill' \
  'docker[[:space:]]+stop' 'network[[:space:]]+(create|rm|disconnect)'; do
  refute "$forbidden" "$ACTION" "the interface must not invoke Docker directly: $forbidden"
done
# The only Docker call it may make is a read-only listing for the add form.
assert 'docker ps -a --format' "$ACTION" "the container list should come from a read-only listing"

# ── Changing a level must carry every other setting along ──
assert 'select class="watchdog-level"' "$MAIN" "the action level must be editable in the table"
# The carry list is asserted literally: dropping a name here would silently reset
# that setting whenever an operator changes a level.
assert "\\['checks', 'networks', 'threshold', 'cooldown', 'max_actions', 'window', 'http', 'peer'\\]" \
  "$MAIN" "changing a level must preserve every other setting"
assert 'reattach needs at least one network' "$MAIN" \
  "switching to reattach without networks must ask rather than fail"

# ── Output is escaped before it reaches the browser ──
assert 'htmlspecialchars' "$MAIN" "server-rendered values must be escaped"
assert 'function escape' "$MAIN" "client-rendered values must be escaped"

# ── Lint when a PHP binary is available ──
if command -v php >/dev/null 2>&1; then
  php -l "$ACTION" >/dev/null
  php -l "$MAIN" >/dev/null
else
  echo "  (php not installed, skipped syntax lint)"
fi

echo "Web interface: authenticated, escaped, delegating, and no direct state or Docker access"
