# tailscale-socks5

基于 **Ubuntu 24.04** 的单容器方案：在容器内同时运行 `tailscaled`（提供出口网络 + 内置无认证 SOCKS5）和 `dante-server`（对外提供账号密码认证的 SOCKS5）。

不依赖 `gost`，不使用 `TS_AUTHKEY`（改用交互式登录）。

## 架构

```
客户端 → 宿主机 127.0.0.1:1056 → danted (容器内 0.0.0.0:1056, 账密认证) → tailscale 内置 SOCKS5 (127.0.0.1:1055, 无认证) → tailnet
                          └──────────── 同一个 Ubuntu 容器内 ────────────┘
```

## 文件说明

| 文件 | 作用 |
|------|------|
| `Dockerfile` | Ubuntu 24.04 + tailscale + dante-server |
| `danted.conf` | dante 配置：1056 账密认证，转发到上游 1055 |
| `entrypoint.sh` | 建系统用户 + 启动 tailscaled + 启动 danted |
| `docker-compose.yaml` | 单容器，默认只在宿主机 `127.0.0.1:1056` 暴露代理 |
| `.env` | 账号密码（不提交，已被 .gitignore 忽略） |
| `.env.example` | 账密和监听地址模板 |

## 使用

### 1. 配置账密

```bash
cp .env.example .env
# 编辑 .env 改成你自己的强密码
# 默认 PROXY_BIND_ADDR=127.0.0.1，只允许宿主机本机访问
```

`PROXY_USER` 和 `PROXY_PASS` 不能为空，也不能保留为模板里的 `XXX`。容器启动时会检查这两个变量，发现占位值会直接退出。

### 2. 构建并启动

```bash
docker compose up -d --build
```

默认安装当前 Tailscale stable 源中的最新版。若需要固定 Tailscale 版本，可先查询可用 Debian 包版本，再在构建时传入完整版本号：

```bash
docker run --rm ubuntu:24.04 bash -lc 'apt-get update >/dev/null && apt-get install -y --no-install-recommends ca-certificates curl >/dev/null && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list && apt-get update >/dev/null && apt-cache madison tailscale'
docker compose build --build-arg TAILSCALE_VERSION=<完整包版本号>
docker compose up -d
```

不传 `TAILSCALE_VERSION` 时，每次重新构建都可能获得更新的 Tailscale 包；升级前建议先阅读 Tailscale release notes，并保留可回退的镜像或 Dockerfile 版本。

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

# 运行自动 smoke test（不会打印密码）
./scripts/smoke-test.sh
```

检查容器健康状态：

```bash
docker compose ps
docker inspect tailscale-socks5 --format '{{json .State.Health}}'
```

首次启动或重置 `state/` 后，容器在完成 Tailscale 授权前会显示 `unhealthy`，这是预期行为。先执行 `docker compose exec socks tailscale up --hostname=docker-socks5`，按终端输出的链接完成浏览器授权，再重新运行 `./scripts/smoke-test.sh`。

## 安全提醒

- tailscale 的 **1055 是无认证端口**，已绑定 `127.0.0.1`，compose 中**只暴露 1056**。切勿把 1055 映射到宿主机。
- 账密通过 `.env` 注入，`.env` 已加入 `.gitignore`，不会被提交。
- compose 默认把 1056 绑定到宿主机 `127.0.0.1`。如果确实要让其他机器访问，显式设置 `PROXY_BIND_ADDR=0.0.0.0` 后重启，并同时配置防火墙或安全组来源白名单。

### 限制客户端来源

`danted.conf` 当前保留了全来源规则，方便本机和受控内网使用：

```conf
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
}
```

如果把 `PROXY_BIND_ADDR` 改为 `0.0.0.0`，建议同步把 `from` 改成可信来源网段，例如只允许内网客户端：

```conf
client pass {
    from: 10.0.0.0/8 to: 0.0.0.0/0
}
```

`socks pass` 也可以按同样思路收窄 `from` 或 `to` 范围。不要只依赖弱密码保护公网代理。

## 运维手册

### 健康检查、日志和资源限制

`docker-compose.yaml` 内置了健康检查，容器内会先确认 `tailscale status` 和 `tailscale ip` 可用，再通过 Tailscale 的本地 SOCKS5 端口 `127.0.0.1:1055` 访问 `https://ifconfig.me`。这比只检查进程存在更接近真实代理路径，也能避免未登录状态被误判为 healthy。

Docker 日志默认限制为 3 个 10MB 文件，避免长期运行时占满磁盘。容器还设置了 `mem_limit: 256m` 和 `cpus: "1.0"` 作为基础资源护栏；如果你的 Compose 版本或运行环境不支持这些字段，请改用宿主机或容器平台的资源限制能力。

