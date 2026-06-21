#!/usr/bin/env bash
set -euo pipefail

require_env() {
  local name="$1"
  local value="${!name:-}"

  if [ -z "$value" ] || [ "$value" = "XXX" ]; then
    echo "ERROR: $name must be set to a non-placeholder value" >&2
    exit 1
  fi
}

require_env PROXY_USER
require_env PROXY_PASS

tailscaled_pid=""
danted_pid=""

cleanup() {
  local status="${1:-$?}"
  trap - EXIT INT TERM

  if [ -n "${tailscaled_pid:-}" ]; then
    kill "$tailscaled_pid" 2>/dev/null || true
  fi

  if [ -n "${danted_pid:-}" ]; then
    kill "$danted_pid" 2>/dev/null || true
  fi

  wait "$tailscaled_pid" "$danted_pid" 2>/dev/null || true
  exit "$status"
}

# 用环境变量里的账密创建系统用户（dante 的 username 认证走系统账户）
id "$PROXY_USER" &>/dev/null || useradd -M -s /usr/sbin/nologin "$PROXY_USER"
echo "${PROXY_USER}:${PROXY_PASS}" | chpasswd

mkdir -p /var/lib/tailscale /var/run/tailscale

tailscaled \
  --state=/var/lib/tailscale/tailscaled.state \
  --socket=/var/run/tailscale/tailscaled.sock \
  --tun=userspace-networking \
  --socks5-server=127.0.0.1:1055 &
tailscaled_pid=$!

danted -f /etc/danted.conf &
danted_pid=$!

trap 'cleanup 143' INT TERM
trap cleanup EXIT

wait -n "$tailscaled_pid" "$danted_pid" || true
echo "ERROR: tailscaled or danted exited; stopping container" >&2
exit 1
