# DSH iOS App

原生 SwiftUI iPhone Agent 客户端，直接连接远程 DSH 或 Hermes 服务器。不使用 WebUI 或 WKWebView，所有界面由 iOS 原生组件绘制。

## 功能

- 多服务器管理（添加、编辑、删除、切换）
- DSH 会话按工作区分组；Hermes 会话按渠道 → 工作区 → 会话分组
- 实时流式回复、Markdown 渲染、思考过程展示、工具运行状态
- 危险操作审批（拒绝、允许一次、本会话允许、始终允许）
- 左缘右滑打开会话抽屉，抽屉内可新建会话
- HTTPS 强制校验，密码仅存 Keychain
- Hermes OAuth/PKCE 登录、Bearer token 自动续期

## 要求

- macOS + Xcode 16+
- iOS 17+
- [xcodegen](https://github.com/yonaskolb/XcodeGen)（修改项目定义时需要）

## 构建运行

```sh
cd dsh-ios-app
open DSHIOSApp.xcodeproj
```

在 Xcode Signing & Capabilities 中选择自己的 Team，连接 iPhone 运行。

修改 `project.yml` 后重新生成工程：

```sh
brew install xcodegen && make project
```

## 项目结构

```
DSHIOSApp/
├── App/            # AppShellView、抽屉、服务器设置
├── Views/          # ChatSessionView、DSHUIView、MarkdownText
├── Services/       # API 客户端、Keychain、网关
├── Models/         # 数据模型
└── Support/        # 扩展工具
```

## 服务器部署

参见 [deploy/README.md](deploy/README.md)。