### Tailscale 状态目录

`./state` 会挂载到容器内 `/var/lib/tailscale`，里面保存 Tailscale 的机器身份。它不是普通缓存，泄露后应按凭据泄露处理。

- 备份 `./state` 时只保存到可信位置，并限制文件权限。
- 如果 `./state` 泄露，先到 Tailscale 管理后台移除对应机器，再重新登录生成新状态。
- 迁移服务时可以携带 `./state`，这样新宿主机通常不需要重新授权；只在可信机器之间迁移。

重置本地状态：

```bash
docker compose down
mv state "state.$(date +%Y%m%d%H%M%S).bak"
docker compose up -d
docker compose exec socks tailscale up --hostname=docker-socks5
```

确认新状态可用后，再删除旧的 `state.*.bak`。如果只是测试重登，也可以先移动目录而不是直接删除，便于回退。

### 密码轮换

1. 编辑 `.env`，更新 `PROXY_PASS`，必要时也更新 `PROXY_USER`。
2. 重建容器内系统用户密码：

```bash
docker compose up -d --force-recreate
```

3. 用新密码验证：

```bash
./scripts/smoke-test.sh
```

4. 如需确认旧密码失效，可临时用旧密码执行一次 `curl --socks5`，预期认证失败。

### 升级

```bash
docker compose build --no-cache
docker compose up -d
docker compose logs --tail=100
./scripts/smoke-test.sh
```

如果使用固定 Tailscale 版本，先修改或传入新的 `TAILSCALE_VERSION`，再执行以上步骤。

### 回滚

- 如果保留了旧镜像 tag，优先回滚到旧镜像。
- 如果是 Dockerfile 或 build arg 导致的问题，恢复上一版 Dockerfile 或 `TAILSCALE_VERSION` 后重新构建。
- 只有在确认机器身份也需要回滚、且备份可信时，才恢复旧的 `./state`。
- 回滚后执行 `docker compose up -d --force-recreate` 和 `./scripts/smoke-test.sh`。

### 故障排查

| 现象 | 检查项 | 处理 |
|------|--------|------|
| 容器 unhealthy | `docker compose ps`、`docker inspect tailscale-socks5 --format '{{json .State.Health}}'` | 查看 `docker compose logs --tail=100`，确认是否已完成 Tailscale 登录 |
| Tailscale 未登录或登录失效 | `docker compose exec socks tailscale status` | 重新执行 `docker compose exec socks tailscale up --hostname=docker-socks5` |
| Dante 认证失败 | `.env` 中的 `PROXY_USER` / `PROXY_PASS` | 确认不是 `XXX`，修改后 `docker compose up -d --force-recreate` |
| 代理测试卡住或出口不对 | `./scripts/smoke-test.sh`、`docker compose logs --tail=100` | 先确认容器健康，再检查 `danted.conf` 的 `route` 和 Tailscale 状态 |
| 需要重置身份 | `./state` | 按 “Tailscale 状态目录” 小节移动旧 state 并重新登录 |
| 日志增长过快 | `docker inspect tailscale-socks5 --format '{{json .HostConfig.LogConfig}}'` | 确认 Compose logging 配置生效，必要时降低日志级别或排查重启循环 |

### 本地检查和 CI 建议

基础检查：

```bash
bash -n entrypoint.sh
bash -n scripts/smoke-test.sh
docker compose config --quiet
```

可选 lint（未安装时跳过或在 CI 中安装）：

```bash
shellcheck entrypoint.sh scripts/smoke-test.sh
hadolint Dockerfile
```

未来接入 CI 时，建议至少运行：shell 语法检查、Compose 配置检查、ShellCheck、Hadolint，以及 smoke test 的 dry-run 部分。

### 发布检查清单

1. 构建镜像：`docker compose build`
2. 启动容器：`docker compose up -d`
3. 如果是新 `state`，完成 `tailscale up` 登录。
4. 检查健康状态：`docker compose ps`
5. 运行：`./scripts/smoke-test.sh`
6. 检查日志限制是否生效：`docker inspect tailscale-socks5 --format '{{json .HostConfig.LogConfig}}'`
7. 确认暴露范围符合预期：默认 `127.0.0.1:1056`，公网暴露必须显式配置 `PROXY_BIND_ADDR=0.0.0.0` 并配合来源限制。

## 已知风险点

dante 的上游 SOCKS5 转发（`danted.conf` 中的 `route` + `proxyprotocol: socks_v5`）写法符合官方文档，但未实测。若 curl 测试不通，多半需要微调 `external` / `route` 段，或退回到内核态 TUN 方案（在 compose 中加 `cap_add: [NET_ADMIN]` + 挂载 `/dev/net/tun`，并用 `tailscale up --exit-node`）。
