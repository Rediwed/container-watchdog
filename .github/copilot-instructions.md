# Container Watchdog Guidelines

## Safety Boundary

- This is a privileged Unraid host-control plugin that acts on its own. Preserve
  exact-name targeting from the flash-backed allowlist and fail closed.
- The permitted mutations are exactly `docker start`, `docker restart`,
  `docker stop` as part of a reattach, and `docker network connect` onto a
  network named in that container's own record. Never add container creation or
  removal, exec, image or volume mutation, or network create, remove, and
  disconnect.
- Stop and kill stay out of this plugin. Delegate them to Container Breakglass so
  they leave an audited persistent latch.
- A Breakglass latch and an armed deployment guard are absolute. A container in
  either state may be reported but never touched.
- Never remove a brake. Threshold, cooldown, and the rolling repair limit exist
  so a watchdog cannot become the outage. A container that exhausts its budget
  must be suspended into notify-only, never restarted again.
- A cycle must be skipped entirely when the Docker daemon does not answer, so a
  daemon outage never looks like every container failing at once.
- An unparseable configuration record is skipped and logged, never guessed at.
- Every external helper is injected by name so the hardened `PATH` stays
  authoritative and tests can substitute stubs.
- The published status stays aggregate-only: no container names, networks, URLs,
  or paths, and no network listener.
- Secrets remain host-local under `/boot/config/plugins/container-watchdog/` or
  are reused from Container Breakglass; never embed them in source or manifests.

## Changes

- Keep the self-contained `.plg` reproducible from reviewed sources.
- Bump the sortable date version for any payload change and update `CHANGELOG.md`.
- Run `./tests/validate.sh` before committing.
- Test remediation only against stubs or disposable, no-volume containers with
  cleanup traps. Never against a real service.
- Do not deploy or publish automatically.
