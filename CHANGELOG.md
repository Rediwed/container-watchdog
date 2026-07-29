# Changelog

All notable changes to Container Watchdog.

Versions are sortable dates, `YYYY.MM.DD` with an optional letter suffix, so the
Unraid plugin manager orders them correctly.

## [2026.07.29f]

### Fixed

- The ports check verified the *container* port against the host's listening
  sockets instead of the *published host* port. Any container mapped from one
  port to another, such as Nextcloud AIO publishing 8080 on 7282, was reported
  as broken while being perfectly reachable. Found by the first dry run on a
  real host, before a single notification had been sent.
- Ports are now matched per protocol, so a UDP mapping is no longer looked up in
  a TCP socket table.

## [2026.07.29e]

### Fixed

- Notifications were never sent on a fresh install. The installer always writes
  an `ntfy.conf`, and the fallback to the Container Breakglass credentials keyed
  on that file merely existing, so an empty own configuration permanently
  shadowed a working one. Each candidate is now accepted only once it yields a
  usable URL and a plausible token.
- Replaced a token length check that used a regex interval with an upper bound
  above `RE_DUP_MAX`. On platforms with the lower limit the expression is
  invalid and evaluates as false, so a valid token was rejected.

## [2026.07.29d]

### Fixed

- The web interface refused every request with "Invalid CSRF token". Unraid
  registers a global `auto_prepend_file` that validates the token with
  `hash_equals` for every POST and then removes it from `$_POST`, so the
  endpoint was comparing against a value the platform had already consumed.

### Security

- The endpoint now relies on that platform gate, which was verified empirically:
  a wrong, empty, or missing token never reaches plugin code at all. Requiring
  POST is therefore documented as the security control that engages the gate,
  since a GET would bypass it.
- Defence in depth remains: the token is still validated here if a future
  release stops removing it, the `X-CSRF-Token` header form is accepted, and a
  request carrying no token at all is refused.

## [2026.07.29c]

### Fixed

- The web interface rejected every request with "Invalid CSRF token". The page
  read the token from an ambient `$var`, which is not in scope inside an included
  file, so it emitted an empty token. It now reads `/var/local/emhttp/var.ini`
  itself, exactly as the action endpoint does.
- The installer no longer describes the plugin as command line only.

## [2026.07.29b]

### Fixed

- Reattach now validates every declared network *before* stopping the container,
  and always starts it again on any later failure. Previously an unknown or
  renamed network could leave a healthy-but-detached container fully stopped
  until the next cycle cleared the cooldown.

### Security

- The optional probe is restricted to HTTP and HTTPS and no longer follows
  redirects, so an operator-supplied URL cannot be steered elsewhere.
- Pathname expansion is disabled in the main script, so a configuration value
  containing a glob character can never match a file.
- Interface input patterns now reject a trailing newline, which PCRE would
  otherwise accept and which could split a record into a silently
  misconfigured one.
- The notifier mirrors the symlink guard on its runtime directory.

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
