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

## Configuration integrity

- The allowlist and the credential files are refused when they are symlinks, so
  a swapped file cannot inject records or redirect a token.
- Every field is validated against an explicit pattern and bounded range. A
  record that fails validation is skipped and logged; nothing is inferred.
- Every external helper is addressed by an injected name so the hardened `PATH`
  inside the script stays authoritative.

## Secrets

- The ntfy token lives in a mode `0600` file on the Unraid flash device, outside
  the repository, and is passed to `curl` through a mode `0600` config file so it
  never appears in the process list.
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
