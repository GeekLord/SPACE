
# Docker Desktop

Ensure the Docker daemon is running and responsive on macOS Docker Desktop. If a task needs Docker (`docker`, `kind`, `k3d`, `docker-compose`, etc.) and the daemon is hung or not started, run the script below before giving up. Never just bail out and ask the user to start Docker.

## When to use

Use this reference the moment any of these signals appear:

- `docker info`, `docker ps`, or any `docker` command hangs, returns "EOF", or fails with "Cannot connect to the Docker daemon"
- `kind create cluster` errors with `failed to list clusters: ... command "docker ps ..." failed`
- A task you are about to perform requires the Docker daemon (kind clusters, container builds, compose stacks)

## Usage

Run the bundled script relative to the `space-validation` skill directory:

```bash
scripts/ensure-docker.sh
```

The script:

1. Probes the daemon with `docker info` (5s timeout).
2. If it is responsive, exits 0 immediately.
3. If Docker Desktop is running but the daemon is hung, waits up to 30s for it to come around.
4. If still hung, gracefully quits Docker Desktop, then re-launches it.
5. If Docker Desktop is not running, launches it.
6. Polls the daemon for up to 90s after launch.
7. As a last resort, force-kills lingering Docker processes and re-launches once more.
8. On final failure, prints diagnostics: process list, socket path, and tail of Docker Desktop logs.

Exit code is 0 if the daemon is responsive, 1 if all attempts failed.

## Scope

- macOS Docker Desktop only. For OrbStack, Colima, Rancher Desktop, or Linux Docker Engine, do not use this procedure.
- Does not modify Docker config or settings. Only starts, stops, and waits.
