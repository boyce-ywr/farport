# Zellij 与 herdr 会话支持：决策与实测事实

日期：2026-11-11。目标：在 tmux 之外支持 Zellij 和 herdr，能力对齐 tmux。

## 决策（与用户逐项确认）

1. **范围**：对齐 tmux，分两版交付。
   - 0.1.24：会话层（列出/新建/进入/重命名/结束、连接时自动进入）、复制、环境变量隔离、版本检测、界面命名。
   - 0.1.25：容器窗格（附件粘贴、路径点击）与 herdr Agent 会话启动/恢复。
2. **组织方式**：统一的“会话”页，自动检测主机已安装的工具并按 tmux / Zellij / herdr 分组列出。主机设置 `prefersTmux: Bool` 扩展为“连接时进入：无 / tmux / Zellij / herdr”，旧值 `true` 视为 tmux；保存时同步写 `prefersTmux`，旧版 Farport 读取不受影响。
3. **映射**：列表行 = 会话（进入单位）。详情：tmux 为窗口/窗格；Zellij 为标签/窗格；herdr 为工作区/标签/窗格，额外显示 Agent 与状态（只展示，不与 Agent 会话目录打通）。
4. **已退出会话**（Zellij `EXITED`、herdr `stopped`）：单独分组，只提供“删除”，不提供“恢复”。Zellij 恢复会重放命令，不视为恢复（见 `2026-10-20-terminal-session-competitors.md`）。
5. **能力缺口**：工具不支持的操作按钮置灰并说明原因，不模拟（herdr 没有会话重命名）。能后台创建的先后台创建再进入。结束会话一次完成 kill/stop + delete，确认框写明会结束所有进程。
6. **复制**：Zellij/herdr 不复刻 tmux 读 buffer 的路径；依赖工具自身的选区复制经 OSC 52 进入 Farport 已有剪贴板权限流程。标签设为远端选区上下文、关闭语义命令复制；右键菜单转发只用于 tmux。
7. **容器窗格（0.1.25）**：必须覆盖主场景。herdr 用 `pane process-info` 的 argv 识别 `docker exec`；Zellij 用 `list-panes --json` 的 `pane_command`，不足时询问目标，不一刀切拒绝。
8. **适用范围**：本机与远端 POSIX SSH 主机；Windows SSH 不支持。远端执行补 Homebrew 等常见路径。启动本机终端时清除 `TMUX*`、`ZELLIJ*`、`HERDR_*` 环境变量，避免误判嵌套。
9. **版本**：低于下限显示“版本过低”并禁用操作。下限：Zellij 0.44（`list-panes --json` 等依赖较新 CLI，实测基于 0.45.1），herdr 0.9（实测 0.9.5）。JSON 宽松解析，忽略未知字段。
10. **测试**：herdr 只使用 `farport-test-*` 具名会话，不触碰用户 `default` 会话。
11. **许可证**：Haven（AGPL-3.0）仅作行为参考，不复制代码。

## 实测事实（macOS，Zellij 0.45.1，herdr 0.9.5）

### Zellij

| 操作 | 命令 | 结果 |
| --- | --- | --- |
| 列出 | `zellij ls -n` | 每行 `名 [Created 2s ago] `，退出的带 `(EXITED - attach to resurrect)`，当前会话带 `(current)`；无会话时 stdout 为 `No active zellij sessions found.`，退出码 1 |
| 后台新建 | `zellij attach -b 名` | 退出码 0，会话立即出现在列表 |
| 进入 | `zellij attach 名` | 交互附着 |
| 重命名 | `zellij --session 旧 action rename-session 新` | 退出码 0，仅对运行中会话 |
| 结束 | `zellij kill-session 名` 后 `zellij delete-session 名` | kill 后可能留下 EXITED 记录；delete 运行中会话会失败；不存在时退出码非 0 |
| 窗格 | `zellij --session 名 action list-panes --json` | 数组；终端窗格含 `id`、`is_plugin=false`、`is_focused`、`exited`、`tab_id`、`tab_name`、`pane_command`、`pane_cwd`；插件窗格 `is_plugin=true` 需过滤 |
| 标签 | `action list-tabs --json` | 含 `tab_id`、`name`、`active` |

