#!/bin/bash

# The manifest heredoc below is intentionally unquoted so it can expand the
# payload variables. That also means a backtick anywhere in this file would be
# executed as a command instead of written to the manifest, so this script must
# stay free of them; tests/validate.sh enforces that.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOST_SCRIPT="$SCRIPT_DIR/src/container-watchdog"
NOTIFY_SCRIPT="$SCRIPT_DIR/src/container-watchdog-notify"
STATUS_SCRIPT="$SCRIPT_DIR/src/container-watchdog-status"
CRON_FILE="$SCRIPT_DIR/plugin/container-watchdog.cron"
EVENT_FILE="$SCRIPT_DIR/plugin/event-started.sh"
REMOVE_SCRIPT="$SCRIPT_DIR/plugin/remove.sh"
EXAMPLE_FILE="$SCRIPT_DIR/plugin/watch.conf.example"
PAGE_FILE="$SCRIPT_DIR/plugin/container-watchdog.page"
MAIN_PHP_FILE="$SCRIPT_DIR/plugin/php/watchdog_main.php"
ACTION_PHP_FILE="$SCRIPT_DIR/plugin/php/watchdog_action.php"
CSS_FILE="$SCRIPT_DIR/plugin/css/watchdog.css"
README_FILE="$SCRIPT_DIR/README.md"
DIST_DIR="$SCRIPT_DIR/dist"
OUTPUT="$DIST_DIR/container-watchdog.plg"
VERSION="${1:-2026.07.29a}"

for file in "$HOST_SCRIPT" "$NOTIFY_SCRIPT" "$STATUS_SCRIPT" "$CRON_FILE" \
  "$EVENT_FILE" "$REMOVE_SCRIPT" "$EXAMPLE_FILE" "$PAGE_FILE" "$MAIN_PHP_FILE" \
  "$ACTION_PHP_FILE" "$CSS_FILE" "$README_FILE"; do
  [[ -f "$file" ]] || { echo "Missing plugin source: $file" >&2; exit 1; }
done
[[ "$VERSION" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}[a-z]?$ ]] \
  || { echo "Version must use YYYY.MM.DD with an optional letter suffix" >&2; exit 2; }

bash -n "$HOST_SCRIPT"
bash -n "$NOTIFY_SCRIPT"
bash -n "$STATUS_SCRIPT"
bash -n "$EVENT_FILE"
bash -n "$REMOVE_SCRIPT"

# The interface is privileged PHP; a syntax error would break the whole page.
if command -v php >/dev/null 2>&1; then
  php -l "$MAIN_PHP_FILE" >/dev/null
  php -l "$ACTION_PHP_FILE" >/dev/null
fi

