# tailscale-socks5

A **single-container** solution based on **Ubuntu 24.04**: runs both `tailscaled` (provides egress networking + built-in unauthenticated SOCKS5) and `dante-server` (provides externally-facing username/password authenticated SOCKS5) inside the same container.

No `gost` dependency, no `TS_AUTHKEY` (uses interactive login instead).

## Architecture

```
Client → Host 127.0.0.1:1056 → danted (container 0.0.0.0:1056, password auth) → tailscale built-in SOCKS5 (127.0.0.1:1055, no auth) → tailnet
                         └─────────── inside the same Ubuntu container ───────────┘
```

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Ubuntu 24.04 + tailscale + dante-server |
| `danted.conf` | dante config: 1056 with password auth, forwarding to upstream 1055 |
| `entrypoint.sh` | Creates system user + starts tailscaled + starts danted |
| `docker-compose.yaml` | Single container, exposes the proxy on host `127.0.0.1:1056` only |
| `.env` | Credentials (not committed, ignored by .gitignore) |
| `.env.example` | Template for credentials and listen address |

## Usage

### 1. Configure credentials

```bash
cp .env.example .env
# Edit .env with your own strong password
# Default PROXY_BIND_ADDR=127.0.0.1, only allows the host machine to access
```

`PROXY_USER` and `PROXY_PASS` must not be empty or left as `XXX` from the template. The container checks these on startup and exits if it finds placeholder values.

### 2. Build and start

```bash
docker compose up -d --build
```

Installs the latest Tailscale from the stable Debian repository by default. To pin a specific Tailscale version, first query available Debian packages, then pass the full version number at build time:

```bash
docker run --rm ubuntu:24.04 bash -lc 'apt-get update >/dev/null && apt-get install -y --no-install-recommends ca-certificates curl >/dev/null && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list && apt-get update >/dev/null && apt-cache madison tailscale'
docker compose build --build-arg TAILSCALE_VERSION=<full-package-version>
docker compose up -d
```

Without `TAILSCALE_VERSION`, each rebuild may pull a newer Tailscale package. Before upgrading, read the Tailscale release notes and keep a rollback-capable image or Dockerfile version.

### 3. First-time tailscale login (interactive, no authkey)

```bash
docker compose exec socks tailscale up --hostname=docker-socks5
```

This prints a `https://login.tailscale.com/...` URL — open it in a browser and authorize.
State is persisted in the `./state` volume. **No re-login needed after restarts.**

### 4. Verification

```bash
# Check logs to confirm both tailscaled and danted are running
docker compose logs -f

# Test proxy egress IP
curl --socks5-hostname user:pass@127.0.0.1:1056 https://ifconfig.me

# Run the automated smoke test (won't print passwords)
./scripts/smoke-test.sh
```

Check container health:

```bash
docker compose ps
docker inspect tailscale-socks5 --format '{{json .State.Health}}'
```

On first start or after resetting `state/`, the container shows `unhealthy` until Tailscale is authorized — this is expected. Run `docker compose exec socks tailscale up --hostname=docker-socks5`, follow the URL in the output to authorize in your browser, then re-run `./scripts/smoke-test.sh`.

## Security Notes

- Tailscale's **port 1055 is unauthenticated** and is bound to `127.0.0.1`. Only **port 1056 is exposed** in the compose file. Never map port 1055 to the host.
- Credentials are injected via `.env`. The `.env` file is in `.gitignore` and will not be committed.
- By default, compose binds port 1056 to `127.0.0.1` on the host. If you need other machines to access it, explicitly set `PROXY_BIND_ADDR=0.0.0.0`, restart, and configure firewall or security group source allowlists.

### Restricting client sources

`danted.conf` currently allows all sources for flexibility with local and trusted network access:

```conf
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
}
```

If you change `PROXY_BIND_ADDR` to `0.0.0.0`, consider narrowing the `from` range to trusted subnets, e.g.:

```conf
client pass {
    from: 10.0.0.0/8 to: 0.0.0.0/0
}
```

The `socks pass` rules can similarly be narrowed by `from` or `to` ranges. Don't rely solely on a weak password to protect a public-facing proxy.

## Operations Guide

### Health checks, logging, and resource limits

`docker-compose.yaml` includes a health check that verifies `tailscale status` and `tailscale ip` are available, then tests the Tailscale local SOCKS5 port `127.0.0.1:1055` by accessing `https://ifconfig.me`. This is more reliable than checking only for running processes and prevents an unauthenticated container from being reported as healthy.

Docker logs are capped at 3 files of 10MB each to prevent disk exhaustion during long-running sessions. The container also sets `mem_limit: 256m` and `cpus: "1.0"` as basic resource guardrails. If your Compose version or runtime doesn't support these fields, use your host or platform's resource limiting capabilities instead.