### herdr

| 操作 | 命令 | 结果 |
| --- | --- | --- |
| 列出 | `herdr session list --json` | `{"sessions":[{"name","default","running","session_dir","socket_path"}]}` |
| 后台新建 | `herdr --session 名 server`（常驻进程） | 会话 running，无工作区；`workspace create --cwd` 可建首个工作区 |
| 进入 | `herdr session attach 名` | 交互附着；对 stopped 会话会重新启动 |
| 重命名 | 无 | 只有 workspace rename |
| 结束 | `herdr session stop 名 --json` 后 `herdr session delete 名 --json` | stop 返回 `stopped:true`，delete 返回 `deleted:true`；对不存在的名字 delete 也返回 `deleted:true` |
| 窗格 | `herdr --session 名 pane list` | `result.panes[]`：`pane_id`、`workspace_id`、`tab_id`、`cwd`、`foreground_cwd`、`focused`、`agent`、`agent_status`、`terminal_title` |
| 工作区 | `herdr --session 名 workspace list` | `result.workspaces[]`：`workspace_id`、`label`、`tab_count`、`pane_count`、`agent_status` |
| 进程 | `herdr --session 名 pane process-info --pane w1:p1` | `shell_pid`、`foreground_processes[]`（`pid`、`argv`、`cwd`、`name`）；argv 可能含敏感参数，不得写日志 |
| 服务未运行 | 任意 API | stdout 输出 `{"error":{"code":"server_not_running",...}}` |

## 实现后的实测补充（2026-11-11）

- **Zellij 会话名长度**：macOS 的 `$TMPDIR` 较长，`zellij-<uid>/<版本>/<会话名>` 的 IPC socket 路径上限为 103 字节，会话名约超过 24 个字符即报 `the IPC socket path is too long`。Farport 不另设上限，直接展示 Zellij 的报错。
- **Zellij 附着提示**：客户端附着时会弹出 “About Zellij” 提示层（非浮动窗格，`hide-floating-panes` 无效），ESC 关闭；此时键入会进入提示层。
- **复制链路已实测**：Zellij 0.45.1 拖选后输出 `ESC]52;c;<base64>ESC\`（位于同步输出 `?2026` 块内），Farport 的 SwiftTerm 正常解析并按剪贴板权限写入 Mac 剪贴板；herdr 0.9.5 同样通过。Zellij 选区终点不含释放所在列。
- **远端可执行文件发现**：回环 SSH 的非登录 exec PATH 不含 `/opt/homebrew/bin`，追加常见目录后 Zellij/herdr 均可被发现。
- **herdr 新建**：没有窗口尺寸的伪终端里 herdr 拒绝附着（`terminal reported a zero-sized grid`），因此只能在真实终端标签中由 `herdr --session` 创建；Farport 终端内实测创建成功。

## 验证

- `.build/debug/workbench-tests`：2966 项核心断言通过（含 Zellij/herdr 离线断言）。
- `.build/debug/workbench-tests --multiplexer-live`：本机 Zellij 0.45.1、herdr 0.9.5 服务层实测通过。
- `scripts/check-multiplexers.sh --loopback`：中英文 × 本机/回环 SSH，会话页检测、附着（`list-clients` 确认）、关闭只分离、herdr 终端内新建、连接时进入 Zellij、结束删除全部通过。
- `SWB_QA_COPY=1` 的复制实测：Zellij、herdr 拖选经 OSC 52 写入 Mac 剪贴板通过（需要 App 在前台）。
- `preferred-tmux` 的模型部分（本机隔离 tmux）与 `terminal-preferences` 回归通过；依赖 Docker SSH 夹具的部分本次未运行（本机缺少 `ssh-workbench-test:local` 镜像）。
- 未验证：Linux 远端主机上的 Zellij/herdr、Zellij 0.44 实机、附件粘贴在 Zellij/herdr 窗格中的行为。
