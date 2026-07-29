# Security Policy

## Threat model

Container Watchdog runs as root on an Unraid host and acts without a human in
the loop. Its value comes from being narrow: it can only nudge containers that
an operator has already listed, and only in ways that cannot destroy state.

## What it can do

- `docker start`, `docker restart`, and `docker stop` on an exact container name
  that appears in `/boot/config/plugins/container-watchdog/watch.conf`.
- `docker network connect` for such a container onto a network named in that
  same record, and only while the container is stopped.
- Read-only `docker inspect`, `docker info`, and `docker network inspect`.
- Read the Breakglass and deployment-guard status for a container.
- Write syslog entries, a bounded ntfy notification, runtime counters under
  `/run/container-watchdog`, and aggregate statistics on flash.

## What it cannot do

- Create or remove containers, images, volumes, or networks.
- Disconnect a network.
- Execute anything inside a container.
- Act on a container that is not in the allowlist, or under a name it derived
  itself.
- Act on a container latched by Container Breakglass or covered by an armed
  deployment guard.
- Stop or kill a container as a remediation. Those are Breakglass operations and
  deliberately require a human.
- Open a network listener of any kind.

## Web interface

The interface is a page rendered by the web server Unraid already runs. No
listener, port, or socket is added, and the page inherits the existing
authentication.

- Every request must be POST and must carry the host CSRF token from
  `/var/local/emhttp/var.ini`, compared with `hash_equals`.
- The page owns no logic and no state. Every operation is delegated to the
  command line tool, so the interface cannot express anything the command line
  would refuse, and configuration is never written by the web layer.
- Every value is validated against an explicit allowlist *before* it is escaped
  into a command, so a rejected value never reaches a shell at all. Arguments are
  escaped individually; no command string is assembled by concatenation.
- The only Docker call the interface makes is a read-only container listing used
  to populate the name picker.
- Values are escaped on output, both server-side and in the browser.

These properties are asserted statically by `tests/test-ui.sh`, so they cannot be
weakened without a failing test.

## Configuration integrity

- The allowlist and the credential files are refused when they are symlinks, so
  a swapped file cannot inject records or redirect a token.
- Every field is validated against an explicit pattern and bounded range. A
  record that fails validation is skipped and logged; nothing is inferred.
- Every external helper is addressed by an injected name so the hardened `PATH`
  inside the script stays authoritative.

## Secrets

- The ntfy token lives in its own file on the Unraid flash device, outside the
  repository, and is passed to `curl` through a config file so it never appears
  in the process list.
- Be aware that the flash device is FAT, where the mode `0600` the installer
  requests is not actually enforced. The real boundary is who can reach the
  `flash` share. The same applies to the installed cron fragment: anyone with
  write access to flash effectively has root cron on the host, with or without
  this plugin.
- When no local token is configured, the Container Breakglass credentials are
  reused rather than duplicated.
- The published `status.json` is aggregate-only. It contains no container names,
  networks, URLs, paths, or secrets, so it is safe to mount read-only into a
  dashboard container.

## Blast-radius controls

A watchdog that reacts too eagerly is itself an outage. Three brakes are part of
the security boundary, not a convenience:

- A fault must persist for N consecutive cycles before anything happens.
- A cooldown separates repairs of the same container.
- A rolling limit caps repairs per window; exceeding it suspends the container
  into notify-only and raises an alert.

When the Docker daemon does not answer, the entire cycle is skipped rather than
treating every container as broken.

## Reporting

Report suspected vulnerabilities privately through a GitHub security advisory on
this repository. Please do not open a public issue first.