### Tailscale state directory

`./state` is mounted to `/var/lib/tailscale` inside the container and stores Tailscale's machine identity. It's not a regular cache — treat a leak like a credential leak.

- Only back up `./state` to trusted locations with restricted file permissions.
- If `./state` is leaked, remove the machine from the Tailscale admin console first, then re-login to generate new state.
- When migrating the service, you can carry `./state` to avoid re-authorization on the new host — only migrate between trusted machines.

To reset local state:

```bash
docker compose down
mv state "state.$(date +%Y%m%d%H%M%S).bak"
docker compose up -d
docker compose exec socks tailscale up --hostname=docker-socks5
```

After confirming the new state works, delete the old `state.*.bak`. Move the directory rather than deleting directly during testing, so you can roll back if needed.

### Password rotation

1. Edit `.env`, update `PROXY_PASS` (and `PROXY_USER` if needed).
2. Recreate the container to update the system user password:

```bash
docker compose up -d --force-recreate
```

3. Verify with the new password:

```bash
./scripts/smoke-test.sh
```

4. To confirm the old password is invalid, try it in `curl --socks5-hostname` — it should fail.

### Upgrading

```bash
docker compose build --no-cache
docker compose up -d
docker compose logs --tail=100
./scripts/smoke-test.sh
```

If using a pinned Tailscale version, update or pass the new `TAILSCALE_VERSION` first, then follow the steps above.

### Rollback

- If you kept the old image tag, rollback to it first.
- If the issue is in the Dockerfile or build args, restore the previous Dockerfile or `TAILSCALE_VERSION` and rebuild.
- Only restore old `./state` if machine identity also needs to roll back and the backup is trusted.
- After rollback, run `docker compose up -d --force-recreate` and `./scripts/smoke-test.sh`.

### Troubleshooting

| Symptom | Check | Resolution |
|---------|-------|------------|
| Container unhealthy | `docker compose ps`, `docker inspect tailscale-socks5 --format '{{json .State.Health}}'` | Check `docker compose logs --tail=100` to see if Tailscale login is complete |
| Tailscale not logged in or session expired | `docker compose exec socks tailscale status` | Re-run `docker compose exec socks tailscale up --hostname=docker-socks5` |
| Dante auth failure | `PROXY_USER` / `PROXY_PASS` in `.env` | Confirm it's not `XXX`, then `docker compose up -d --force-recreate` |
| `Could not resolve host` for `.ts.net` domains | Whether curl uses remote DNS | Use `curl --socks5-hostname user:pass@127.0.0.1:1056 http://target.ts.net:port/` or `curl --proxy socks5h://user:pass@127.0.0.1:1056` |
| Proxy test hangs or wrong egress | `./scripts/smoke-test.sh`, `docker compose logs --tail=100` | Confirm container health first, then check `danted.conf` `route` and Tailscale status |
| Need to reset identity | `./state` | Move old state (see "Tailscale state directory" section) and re-login |
| Logs growing too fast | `docker inspect tailscale-socks5 --format '{{json .HostConfig.LogConfig}}'` | Verify Compose logging config is applied; reduce log level or check for restart loops if needed |

### Local checks and CI recommendations

Basic checks:

```bash
bash -n entrypoint.sh
bash -n scripts/smoke-test.sh
docker compose config --quiet
```

Optional linting (skip if not installed, or install in CI):

```bash
shellcheck entrypoint.sh scripts/smoke-test.sh
hadolint Dockerfile
```

For CI pipelines, at minimum run: shell syntax check, Compose config check, ShellCheck, Hadolint, and the dry-run portion of the smoke test.

### Release checklist

1. Build: `docker compose build`
2. Start: `docker compose up -d`
3. If fresh `state`, complete `tailscale up` login.
4. Check health: `docker compose ps`
5. Run: `./scripts/smoke-test.sh`
6. Verify log limits: `docker inspect tailscale-socks5 --format '{{json .HostConfig.LogConfig}}'`
7. Confirm exposure: default is `127.0.0.1:1056`; public exposure requires explicit `PROXY_BIND_ADDR=0.0.0.0` with source restrictions.

## Known Risks

The dante upstream SOCKS5 forwarding (`route` + `proxyprotocol: socks_v5` in `danted.conf`) follows the official documentation but has not been extensively tested. If `curl` tests don't work, you may need to tweak the `external` / `route` sections, or fall back to a kernel TUN-based approach (add `cap_add: [NET_ADMIN]` + mount `/dev/net/tun` in compose, and use `tailscale up --exit-node`).
