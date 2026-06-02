#!/usr/bin/env bash
set -euo pipefail

# 用环境变量里的账密创建系统用户（dante 的 username 认证走系统账户）
id "$PROXY_USER" &>/dev/null || useradd -M -s /usr/sbin/nologin "$PROXY_USER"
echo "${PROXY_USER}:${PROXY_PASS}" | chpasswd

mkdir -p /var/lib/tailscale /var/run/tailscale

tailscaled \
  --state=/var/lib/tailscale/tailscaled.state \
  --socket=/var/run/tailscale/tailscaled.sock \
  --tun=userspace-networking \
  --socks5-server=127.0.0.1:1055 &

danted -f /etc/danted.conf &

wait -n   # 任一进程退出则容器退出，交给 restart 策略
