# Installing Container Watchdog

## Requirements

- Unraid 7.0 or newer.
- Docker running on the host.
- Optional but recommended: [Container Breakglass](https://github.com/Rediwed/container-breakglass).
  Without it the watchdog cannot see latches or deployment guards, and will
  simply act on every fault it is allowed to repair.

## 1. Build the plugin

```bash
./tests/validate.sh          # runs every test and builds dist/container-watchdog.plg
```

Or build a specific version directly:

```bash
./build-plugin.sh 2026.07.29
```

The result is a single self-contained `dist/container-watchdog.plg`. Every
payload is base64-embedded with a SHA-256 that Unraid verifies on install.

## 2. Install on the host

Copy the `.plg` to the Unraid flash device and install it from
**Plugins → Install Plugin**, or point the installer at a local path such as
`/boot/config/plugins/container-watchdog.plg`.

Installation creates, without watching anything yet:

```text
/usr/local/sbin/container-watchdog
/usr/local/sbin/container-watchdog-notify
/usr/local/sbin/container-watchdog-status
/boot/config/plugins/container-watchdog/watch.conf      # empty allowlist
/boot/config/plugins/container-watchdog/ntfy.conf       # empty, falls back to Breakglass
/boot/config/plugins/container-watchdog/container-watchdog.cron
```

**Nothing is watched until you add records.** That is deliberate.

## 3. Configure notifications

If Container Breakglass is already sending ntfy notifications, skip this step —
its credentials are reused automatically.

Otherwise:

```bash
printf '%s' 'your-ntfy-token' > /boot/config/plugins/container-watchdog/ntfy.token
chmod 600 /boot/config/plugins/container-watchdog/ntfy.token
```

Then set the topic URL in `ntfy.conf`:

```text
NTFY_URL=https://ntfy.example.test/your-topic
NTFY_TOKEN_FILE=/boot/config/plugins/container-watchdog/ntfy.token
```

Only `https` URLs are accepted, and the token must be a plausible token string.
Anything else silently disables notifications rather than leaking a request.

## 4. Choose what to watch

Start conservatively. Put everything on `notify` first, watch for a week, and
only then grant repair rights where the behaviour was correct.

```bash
cat >> /boot/config/plugins/container-watchdog/watch.conf <<'EOF'
container=redman action=notify
container=nextcloud-aio-mastercontainer action=notify
EOF
```

Check what it sees, without changing anything:

```bash
container-watchdog list
container-watchdog check
container-watchdog status redman
```

When you trust it, raise the action level:

```text
container=redman action=reattach networks=redman-docker-api
```

The full syntax lives in
`/usr/local/emhttp/plugins/container-watchdog/watch.conf.example`.

### Choosing an action level

| Level | Grants | Good for |
|-------|--------|----------|
| `notify` | nothing | anything managed by another controller, or known to flap |
| `restart` | start a stopped container, restart a broken one | self-contained services |
| `reattach` | everything above, plus reconnecting a lost network | services whose network attachment has failed before |

Containers managed by a parent, such as the Nextcloud AIO children, belong on
`notify`. Repairing them behind the master container's back causes more trouble
than it solves.

## 5. Verify the schedule

The cron fragment is registered at install and after every array start. Unraid
keeps these in `/etc/cron.d/root`, not in the user crontab:

```bash
grep -A2 container-watchdog /etc/cron.d/root
```

## 6. Optional: Homepage widget

Mount the RAM-backed status directory read-only into your Homepage container and
add the widget from `README.md`:

```text
/run/container-watchdog/public:/app/public/watchdog:ro
```

## Uninstall

Remove it from the Plugins page. Removal refuses while any container is
suspended, because a suspension is an unresolved incident — resume or resolve it
first:

```bash
container-watchdog list
container-watchdog resume SOME-CONTAINER
```

Removal deletes the binaries, the configuration, and all runtime state. It never
changes container state.
