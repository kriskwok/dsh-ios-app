# dsh-ios-app

`dsh-ios-app` 是一个完全原生的 SwiftUI iPhone Agent 客户端。它不加载 WebUI，也不使用 `WKWebView`；会话列表、聊天界面和输入区均由 iOS 原生组件绘制，可直接连接远程 DSH 或 Hermes。

## 当前阶段

本阶段实现最基本、可用的原生会话闭环，交互参考 ChatGPT、DeepSeek 等移动聊天产品。DSH 与 Hermes 的协议仍可能变化，因此客户端明确固定对照下方所列官方提交。

## 功能

- 默认进入新会话窗口，发送第一条消息时才在服务器上创建会话
- 左上角按钮或屏幕左缘右滑打开会话抽屉
- DSH 会话按工作区分组；Hermes 会话按“渠道 → Project → 会话”分组，支持 iPhone、Desktop、CLI、TUI、微信、飞书及未来新增渠道
- 会话按更新时间倒序；渠道和工作区也按各自最新会话的更新时间倒序
- 抽屉底部提供居中的“聊天”和服务器设置悬浮按钮；点击服务器即可切换到该服务器的会话
- DSH 工作区标题行可直接新建或折叠会话；未指定工作区的新会话默认进入 `DSH-Workspace`
- DSH 与 Hermes 分别使用官方鲸鱼标志和 Hermes Desktop 女孩头像
- 多服务器添加、编辑和删除
- HTTPS 校验；仅 `.local`、localhost 或不含点号的局域网主机名可使用 HTTP
- DSH 支持 HTTP Basic/Digest challenge，密码只存 Keychain
- 拉取会话历史，展示用户消息、助手 Markdown、思考过程和工具运行状态
- 通过 `events.mux` 与 `events.host` 实时接收流式回复和运行状态
- 发送追问、停止当前生成
- DSH 与 Hermes 的危险操作审批：展示原因与命令，按服务端能力支持拒绝、允许一次、本会话允许或始终允许
- 连接失败、鉴权失败和协议错误提示；不绕过 TLS 证书验证
- Hermes 使用官方 `native_pkce` 系统登录、Bearer token 自动续期、Keychain 存储和单次 WebSocket ticket
- Hermes 使用官方 `/api/ws` JSON-RPC、`projects.tree`、`session.resume/create`、`prompt.submit`，不在客户端重造 Agent 协议

尚未实现：问题表单、附件和图片、语音输入、会话搜索/重命名/删除、模型切换、工作区管理（创建、重命名、删除）和终端。这些属于后续原生化范围，不会回退为网页壳。

## 生成并运行

要求：macOS、完整 Xcode 16 或更新版本、iOS 17 或更新版本。仓库已经包含生成好的 Xcode 工程，可直接打开：

```sh
cd dsh-ios-app
open DSHIOSApp.xcodeproj
```

在 Xcode 的 Signing & Capabilities 中选择自己的 Team，然后连接 iPhone 运行。Bundle Identifier 可在 `project.yml` 中修改；修改项目定义后运行 `brew install xcodegen && make project` 重新生成。测试覆盖服务器 URL、安全规则、工作区解析、服务器选择持久化、抽屉按钮和左缘滑动手势。

无需启动模拟器的静态验证可运行 `make verify`；安装完整 Xcode 后可运行 `make ios-build` 做 iOS Simulator 编译。

## 服务器端

请使用 [deploy/README.md](deploy/README.md) 中对应的独立部署方案。Hermes 端新增 `hermes serve`，不替换、不重启现有 `hermes gateway`；公网入口统一由 HTTPS 反向代理提供。

## 已核验的官方依据

本工程在 2026-08-15 对照 `deepseek-ai/deepseek-harness` 的 `47f943859bef60e4160492346772ded9b24f765a`：

- [官方仓库和运行说明](https://github.com/deepseek-ai/deepseek-harness)
- [官方第一个插件教程](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/develop/basic/index.md)
- [官方架构说明](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/architecture.md)
- [客户端连接与远程安全限制](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/client/connection/README.md)
- [GUI 分层与 RPC 协议](https://github.com/deepseek-ai/deepseek-harness/blob/master/.agents/notes/implemented/architecture/2026-07-19-gui-layering-and-rpc-protocol.md)

Hermes 支持对照 `NousResearch/hermes-agent` 的 `f0c222c73dff282784dcf2cd91a14a32035a2ccd`，复用其官方 Desktop/Web 客户端协议：

- [Hermes Agent 官方仓库](https://github.com/NousResearch/hermes-agent)
- [程序化集成说明](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/developer-guide/programmatic-integration.md)
- [CLI 的 `hermes serve` 说明](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/reference/cli-commands.md#hermes-serve)

## 安全边界

DSH 和 Hermes 都是远程代码执行控制面。不要裸露内部端口、不要关闭 TLS 验证、不要在不受信任网络上使用明文 HTTP。Hermes 的内置用户名/密码仅作为可信局域网或 VPN 的旧版兼容路径；直接公网必须使用其 OAuth/OIDC，并在反向代理层禁止 `/auth/password-login`。