encode_file() {
  base64 < "$1" | tr -d '\n'
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

HOST_BASE64=$(encode_file "$HOST_SCRIPT")
NOTIFY_BASE64=$(encode_file "$NOTIFY_SCRIPT")
STATUS_BASE64=$(encode_file "$STATUS_SCRIPT")
CRON_BASE64=$(encode_file "$CRON_FILE")
EVENT_BASE64=$(encode_file "$EVENT_FILE")
EXAMPLE_BASE64=$(encode_file "$EXAMPLE_FILE")
PAGE_BASE64=$(encode_file "$PAGE_FILE")
MAIN_PHP_BASE64=$(encode_file "$MAIN_PHP_FILE")
ACTION_PHP_BASE64=$(encode_file "$ACTION_PHP_FILE")
CSS_BASE64=$(encode_file "$CSS_FILE")
README_BASE64=$(encode_file "$README_FILE")
HOST_SHA256=$(sha256_file "$HOST_SCRIPT")
NOTIFY_SHA256=$(sha256_file "$NOTIFY_SCRIPT")
STATUS_SHA256=$(sha256_file "$STATUS_SCRIPT")
CRON_SHA256=$(sha256_file "$CRON_FILE")
EVENT_SHA256=$(sha256_file "$EVENT_FILE")
EXAMPLE_SHA256=$(sha256_file "$EXAMPLE_FILE")
PAGE_SHA256=$(sha256_file "$PAGE_FILE")
MAIN_PHP_SHA256=$(sha256_file "$MAIN_PHP_FILE")
ACTION_PHP_SHA256=$(sha256_file "$ACTION_PHP_FILE")
CSS_SHA256=$(sha256_file "$CSS_FILE")
README_SHA256=$(sha256_file "$README_FILE")
REMOVE_CONTENT=$(cat "$REMOVE_SCRIPT")

mkdir -p "$DIST_DIR"
TEMPORARY=$(mktemp "$DIST_DIR/.container-watchdog.XXXXXX")
trap 'rm -f "$TEMPORARY"' EXIT

cat > "$TEMPORARY" <<EOF
<?xml version="1.0" standalone="yes"?>
<!DOCTYPE PLUGIN [
<!ENTITY name "container-watchdog">
<!ENTITY author "Rediwed">
<!ENTITY version "$VERSION">
]>
<PLUGIN name="&name;" author="&author;" version="&version;" min="7.0.0" icon="dog" pluginURL="https://github.com/Rediwed/container-watchdog/releases/latest/download/container-watchdog.plg">
  <CHANGES>
###$VERSION
- Added a web interface under Settings, Utilities, rendered by the existing
  authenticated Unraid web server. The plugin still opens no listener of its own.
- The interface shows every watched container with its verdict, action level,
  counters, suspension, and Breakglass latch state, and can suspend, resume,
  reset, add, and remove containers.
- All interface operations are delegated to the command line tool, which
  performs the authoritative validation, so the page cannot express anything the
  command line would refuse.
- Added the report, add, and remove commands so configuration is never written
  by the web layer directly.

###2026.07.29
- Initial CLI-only release.
- Detects containers that report healthy while being unreachable, including a
  lost Docker network attachment and configured port bindings that were never
  published.
- Repairs only with start, restart, or reattach, and only for exact containers
  listed in watch.conf.
- Refuses to touch a container latched by Container Breakglass or covered by an
  armed deployment guard.
- Consecutive-failure threshold, cooldown, and a rolling repair limit that
  suspends a container into notify-only instead of restarting it forever.
- Non-blocking bounded ntfy notifications, falling back to the Container
  Breakglass credentials when present.
- Sanitized read-only JSON status for Homepage custom API widgets.
- Durable aggregate failure, repair, and suspension statistics.
  </CHANGES>

  <FILE Name="/usr/local/sbin/container-watchdog" Mode="0700" Type="base64">
    <SHA256>$HOST_SHA256</SHA256>
    <INLINE>$HOST_BASE64</INLINE>
  </FILE>

  <FILE Name="/usr/local/sbin/container-watchdog-notify" Mode="0700" Type="base64">
    <SHA256>$NOTIFY_SHA256</SHA256>
    <INLINE>$NOTIFY_BASE64</INLINE>
  </FILE>

  <FILE Name="/usr/local/sbin/container-watchdog-status" Mode="0700" Type="base64">
    <SHA256>$STATUS_SHA256</SHA256>
    <INLINE>$STATUS_BASE64</INLINE>
  </FILE>

  <FILE Name="/usr/local/emhttp/plugins/&name;/event/started" Mode="0700" Type="base64">
    <SHA256>$EVENT_SHA256</SHA256>
    <INLINE>$EVENT_BASE64</INLINE>
  </FILE>

  <FILE Name="/usr/local/emhttp/plugins/&name;/README.md" Mode="0644" Type="base64">
    <SHA256>$README_SHA256</SHA256>
    <INLINE>$README_BASE64</INLINE>
  </FILE>

  <FILE Name="/usr/local/emhttp/plugins/&name;/watch.conf.example" Mode="0644" Type="base64">
    <SHA256>$EXAMPLE_SHA256</SHA256>
    <INLINE>$EXAMPLE_BASE64</INLINE>
  </FILE>

  <FILE Name="/usr/local/emhttp/plugins/&name;/container-watchdog.page" Mode="0644" Type="base64">
    <SHA256>$PAGE_SHA256</SHA256>
    <INLINE>$PAGE_BASE64</INLINE>
  </FILE>

  <FILE Name="/usr/local/emhttp/plugins/&name;/php/watchdog_main.php" Mode="0644" Type="base64">
    <SHA256>$MAIN_PHP_SHA256</SHA256>
    <INLINE>$MAIN_PHP_BASE64</INLINE>
  </FILE>

  <FILE Name="/usr/local/emhttp/plugins/&name;/php/watchdog_action.php" Mode="0644" Type="base64">
    <SHA256>$ACTION_PHP_SHA256</SHA256>
    <INLINE>$ACTION_PHP_BASE64</INLINE>
  </FILE>

  <FILE Name="/usr/local/emhttp/plugins/&name;/css/watchdog.css" Mode="0644" Type="base64">
    <SHA256>$CSS_SHA256</SHA256>
    <INLINE>$CSS_BASE64</INLINE>
  </FILE>

  <FILE Name="/boot/config/plugins/&name;/container-watchdog.cron" Mode="0600" Type="base64">
    <SHA256>$CRON_SHA256</SHA256>
    <INLINE>$CRON_BASE64</INLINE>
  </FILE>

  <FILE Run="/bin/bash">
    <INLINE><![CDATA[
set -euo pipefail
install -d -m 0700 /boot/config/plugins/container-watchdog/state/suspended
install -d -m 0700 /run/container-watchdog
install -d -m 0755 /run/container-watchdog/public
if [[ ! -f /boot/config/plugins/container-watchdog/watch.conf ]]; then
  install -m 0600 /dev/null /boot/config/plugins/container-watchdog/watch.conf
  cat > /boot/config/plugins/container-watchdog/watch.conf <<'CONFIG'
# One container per line. Nothing is watched until you add entries here.
# See watch.conf.example in the plugin directory for the full syntax.
CONFIG
  chmod 0600 /boot/config/plugins/container-watchdog/watch.conf
fi
if [[ ! -f /boot/config/plugins/container-watchdog/ntfy.conf ]]; then
  cat > /boot/config/plugins/container-watchdog/ntfy.conf <<'CONFIG'
# Leave empty to reuse the Container Breakglass credentials when that plugin is
# installed. Set both values to notify through a separate topic instead.
NTFY_URL=
NTFY_TOKEN_FILE=/boot/config/plugins/container-watchdog/ntfy.token
CONFIG
  chmod 0600 /boot/config/plugins/container-watchdog/ntfy.conf
fi
if [[ ! -f /boot/config/plugins/container-watchdog/ntfy.token ]]; then
  install -m 0600 /dev/null /boot/config/plugins/container-watchdog/ntfy.token
fi
nohup /bin/bash -c '
  for attempt in {1..10}; do
    if [[ -L /var/log/plugins/container-watchdog.plg ]]; then
      /usr/local/emhttp/plugins/container-watchdog/event/started
      exit 0
    fi
    sleep 1
  done
' >/dev/null 2>&1 &
echo "Container Watchdog $VERSION installed (CLI only)."
echo "Nothing is watched until you list containers in watch.conf."
]]></INLINE>
  </FILE>

  <FILE Run="/bin/bash" Method="remove">
    <INLINE><![CDATA[
$REMOVE_CONTENT
]]></INLINE>
  </FILE>
</PLUGIN>
EOF

xmllint --noout "$TEMPORARY"
chmod 0644 "$TEMPORARY"
mv -f "$TEMPORARY" "$OUTPUT"
trap - EXIT

echo "Built $OUTPUT"
