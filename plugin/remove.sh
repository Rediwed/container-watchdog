#!/bin/bash

set -euo pipefail

CONFIG_DIR="${WATCHDOG_PLUGIN_PERSIST_DIR:-/boot/config/plugins/container-watchdog}"
STATE_DIR="${WATCHDOG_STATE_DIR:-$CONFIG_DIR/state}"
SUSPEND_DIR="$STATE_DIR/suspended"
RUNTIME_DIR="${WATCHDOG_RUNTIME_DIR:-/run/container-watchdog}"
PLUGIN_RUNTIME_DIR="${WATCHDOG_PLUGIN_RUNTIME_DIR:-/usr/local/emhttp/plugins/container-watchdog}"
SBIN_DIR="${WATCHDOG_SBIN_DIR:-/usr/local/sbin}"
UPDATE_CRON="${WATCHDOG_UPDATE_CRON:-/usr/local/sbin/update_cron}"

install -d -m 0700 "$RUNTIME_DIR"
install -d -m 0700 "$SUSPEND_DIR"
exec 8>"$RUNTIME_DIR/run.lock"
flock -w 5 8

# A suspended container is an unresolved incident the operator has not closed yet.
shopt -s nullglob
suspended_files=("$SUSPEND_DIR"/*)
shopt -u nullglob
(( ${#suspended_files[@]} == 0 )) \
  || { echo "Resume or resolve all suspended containers before uninstalling." >&2; exit 1; }

echo "Removing host-local Container Watchdog configuration and runtime state."
rm -f "$SBIN_DIR/container-watchdog"
rm -f "$SBIN_DIR/container-watchdog-notify"
rm -f "$SBIN_DIR/container-watchdog-status"
rm -rf "$PLUGIN_RUNTIME_DIR"
rm -rf "$RUNTIME_DIR"
rm -rf "$CONFIG_DIR"
"$UPDATE_CRON"
echo "Container Watchdog removed. No container state was changed."
