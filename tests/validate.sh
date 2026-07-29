#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED_VERSION="2026.07.29n"

for script in \
  "$ROOT/build-plugin.sh" \
  "$ROOT/src/container-watchdog" \
  "$ROOT/src/container-watchdog-notify" \
  "$ROOT/src/container-watchdog-status" \
  "$ROOT/plugin/event-started.sh" \
  "$ROOT/plugin/remove.sh"; do
  bash -n "$script"
done

bash "$ROOT/tests/test-config.sh"
bash "$ROOT/tests/test-checks.sh"
bash "$ROOT/tests/test-safety.sh"
bash "$ROOT/tests/test-status.sh"
bash "$ROOT/tests/test-notify.sh"
bash "$ROOT/tests/test-notice.sh"
bash "$ROOT/tests/test-ui.sh"

"$ROOT/build-plugin.sh" "$EXPECTED_VERSION" >/dev/null
xmllint --noout "$ROOT/dist/container-watchdog.plg"

python3 - "$ROOT/dist/container-watchdog.plg" "$EXPECTED_VERSION" <<'PY'
import base64
import hashlib
import sys
import xml.etree.ElementTree as ET

manifest, expected_version = sys.argv[1:]
root = ET.parse(manifest).getroot()
assert root.get('version') == expected_version
files = [node for node in root.findall('FILE') if node.find('SHA256') is not None]
assert len(files) == 11, len(files)
for node in files:
    assert node.get('Type') == 'base64', node.get('Name')
    payload = base64.b64decode((node.findtext('INLINE') or '').strip(), validate=True)
    assert hashlib.sha256(payload).hexdigest() == (node.findtext('SHA256') or '').strip(), node.get('Name')
PY

# Removal must refuse while an incident is still open, and must never touch containers.
uninstall_root=$(mktemp -d)
trap 'rm -rf "$uninstall_root"' EXIT
original_path=$PATH
mkdir -p "$uninstall_root/bin"
cat > "$uninstall_root/bin/flock" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 0700 "$uninstall_root/bin/flock"
export PATH="$uninstall_root/bin:$PATH"
export WATCHDOG_RUNTIME_DIR="$uninstall_root/run"
export WATCHDOG_PLUGIN_PERSIST_DIR="$uninstall_root/persist-plugin"
export WATCHDOG_STATE_DIR="$uninstall_root/persist-plugin/state"
export WATCHDOG_PLUGIN_RUNTIME_DIR="$uninstall_root/runtime-plugin"
export WATCHDOG_SBIN_DIR="$uninstall_root/sbin"
WATCHDOG_UPDATE_CRON="$(command -v true)"
export WATCHDOG_UPDATE_CRON
mkdir -p "$WATCHDOG_RUNTIME_DIR" "$WATCHDOG_STATE_DIR/suspended" \
  "$WATCHDOG_PLUGIN_RUNTIME_DIR" "$WATCHDOG_SBIN_DIR"
touch "$WATCHDOG_SBIN_DIR/container-watchdog"
touch "$WATCHDOG_SBIN_DIR/container-watchdog-status"
touch "$WATCHDOG_STATE_DIR/suspended/open-incident"
! "$ROOT/plugin/remove.sh" >/dev/null 2>&1
[[ -e "$WATCHDOG_SBIN_DIR/container-watchdog" ]]
rm -f "$WATCHDOG_STATE_DIR/suspended/open-incident"
"$ROOT/plugin/remove.sh" >/dev/null
[[ ! -e "$WATCHDOG_SBIN_DIR/container-watchdog" ]]
[[ ! -e "$WATCHDOG_SBIN_DIR/container-watchdog-status" ]]
[[ ! -e "$WATCHDOG_PLUGIN_RUNTIME_DIR" ]]
[[ ! -e "$WATCHDOG_PLUGIN_PERSIST_DIR" ]]
unset WATCHDOG_RUNTIME_DIR WATCHDOG_PLUGIN_PERSIST_DIR WATCHDOG_STATE_DIR \
  WATCHDOG_PLUGIN_RUNTIME_DIR WATCHDOG_SBIN_DIR WATCHDOG_UPDATE_CRON
export PATH=$original_path
rm -rf "$uninstall_root"
trap - EXIT

# A regex interval whose upper bound exceeds RE_DUP_MAX is invalid on some
# platforms, where the match then silently evaluates as false rather than
# raising. Keep bounds small and check longer lengths explicitly.
if grep -REn '\{[0-9]+,(2[6-9][0-9]|[3-9][0-9]{2}|[0-9]{4,})\}' "$ROOT/src"; then
  echo "Regex interval upper bound above 255 is not portable" >&2
  exit 1
fi

# The manifest heredoc is unquoted so it can expand payload variables, which
# means a stray backtick would be executed instead of written.
if grep -q '`' "$ROOT/build-plugin.sh"; then
  echo "build-plugin.sh contains a backtick, which the unquoted heredoc would execute" >&2
  exit 1
fi

# The plugin must never gain the capabilities it promises not to have.
forbidden='docker[[:space:]]+(rm|rmi|exec|volume|image|build|run)\b|network[[:space:]]+(create|rm|disconnect)\b'
if grep -REq "$forbidden" "$ROOT/src" "$ROOT/plugin"; then
  echo "Forbidden Docker capability found in plugin sources" >&2
  exit 1
fi
secret_pattern='(tk_[A-Za-z0-9]{12,}|AKIA[A-Z0-9]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|password[=:][^[:space:]]+|secret[=:][^[:space:]]+|api[_-]?key[=:][^[:space:]]+|/Users/|/home/[A-Za-z0-9._-]+/|10\.[0-9]{1,3}\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)'
secret_found=false
grep -RqIE --exclude-dir=.git --exclude-dir=dist --exclude=validate.sh "$secret_pattern" "$ROOT" && secret_found=true
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$ROOT" grep --cached -IqE "$secret_pattern" -- . ':!tests/validate.sh' && secret_found=true
fi
if $secret_found; then
  echo "Potential secret or private host data found" >&2
  exit 1
fi

echo "Container Watchdog validation passed: $EXPECTED_VERSION"
