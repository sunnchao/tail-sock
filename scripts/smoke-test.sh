#!/usr/bin/env bash
set -euo pipefail

if [ ! -f .env ]; then
  echo "ERROR: .env not found" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

if [ -z "${PROXY_USER:-}" ] || [ -z "${PROXY_PASS:-}" ]; then
  echo "ERROR: PROXY_USER and PROXY_PASS must be set" >&2
  exit 1
fi

if [ "${PROXY_USER}" = "XXX" ] || [ "${PROXY_PASS}" = "XXX" ]; then
  echo "ERROR: PROXY_USER and PROXY_PASS must not use placeholder values" >&2
  exit 1
fi

bind_addr="${PROXY_BIND_ADDR:-127.0.0.1}"
if [ "$bind_addr" = "0.0.0.0" ]; then
  connect_addr="127.0.0.1"
else
  connect_addr="$bind_addr"
fi

docker compose config --quiet
docker compose ps

if ! docker compose exec -T socks tailscale status >/dev/null; then
  echo "ERROR: tailscale is not logged in or not running. Run: docker compose exec socks tailscale up --hostname=docker-socks5" >&2
  exit 1
fi

if ! docker compose exec -T socks tailscale ip >/dev/null; then
  echo "ERROR: no Tailscale IP is assigned. Complete tailscale login before running the proxy smoke test." >&2
  exit 1
fi

curl --fail --silent --show-error \
  --socks5-hostname "${PROXY_USER}:${PROXY_PASS}@${connect_addr}:1056" \
  https://ifconfig.me >/tmp/tailscale-socks5-smoke.out

echo "SOCKS5 smoke test passed"
