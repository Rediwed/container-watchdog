# Container Watchdog for Unraid

Unraid plugin that detects containers which are *up* but broken, and repairs the
narrow set of faults that a human would otherwise have to notice first. It is the
autonomous counterpart to
[Container Breakglass](https://github.com/Rediwed/container-breakglass), and it
defers to it: a container the operator deliberately latched is never restarted.

It ships a web interface under **Settings → Utilities → Container Watchdog**, and
the full command line remains available for scripting and recovery.

## Why it exists

A container can pass its Docker health check while being completely unreachable.
The health probe runs inside the container over localhost, so a container that
lost its network attachment reports `healthy` while:

- it has no interface beyond `lo`,
- every outbound connection fails with `ENETUNREACH`,
- and none of its configured port bindings are published.

That state survived two days unnoticed on a production NAS. Docker's own
restart policy does not catch it, because the container never exits. A plain
`docker restart` does not repair it either, because the broken endpoint
configuration is reused on start.

## Safety boundary

- No network listener of its own. The interface is a page rendered by the web
  server Unraid already runs, and inherits its authentication and CSRF token.
- The interface owns no logic: every operation is delegated to the command line
  tool, which performs the authoritative validation. The page cannot express
  anything the command line would refuse.
- No shell execution inside containers.
- No container creation or removal, and no image or volume mutation.
- The only network mutation is `docker network connect` for an exact container
  onto an exact network that is named in its own configuration record. Networks
  are never created, removed, or disconnected.
- Exact container names only, from a flash-backed allowlist.
- Stop and kill are not implemented here. They are Breakglass operations, so
  they go through the audited path and leave a persistent latch.
- Every action is written to syslog with tag `container-watchdog`.
- Every action can send a bounded, best-effort ntfy notification.
- An unparseable configuration line is skipped and logged, never guessed at.
- When the Docker daemon does not answer, the whole cycle is skipped rather than
  treating every container as broken at once.

## Checks

| Check     | Detects |
|-----------|---------|
| `running` | Container is not in the running state |
| `health`  | Docker health check reports unhealthy |
| `network` | No network attached, an attached network without an address, or a declared network that is missing |
| `ports`   | Port bindings configured but never published, or a published port with nothing listening on the host |
| `http`    | Optional local probe returning an unexpected status |

`starting` is treated as acceptable, so a slow boot is never mistaken for a
fault.

## Repairs

The watchdog picks the narrowest repair that can fix the observed fault, bounded
by the `action` level the operator granted:

| Fault | Repair | Requires |
|-------|--------|----------|
| Stopped | `docker start` | `action=restart` or higher |
| Unhealthy, port not listening, failing probe | `docker restart` | `action=restart` or higher |
| Detached from its network | stop, `docker network connect`, start | `action=reattach` |
| Container not found | none, report only | — |

Reattaching stops the container first on purpose: connecting a *running*
container leaves its published ports unmapped, which is the very fault being
repaired.

## Restraint

Three independent brakes prevent a watchdog from becoming the outage:

- **Threshold** — a fault must persist for N consecutive cycles before anything
  happens, so a single bad sample is treated as noise.
- **Cooldown** — a minimum gap between repairs of the same container.
- **Rolling limit** — at most N repairs per window. On exceeding it the
  container is *suspended* into notify-only and an alert is sent, instead of
  being restarted forever.

Suspension is sticky and survives reboot. `container-watchdog resume NAME`
clears it once the underlying problem is understood.

## Breakglass integration

Before any repair the watchdog asks Breakglass about the container:

- `latched=yes` — the operator deliberately stopped it. The watchdog reports and
  stops there.
- an armed deployment guard — a deployment owns the container. The watchdog
  stays silent and out of the way.

Both tools share one ntfy credential: if `ntfy.conf` here has no URL, the
Breakglass configuration is used.

## Usage

```text
container-watchdog list              # configured containers and their settings
container-watchdog report            # machine-readable state, without checking
container-watchdog check             # run every check, repair nothing
container-watchdog status NAME       # settings, counters, and current verdict
container-watchdog run               # the scheduled cycle, used by cron
container-watchdog add container=NAME action=restart
container-watchdog remove NAME       # stop watching and forget its counters
container-watchdog suspend NAME      # keep watching, stop repairing
container-watchdog resume NAME       # allow repairs again, clear counters
container-watchdog reset NAME        # clear counters only
```

## Web interface

**Settings → Utilities → Container Watchdog** shows a tile row with the overall
status and the durable counters, followed by a table of every watched container:
its verdict, what it is allowed to do, which checks apply, consecutive failures,
repairs used in the current window, and whether it is suspended or latched.

From there you can suspend, resume, reset, inspect, and remove a container, add a
new one with a name picker fed from the running containers, and run a full check
pass on demand. Running checks never repairs anything.

The page warns when Container Breakglass is missing, because without it the
watchdog cannot see latches or deployment guards.

## Configuration

Records live in `/boot/config/plugins/container-watchdog/watch.conf`. Nothing is
watched until entries are added, through the web interface or the command line.
The full syntax is documented in `watch.conf.example`, installed alongside this
README.

```text
container=redman action=reattach networks=redman-docker-api
container=nextcloud-aio-mastercontainer action=restart
container=nextcloud-aio-nextcloud action=notify
container=homepage action=restart http=http://127.0.0.1:3000/ checks=running,health,network,ports,http
```

## Homepage status

Each cycle atomically refreshes a sanitized JSON summary at
`/run/container-watchdog/public/status.json`. It contains only aggregate counts,
durable counters, and timestamps — no container names, networks, URLs, or
paths — and the plugin still opens no network listener.

Expose the RAM-backed directory through an existing Homepage container:

```text
/run/container-watchdog/public:/app/public/watchdog:ro
```

Then add a service widget to `services.yaml`:

```yaml
- Infrastructure:
    - Container Watchdog:
        icon: mdi-dog-side
        description: Container health enforcement
        widget:
          type: customapi
          url: http://127.0.0.1:3000/watchdog/status.json
          refreshInterval: 30000
          mappings:
            - field: status
              label: Status
            - field: watched
              label: Watched
            - field: failing
              label: Failing
            - field: suspended
              label: Suspended
            - field: updated_at
              label: Updated
              format: relativeDate
              style: short
              numeric: auto

    - Watchdog Statistics:
        icon: mdi-chart-timeline-variant
        description: Persistent repair history
        widget:
          type: customapi
          url: http://127.0.0.1:3000/watchdog/status.json
          refreshInterval: 30000
          mappings:
            - field: repairs
              label: Repairs
            - field: repairs_failed
              label: Failed repairs
            - field: checks_failed
              label: Incidents
            - field: last_repair
              label: Last repair
              format: relativeDate
              style: short
              numeric: auto
            - field: last_repair_action
              label: Last action
```

## Build

```bash
./build-plugin.sh 2026.07.29b
```

Produces a self-contained `dist/container-watchdog.plg` with every payload
base64-embedded and SHA-256 verified. Install it through the Unraid plugin page.

## Uninstall

Removal refuses while any container is suspended, because a suspension is an
unresolved incident. Resume or resolve them first. Removal never changes
container state.

## Licence

MIT. See `LICENSE`.
