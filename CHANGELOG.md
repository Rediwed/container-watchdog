# Changelog

All notable changes to Container Watchdog.

Versions are sortable dates, `YYYY.MM.DD` with an optional letter suffix, so the
Unraid plugin manager orders them correctly.

## [2026.07.29a]

### Added

- Web interface under **Settings → Utilities → Container Watchdog**, rendered by
  the web server Unraid already runs. The plugin still opens no listener of its
  own and inherits the existing authentication and CSRF token.
- The interface lists every watched container with its verdict, action level,
  checks, networks, counters, suspension, and Breakglass latch state, and can
  suspend, resume, reset, inspect, add, and remove containers, or run a check
  pass on demand.
- `report`, `add`, and `remove` commands, so the web layer never writes
  configuration itself and every record passes the same validation as the
  command line.

### Security

- Interface requests are rejected unless they are POST and carry the host CSRF
  token, compared with a constant-time comparison.
- Every value is validated against an allowlist before it is escaped into a
  command, so a rejected value never reaches a shell.
- The interface performs no Docker mutation of its own; its only Docker call is a
  read-only container listing for the add form.

## [2026.07.29]

### Added

- Initial CLI-only release.
- Detection of containers that report healthy while being unreachable: no
  network attachment, an attached network without an address, a declared network
  that went missing, port bindings that were configured but never published, and
  published ports with nothing listening on the host.
- Optional Docker health and local HTTP probes, with `starting` treated as
  acceptable so a slow boot is never mistaken for a fault.
- Remediation limited to `start`, `restart`, and `reattach`, chosen as the
  narrowest repair for the observed fault and bounded by a per-container action
  level.
- Reattach stops the container before connecting its network, because connecting
  a running container leaves its published ports unmapped.
- Deference to Container Breakglass: a latched container or one covered by an
  armed deployment guard is reported but never touched.
- Three independent brakes: a consecutive-failure threshold, a cooldown between
  repairs, and a rolling repair limit that suspends a container into notify-only
  instead of restarting it forever.
- Suspension persists across reboot and blocks uninstall until resolved.
- Whole-cycle skip when the Docker daemon does not answer.
- Non-blocking bounded ntfy notifications, falling back to the Container
  Breakglass credentials when its configuration is present.
- Sanitized read-only JSON status for Homepage custom API widgets, containing
  aggregates only.
- Durable aggregate failure, repair, and suspension statistics, written only on
  real events so the flash device is not touched every cycle.
