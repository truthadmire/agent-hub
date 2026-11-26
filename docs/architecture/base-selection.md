# macOS 桌面底座选型

**决定（2026-11-26）**　Agent Hub 使用 SwiftUI/AppKit、SwiftPM、系统 SQLite 和本机 Git 新建应用。工作区起始为空，首版只面向 macOS。看板、任务内双面板和验证状态需要围绕同一套任务记录设计。原生方案可以在一个 Swift 工程内实现这些界面、进程监督和持久化。代价是自行实现 CLI 协议、进程恢复和 Git 整合，并为它们编写回归测试。

## 核查版本和运行结果

在 Apple Silicon、macOS 26.6.2 上检查两个公开仓库的浅克隆。表中的源码提交来自本地 Git 对象，稳定标签来自 GitHub 的 `releases/latest` 重定向及远端 Git 标签。发布日期取自上游发布页。源码检查与稳定发行版分别固定，便于复查。

| 方案 | 检查版本与活动 | 本次本机运行 |
| --- | --- | --- |
| AionUi | [main，2026-11-05](https://github.com/iOfficeAI/AionUi/commit/e108b6b56b1a6eb99a00904878d0582f657b2908)。[v2.2.2，2026-09-09](https://github.com/iOfficeAI/AionUi/releases/tag/v2.2.2)，提交 `6744099b279b991c17e31c243f0920477bd31cb6`。 | Node 24.12.0 直接载入上游启动函数，用受控回调断言成功端口、错误捕获及失败退出码，均通过。完整 Electron 客户端、AionCore 和上游测试套件未运行。 |
| Paradev | [main，2026-11-26](https://github.com/ParadevAI/Paradev/commit/09ce262b1cfb23a8db79f097bc8a9a2e5c7a0407)。[desktop-v2.0.12，2026-11-25](https://github.com/ParadevAI/Paradev/releases/tag/desktop-v2.0.12)，提交 `f8ec8e2c02944913f3f85f357a4055c7b735ec58`。 | 临时 Git 仓库创建两个 worktree，第二个路径含空格并设置锁定理由。将真实 porcelain 输出交给上游解析器，核对两个分支、起始 SHA、锁定理由，均通过。完整 Electron 客户端、服务栈和上游测试套件未运行。 |
| Tauri 2 + React | 检查 Rust 核心包 [tauri-v2.12.7](https://github.com/tauri-apps/tauri/releases/tag/tauri-v2.12.7) 及 [Cargo 工作区](https://github.com/tauri-apps/tauri/blob/9319e539f34237035cb4693bed9246660bc0a926/Cargo.toml)。 | 检查工程配置和平台文档。当前命令环境能发现 Node，找不到 Rust/Cargo 和 Bun。未另建或编译 Tauri 应用。 |
| SwiftUI/AppKit | 本机 Xcode 27.0（27A266a）、Apple Swift 6.4、Apple Git 2.54.0、SQLite 3.51.0。 | 编译并执行 Swift 探针，成功构造双列 `HSplitView`，写 SQLite 后关闭、重开并读回整数 17，通过 `Foundation.Process` 以 argv 执行系统 Git，收到版本并回收子进程，退出码 0。这次探针未呈现窗口。 |

## AionUi

桌面包包含 React 渲染器、Electron 主进程及独立的本地 HTTP/WebSocket 后端 AionCore。后端使用 Rust、Axum、Tokio 和 SQLite，并承担 agent 会话、事件、团队调度与持久化。上游开发手册要求 Node、Bun，以及用于编译后端的 Cargo。已安装的发行包会带上后端，开发环境才需要从两个仓库构建。该架构适合同时服务桌面端和 WebUI。Agent Hub 若继承，需同时跟进客户端与引擎的接口、存储和迁移。[桌面架构](https://github.com/iOfficeAI/AionUi/blob/e108b6b56b1a6eb99a00904878d0582f657b2908/docs/architecture/overview.md) · [开发步骤](https://github.com/iOfficeAI/AionUi/blob/e108b6b56b1a6eb99a00904878d0582f657b2908/docs/contributing/development.md) · [引擎架构](https://github.com/iOfficeAI/AionCore/blob/503a87199eb978790ca77675b39c84b241535bf3/ARCHITECTURE.md)

引擎有子进程监督、直接 CLI/ACP 会话和权限确认接口。桌面端的源码管理面板以 WebSocket 与引擎通信，能查询变更并发送暂存、取消暂存及丢弃操作。v2.2.2 修复了新 worktree 的重新发现。所查路径未证实其具备 Agent Hub 要求的原项目脏基线、独立整合和按提交使验收失效的完整流程。认证方面，后端服务自身的登录和模型提供方登录分属不同层级，三家 CLI 的现有登录及 Keychain 存储都需要分别验证。[会话行为](https://github.com/iOfficeAI/AionUi/blob/e108b6b56b1a6eb99a00904878d0582f657b2908/docs/prds/conversations/acp/session.md) · [权限确认](https://github.com/iOfficeAI/AionUi/blob/e108b6b56b1a6eb99a00904878d0582f657b2908/docs/prds/conversations/acp/permissions.md) · [SCM 传输](https://github.com/iOfficeAI/AionUi/blob/e108b6b56b1a6eb99a00904878d0582f657b2908/packages/desktop/src/renderer/pages/conversation/SourceControl/scmTransport.ts)

上游有假 ACP CLI 和 E2E 用例。实际检查了后端启动失败处理。打包清单包含 Electron、原生 Node 模块和后端二进制，并启用 Hardened Runtime。其 CI 在 DMG 已生成而公证失败的特定分支仅发警告，Agent Hub 的正式发布需要把公证、票据和成品检查设为成功条件。[后端启动函数](https://github.com/iOfficeAI/AionUi/blob/e108b6b56b1a6eb99a00904878d0582f657b2908/packages/desktop/src/process/startup/backendStartup.ts) · [测试用 CLI](https://github.com/iOfficeAI/AionUi/tree/e108b6b56b1a6eb99a00904878d0582f657b2908/tests/fixtures/fake-acp-cli) · [打包配置](https://github.com/iOfficeAI/AionUi/blob/e108b6b56b1a6eb99a00904878d0582f657b2908/packages/desktop/electron-builder.yml) · [发布工作流](https://github.com/iOfficeAI/AionUi/blob/e108b6b56b1a6eb99a00904878d0582f657b2908/.github/workflows/_build-reusable.yml)

## Paradev

原名 Superset。项目方在 2026-10-26 宣布更名。本机对旧仓库发起 HTTPS HEAD 请求得到 HTTP 301，目标为 `https://github.com/ParadevAI/Paradev`，跟随后为 200。源码包名仍可见 `@superset/*`。[官方更名公告](https://paradev.com/blog/superset-is-now-paradev) · [旧仓库入口](https://github.com/superset-sh/superset)

Paradev 的并行工作区、独立 PTY 和按工作区查看 diff 最贴近要求。Codex 适配器有结构化审批、会话恢复及 turn 中断。worktree 创建会验证注册目录及 HEAD，能识别 Git 实际完成 checkout、但后置钩子报错的情况。业务代码依赖 host-service、Git 封装和工作区数据类型。其源码有终端重连、协作与差异视图的测试；近期发行修复了重连后漏报工作区事件、终端重复行丢失和焦点导致的窗口冻结。没有在本机重现这些历史问题。[Codex 适配器](https://github.com/ParadevAI/Paradev/blob/09ce262b1cfb23a8db79f097bc8a9a2e5c7a0407/packages/chat-runtime/src/harness/codex/codexAdapter/codexAdapter.ts) · [工作树创建](https://github.com/ParadevAI/Paradev/blob/09ce262b1cfb23a8db79f097bc8a9a2e5c7a0407/packages/host-service/src/trpc/router/workspace-creation/shared/add-branch-worktree.ts) · [实际运行的解析器](https://github.com/ParadevAI/Paradev/blob/09ce262b1cfb23a8db79f097bc8a9a2e5c7a0407/packages/host-service/src/trpc/router/workspace-creation/shared/worktree-list.ts) · [桌面终端](https://github.com/ParadevAI/Paradev/tree/09ce262b1cfb23a8db79f097bc8a9a2e5c7a0407/apps/desktop/src/main/terminal-host) · [修复记录](https://github.com/ParadevAI/Paradev/releases/tag/desktop-v2.0.12)

官方本地开发流程固定 Bun 1.4.3，Docker 运行 Postgres、neon-proxy、Redis，初始化开发账号。根开发命令启动 API、Web、桌面和 relay。产品的本地工作区文件保存在主机，relay 远程访问默认关闭；模型调用使用用户自己的订阅或 API key。完整 fork 需要裁剪账号、远程工作区、同步和多平台发布流程，另行验证三家的凭据处理、脏工作区和合并冲突。原有工作区面板可借鉴，卡片与子任务的关系、双会话归属和验证状态仍需改造。[开发服务清单](https://github.com/ParadevAI/Paradev/blob/09ce262b1cfb23a8db79f097bc8a9a2e5c7a0407/DEVELOPMENT.md) · [产品 FAQ](https://github.com/ParadevAI/Paradev/blob/09ce262b1cfb23a8db79f097bc8a9a2e5c7a0407/apps/docs/content/docs/faq.mdx) · [macOS 打包、签名与公证配置](https://github.com/ParadevAI/Paradev/blob/09ce262b1cfb23a8db79f097bc8a9a2e5c7a0407/apps/desktop/electron-builder.ts)

## 自建方案的取舍

| 评估项 | Tauri 2 + React + TypeScript | 选定的原生方案 |
| --- | --- | --- |
| 运行和开发 | 系统 WebView 渲染，无须云服务。React 工具链与 Rust 核心通过命令和事件交换数据。 | SwiftUI 直接订阅任务状态。SQLite 和系统框架可本地运行。调用在线供应商时才需该 CLI 的网络与账户。 |
| CLI 与认证 | Rust 核心可执行子进程、维护会话并访问钥匙串。每家协议及恢复逻辑仍由项目实现。 | 以绝对路径和分离 argv 启动本机 CLI。订阅登录由官方工具维护，需由应用保存的密钥采用 Security.framework。 |
| Git 与界面 | Rust 调用 Git、React 提供拖放与双面板。适合将来共享跨平台界面，需要维护 JS/Rust 间类型和事件语义。 | Git 子进程与状态机共享 Swift 数据模型。原生窗口、菜单、文件选择器及无障碍语义适合 macOS 单平台。 |
| 分发与维护 | 具备官方 DMG 与 Developer ID 签名流程。需维护 Cargo 和前端依赖锁及权限配置。 | SwiftPM 构建可执行程序，组装原生 app 后通过 Apple 工具签名、公证、装订与验证。需自行维护分发脚本，逐项实测安装、Finder 启动与 CLI 发现。 |

Tauri 的 Rust 核心包声明 `Apache-2.0 OR MIT`，该版本最低 Rust 1.90。两个自建方案均需自行实现 Git 基线、冲突处置、授权与取消；SwiftUI 的选择依据是单平台范围、当前可运行的工具链以及产品状态模型。此次没有测量四个方案的内存或启动性能。[Tauri 进程模型](https://v2.tauri.app/concept/process-model/) · [Tauri DMG](https://v2.tauri.app/distribute/dmg/) · [Tauri 签名](https://v2.tauri.app/distribute/sign/macos/) · [Apple 公证流程](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## 复用与许可证

AionUi 和独立的 AionCore 根许可证均为 Apache-2.0。Paradev 根许可证为 MIT，版权所有者为 Superset Inc.。在 Paradev 的子目录还查到 Microsoft 的 MIT 声明和 BSD-3-Clause 的查询字符串解析器。根许可证不能单独代表全部嵌套依赖或品牌资源。[AionUi 许可证](https://github.com/iOfficeAI/AionUi/blob/e108b6b56b1a6eb99a00904878d0582f657b2908/LICENSE) · [AionCore 许可证](https://github.com/iOfficeAI/AionCore/blob/503a87199eb978790ca77675b39c84b241535bf3/LICENSE) · [Paradev 许可证](https://github.com/ParadevAI/Paradev/blob/09ce262b1cfb23a8db79f097bc8a9a2e5c7a0407/LICENSE.md) · [终端链接解析器声明](https://github.com/ParadevAI/Paradev/blob/09ce262b1cfb23a8db79f097bc8a9a2e5c7a0407/apps/desktop/src/renderer/lib/terminal/links/url-link-provider/utils/url-parser/LICENSE) · [查询字符串解析器声明](https://github.com/ParadevAI/Paradev/blob/09ce262b1cfb23a8db79f097bc8a9a2e5c7a0407/packages/sdk/src/internal/qs/LICENSE.md)

采用系统 API、SQLite 和 Git；两个候选的行为与失败案例用作设计参考。进入项目的上游源码、图片、图标及打包脚本数量均为零。供应商 CLI 从官方渠道独立安装。实际组件记录见[第三方说明](../../THIRD_PARTY_NOTICES.md)。
