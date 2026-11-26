# macOS 构建与发行

Agent Hub 0.1.0 的目标是 Apple Silicon 和 macOS 14.0 及以上。版本号、构建号、图标与 bundle ID 来自 `Packaging/Info.plist`。应用只有两个 Mach-O 可执行文件，分别是 `Contents/MacOS/AgentHub` 与 `Contents/Helpers/HubProcessGuard`。本版使用系统 Swift 运行库、系统框架和 SQLite，外部 AI CLI 由用户单独安装。

## 开发版与安装包

在 Apple Silicon Mac 的 Xcode 开发工具环境运行以下命令。下载的源码中已经包含原创 `.icns`。

```sh
./script/build_and_run.sh --verify
swift test
./scripts/smoke.sh --fixture gallery
./scripts/release.sh local
```

开发启动脚本把 App 放入 `dist/development/Agent Hub.app`。本地 DMG 位于 `dist/local/0.1.0/AgentHub-0.1.0-arm64-local.dmg`，其中应用使用 ad hoc 签名。本地构建可以通过 `AGENT_HUB_REPOSITORY_URL=https://github.com/OWNER/REPO` 指向实际官方仓库；发布工作流根据当前仓库自动填入该地址。SwiftPM 工程没有外部包依赖。若要重绘图标，可运行 `./scripts/build-icon.sh`。

## 签名与公证

在 Keychain 中安装具备私钥的 Developer ID Application 证书。运行 `security find-identity -v -p codesigning`，用该证书指纹设置 `DEVELOPER_ID_IDENTITY`，用证书所属团队设置 `APPLE_TEAM_ID`。本机签名直接调用 Keychain。Apple 的安全时间戳服务需要联网。

| 命令 | 用途 | 输出位置 |
| --- | --- | --- |
| `./scripts/release.sh signed` | Developer ID 签名、验证并挂载 DMG，等待公证 | `dist/signed/0.1.0/` |
| `./scripts/release.sh release` | 签名、公证、附加票据、Gatekeeper 验证与校验和 | `dist/release/0.1.0/` |

本机公证使用 `xcrun notarytool store-credentials "AgentHub"` 交互创建 Keychain profile，并设置 `NOTARY_PROFILE=AgentHub`。如已有经确认的分发 profile，使用其实际名称。CI 可使用 `NOTARY_KEY_PATH`、`NOTARY_KEY_ID` 与团队密钥对应的 `NOTARY_ISSUER`。个人 API 密钥按 Apple 的要求省略 issuer。

分发脚本先对 helper 签名，再对 App 签名，两者启用 Hardened Runtime 与安全时间戳，无特殊 entitlements。签名后校验证书类型、团队、可执行架构、最低系统版本和动态库路径。正式发行先把 App 的 ZIP 提交 Apple，取得票据后把已附票 App 放进只读 DMG，再对有安全时间戳的 DMG 执行第二次公证与附票。仅在两份日志均为 Accepted 且没有未审查问题、两份票据和 Gatekeeper 校验通过后，脚本才生成最终产物目录。[Apple 公证指南](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) · [Apple 自定义公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

失败时保留同级 `.in-progress` 目录，包括已取得的 submission ID 和 Apple 日志；对同一组输入运行原命令并附加 `--resume`。Apple 日志中有问题时，先审阅、修复，再指定新的输出目录构建。成功的输出目录保留历史产物。需要再打包同一版本时用 `AGENT_HUB_OUTPUT_DIR` 指定新的目录。

## GitHub Actions

普通 PR 使用只读 token，在无签名和模型凭据的 macOS runner 上运行 Swift 测试、模拟工作流、双产品构建和 DMG 的挂载与安装副本校验。正式工作流仅由受保护的版本标签触发。维护者设置保护 `v*` 标签的 ruleset、同名环境 `macos-release` 的发布审批，以及受保护的默认分支；仅授权的维护者可创建此类标签。工作流检查标签所指提交属于默认分支，且 `vX.Y.Z` 与 Info.plist 一致。[GitHub 托管 runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)

配置 `macos-release` 环境中的变量 `APPLE_TEAM_ID`、`DEVELOPER_ID_IDENTITY`，以及 secrets `CERTIFICATE_P12_BASE64`、`CERTIFICATE_PASSWORD`、`NOTARY_KEY_BASE64`、`NOTARY_KEY_ID` 和适用时的 `NOTARY_ISSUER`。签名作业在临时 Keychain 中导入证书，退出时删除临时凭据。上传到 GitHub Release 的作业只有创建版本所需的仓库写权限，接收 DMG、SHA-256、版本说明、构建信息及去敏后的公证日志。项目仓库地址和授权确定后，由维护者推送受保护标签触发正式发布。

## 验证下载与升级

在已下载的资产目录执行 `shasum -a 256 -c SHA256SUMS.txt`。正式包还可在源码仓库执行下面的独立复验命令。App 的证书链、helper、票据、Gatekeeper、DMG 的只读挂载、Applications 拖拽链接和复制后的应用均参与校验。

```sh
./scripts/verify-release.sh release '/path/to/AgentHub-0.1.0-arm64.dmg'
```

首次安装测试应从真实 Release 下载最终 DMG，在干净的 Apple Silicon 用户环境中通过 Finder 挂载、拖入 Applications 并启动，分别记录 CLI 缺失、CLI 已安装和实际任务的结果。保留 Gatekeeper 和下载隔离属性。脚本在临时目录复制安装包的检查与这些测试分别记录。升级时退出旧版本，再替换 Applications 内的 App；用户数据位于独立的 Application Support 目录。正式版本在设置页从已配置仓库查询新版本，由用户手动下载更新。
