# 端到端验收

HubSmoke 与桌面应用共用 HubStore、HubEngine、provider 适配器、进程监督器及 Git worktree 服务。每次验收都新建临时 Git 仓库及独占的 SQLite 数据目录。引擎关闭后，验收程序会重新开库，检查任务状态、实际文件字节、整合差异、验证命令退出码，以及原仓库的 HEAD 和工作区状态。

[持久证据索引](../Examples/Evidence/2026-11-26.json) 记录每项抽检的时间、任务 ID、示例仓库的 Git 提交和补丁 SHA-256，保留了真实调用与模拟调用的区分。本轮使用 Apple Silicon、macOS 26.6.2（25G83）及 Swift 6.4，时间为 2026 年 11 月 26 日。验收时项目源码尚未创建首次提交，下表中的提交号都属于独立示例仓库。

## 正式 CLI 与订阅

| 验收 | 实际结果 |
|---|---|
| 双订阅并行协作 | 任务 `CCD0267C-388B-45DE-8661-378E6C8E5EFA` 产生三个成功会话。Codex 规划两个互不依赖的工作项，Codex 后端仅改 `backend.txt`，Antigravity 前端仅改 `frontend.txt`。新加坡时间 23:25:11，监督器核实两个工作进程同时存活。从较晚的进程启动到较早记录的 CLI 完成事件，相交窗口为 18.279 秒。两个独立检查在基线均返回 1，在同一整合提交 `4dc265e82cb6718ef80b6e61915f91c2580ac813` 均返回 0。重开数据库后，两个文件的内容、原仓库和任务状态均通过检查。 |
| Codex 0.170.0，ChatGPT 账号，直接执行 CLI | 以 `codex exec --ignore-user-config --ephemeral --sandbox workspace-write` 运行，移除 API key 环境变量，并限定官方 provider 与 ChatGPT 登录。CLI 返回 0，输出 7 条 JSONL，含命令完成和 `turn.completed`。独立读回确认受管 worktree 内容为 `verified\n`，原仓库仍为 `pending\n`，Git 状态干净。CLI 报告输入 52,552 token（其中缓存 39,680），输出 162 token。 |
| Antigravity 1.5.18，官方账号通道，最终权限配置 | 任务 `0CD0FA0E-ACA8-4AD5-B325-1054A55B5B7C` 实际使用 `accept-edits` 与限定到 worktree 的 `--settings`。单次请求成功并留下会话 ID。基线 `grep` 退出 1，提交 `2b2585581c92fc5642197ef65c87ab16392375ff` 仅改 `status.txt`，同一检查退出 0。CLI 报告输入 20,257、输出 2,361 token。首次验收程序与刚关闭的数据库写入者短暂争用锁，随后用独立进程 `--recheck-live` 重新打开原数据库，确认预期字节、diff、原仓库和完成状态，退出 0；此次复核消耗的模型调用为零。 |
| Antigravity 1.5.18，前一版适配器 | 在加入显式 `--settings` 之前，任务 `7390E701-5E47-4D1D-87A7-4604D7196039` 同样取得一个成功会话。提交 `e8c0cb624dea1d30caebb77c0dcfcd12492f7f2e` 仅改 `status.txt`，检查先返回 1、最终返回 0。重开数据库后仍为完成。CLI 报告输入 21,334、输出 2,790 token。 |
| DSH 0.2.0-rc.2，Agent Hub 钥匙串 | 正常主机权限下，应用专用 DeepSeek key 条目不存在，探测结果为 `signedOut`。跳过真实推理，模型请求次数为零。早先受限沙箱中的凭据状态为未知。 |

真实运行记录保存在机器上的临时目录中，macOS 可能回收这些文件。双订阅对应 `agent-hub-smoke-25B581BD-B6EF-443F-9116-99DBB74683E5`，最终权限版 Antigravity 对应 `agent-hub-smoke-71C923D2-E857-49F0-B6CF-36AD4F540F64`。直接 Codex 调用的原始 JSONL 位于 `agent-hub-live-codex.DH24NHMD`，其 SHA-256 为 `c3a4e76c022f4f7fd4013df4e23319bcb9882ed0dcb8391db85ba8c6344b3b68`。token 数来自各 CLI 的报告，本次没有观测到订阅余额或单次请求价格。[已安装应用的桌面验收](desktop-verification.md)

