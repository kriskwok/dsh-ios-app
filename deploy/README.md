# 远程 Agent 部署

本目录同时包含 DSH 和 Hermes 模板。两者使用不同的服务和上游端口，互不替换。

## Hermes：不影响现有 gateway 的独立后端

Hermes 官方提供 `hermes serve` 作为 Desktop/远程客户端使用的无头 JSON-RPC/WebSocket 后端。它可以与现有 `hermes gateway` 并行运行；不要停止、改名或复用 gateway 的 systemd 单元。

`hermes-ios.service.example` 使用同一个 Hermes 系统用户和 `HERMES_HOME`，只新增一个 `hermes serve` 进程。内部端口示例为 `9120`，必须在主机防火墙中禁止公网直连。Caddy 或 Nginx 才是唯一公网入口，WebSocket 会自动透传。

当前 iOS 客户端已实现 Hermes 官方 `native_pkce`：系统浏览器登录、临时 loopback 回调、Bearer token 自动续期、Keychain 存储和单次 WebSocket ticket。旧版 Basic Auth 只作为局域网兼容路径保留。直接开放互联网必须采用 OAuth/OIDC：

- 先运行 `hermes auth add nous` 登录 Nous Portal。
- 再运行 `hermes dashboard register --redirect-uri https://域名/auth/callback`。
- 将生成的 `HERMES_DASHBOARD_OAUTH_CLIENT_ID` 放进新服务专用环境文件。
- 公网代理必须禁止 `/auth/password-login`，避免共享配置中的旧 Basic provider 暴露到互联网。

安装时先核对 Hermes 可执行文件、运行用户、`HERMES_HOME` 和空闲端口，再复制模板。认证环境变量只放到新服务专用的 `/etc/hermes/ios-remote.env`，不要写入现有 gateway 的 service 文件。

## DSH

DSH 当前没有远程身份认证层，而且其 WebUI 可以执行命令和修改服务器文件。请让 DSH 只监听 `127.0.0.1:3080`，再由带 HTTPS 和认证的 Caddy 对外提供服务。

## 1. 运行 DSH

`dsh.service.example` 是 systemd 模板，并固定到本工程已验证的 `0.1.0-rc.6`，避免一次服务重启意外换到不兼容版本。先按服务器实际情况确认版本、`npx` 路径、`User`、`WorkingDirectory` 和 `DSH_HOME`，再安装并启动：

```sh
sudo cp dsh.service.example /etc/systemd/system/dsh.service
sudo systemctl daemon-reload
sudo systemctl enable --now dsh.service
curl --fail --silent --show-error http://127.0.0.1:3080/ >/dev/null
```

不要把 3080 端口放进公网防火墙。

## 2. 配置 Caddy

先生成 Basic Auth 密码哈希；不要把明文密码写进 Caddyfile：

```sh
caddy hash-password
```

将 `Caddyfile.example` 放入 Caddy 配置，并通过 Caddy 的环境变量提供：

```text
DSH_DOMAIN=dsh.example.com
DSH_USER=your-user
DSH_PASSWORD_HASH=<caddy hash-password 的输出>
# 可选，默认值为 127.0.0.1:3080
DSH_UPSTREAM=127.0.0.1:3080
```

Caddy 会自动申请并续期公网 TLS 证书。配置中的 `Host`/`Origin` 重写是有意的：DSH 的敏感设置接口只接受 loopback authority；Caddy 先完成 HTTPS 和密码认证，然后才把已认证请求送给 loopback DSH。删除认证却保留重写会形成高危远程代码执行入口。

## 3. 验证

```sh
curl --fail --silent --show-error --user 'your-user:your-password' https://dsh.example.com/ | head
```

在 iPhone App 中填写同一 HTTPS 地址、用户名和密码。首次加载、普通 RPC 以及 `/api/events.mux`、`/api/events.host` 两条 WebSocket 流都必须经过同一代理。
