# tailscale-socks5

基于 **Ubuntu 24.04** 的单容器方案：在容器内同时运行 `tailscaled`（提供出口网络 + 内置无认证 SOCKS5）和 `dante-server`（对外提供账号密码认证的 SOCKS5）。

不依赖 `gost`，不使用 `TS_AUTHKEY`（改用交互式登录）。

## 架构

```
客户端 → danted (0.0.0.0:1056, 账密认证) → tailscale 内置 SOCKS5 (127.0.0.1:1055, 无认证) → tailnet
                          └──────────── 同一个 Ubuntu 容器内 ────────────┘
```

## 文件说明

| 文件 | 作用 |
|------|------|
| `Dockerfile` | Ubuntu 24.04 + tailscale + dante-server |
| `danted.conf` | dante 配置：1056 账密认证，转发到上游 1055 |
| `entrypoint.sh` | 建系统用户 + 启动 tailscaled + 启动 danted |
| `docker-compose.yaml` | 单容器，只对外暴露 1056 |
| `.env` | 账号密码（不提交，已被 .gitignore 忽略） |
| `.env.example` | 账密模板 |

## 使用

### 1. 配置账密

```bash
cp .env.example .env
# 编辑 .env 改成你自己的强密码
```

### 2. 构建并启动

```bash
docker compose up -d --build
```

### 3. 首次登录 tailscale（交互式，不用 authkey）

```bash
docker compose exec socks tailscale up --hostname=docker-socks5
```

会打印一个 `https://login.tailscale.com/...` 链接，浏览器打开授权即可。
状态存进 `./state` 卷，**之后重启不用再登录**。

### 4. 验证

```bash
# 查看日志，确认 tailscaled 和 danted 都已启动
docker compose logs -f

# 测试代理出口 IP
curl --socks5 用户名:密码@127.0.0.1:1056 https://ifconfig.me
```

## 安全提醒

- tailscale 的 **1055 是无认证端口**，已绑定 `127.0.0.1`，compose 中**只暴露 1056**。切勿把 1055 映射到宿主机。
- 账密通过 `.env` 注入，`.env` 已加入 `.gitignore`，不会被提交。

## 已知风险点

dante 的上游 SOCKS5 转发（`danted.conf` 中的 `route` + `proxyprotocol: socks_v5`）写法符合官方文档，但未实测。若 curl 测试不通，多半需要微调 `external` / `route` 段，或退回到内核态 TUN 方案（在 compose 中加 `cap_add: [NET_ADMIN]` + 挂载 `/dev/net/tun`，并用 `tailscale up --exit-node`）。