## 离线协作与故障注入

| 场景 | 实际结果 |
|---|---|
| `single` | 单个工作者进程写入文件。基线检查退出 1，最终检查退出 0。重开库仍有会话 ID，原仓库干净。 |
| `gallery` | Codex 规划替身生成依赖图。Codex 和 Antigravity 替身在屏障处互相等待，证明两个进程同时存活；随后各自在独立工作树写入 `catalog.py`、`page.py`。DSH 替身先检查自己的基线已包含两个改动，再添加 `tests/test_filter.py`。整合分支只含这三项差异。真实 Python 套件四项测试均通过。预览从本机 HTTP 服务实际取回 Coast 第 2 页唯一作品 Last Ferry（共三件），Portraits 分类实际呈现空状态。 |
| `repair` | 替身宣称任务完成，真实 grep 验证失败。进行一次修复后检查通过。数据库保留修复前后的证据。 |
| `stalled` | 一次修复后相同检查仍失败。任务转为需要用户处理，总共两次尝试。 |
| `auth`、`protocol` | 两个独立进程分别模拟认证失败和非法 JSON。引擎各派发一次后停止，保留 `authentication` 和 `protocolError` 分类。 |
| `pause` | 暂停前工作者已写入部分成果并生成子进程。引擎稳定停止后，替代工作者读到前一成果并完成其余工作。旧子进程已退出。 |
| `cancel` | 中断前的部分文件保存在尝试工作树中，整合分支仍为基线。重开后的状态仍为已取消，子进程已退出。 |
| `quota` | Codex 替身先保留部分成果，再连续两次报告限流。已允许的 Antigravity 替身需在新工作树读到旧成果，才能继续并通过验证。共三次尝试、一次切换。 |
| `restart` | 独立 Hub 进程在工作者修改文件并生成子进程之后以 `_exit(86)` 突然退出。新进程识别一次中断的尝试，等待显式恢复指令。替代工作者读到未提交的部分成果并完成修改，检查通过，旧子进程已退出。 |

真实 CLI 的原生会话续接及实际运行途中取消不在上述实测范围内。暂停、取消和崩溃恢复通过受控 CLI 与真实系统进程验证。Git 合并冲突、PID 重用及预览隔离有独立测试。[验证报告](verification.md)

## 复现

从源码目录执行。环境需要 Git、Swift 工具链及 Python 3。命令结束时打印本轮数据目录与 `result.json`，同级保留 `integrated.patch`。验证器调用 macOS Seatbelt，预览使用任务专属回环端口。已存在的限制性沙箱可能阻止继续创建系统沙箱或启动监听，此时会记录验证阻塞。

```sh
scripts/smoke.sh --fixture gallery
scripts/smoke.sh --fixture repair
scripts/smoke.sh --fixture restart
swift test --filter WorkflowIsolationTests
```

离线场景使用临时目录内的确定性 CLI 替身，经过真实生产协议解析器。假 DSH 在内存中取得测试占位值。摄影示例的原始站点、API 契约及三位工作者的样例改动位于 [Examples/Gallery](../Examples/Gallery/)。在结果工作树中运行 `python3 -B server.py --port 8765` 可打开示例预览。

以下命令会使用已配置的真实模型账号。单家验收设为最多一次模型尝试。双订阅验收要求 Codex 与 Antigravity 官方账号同时就绪，允许一次规划和两次独立实现，关闭 DSH、自动付费回退、重试与修复。

```sh
scripts/smoke.sh --live codex
scripts/smoke.sh --live antigravity
scripts/smoke.sh --live dsh
scripts/smoke.sh --live-team
```

对既有真实运行执行无模型调用的复核，可使用 `scripts/smoke.sh --recheck-live <先前的临时运行目录>`。
