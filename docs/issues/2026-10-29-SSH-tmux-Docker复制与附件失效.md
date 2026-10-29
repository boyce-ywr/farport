# SSH + tmux + Docker 下复制失效、截图粘贴不进容器、Shift 拖选自动取消

- 影响范围：Farport 0.1.18 及之前；远端 tmux 中运行 Claude Code（尤其是 docker-claude 容器内）的复制，远端 tmux 中 docker 窗格的附件/截图粘贴，所有持续输出窗格的 Shift 拖选
- 发现日期：2026-10-29（用户在 SSH → mac-mini → tmux → docker-claude 中反馈）
- 修复 commit：`a432a94`（发布于 0.1.19）
- 严重程度：高（核心复制/粘贴路径在用户主要工作场景完全不可用）

## 现象

1. 在 Claude Code 中拖选文本后按 ⌘C，提示“tmux 当前没有可读取的选区”，Mac 剪贴板没有内容。
2. 在远端 tmux 的 docker-claude 窗格粘贴截图，横幅提示“窗格可能处于嵌套主机、容器或其他用户环境”，附件不发送。
3. 按住 Shift 拖选时，窗格只要有新输出，选区就自动取消。

## 定位过程

1. 从 Claude Code 2.1.296 二进制中提取 `setClipboard` 源码：
   - 有 `TMUX` 环境变量时，执行 `tmux load-buffer -w -`，并输出原始 OSC52 和 DCS 包装的 OSC52；
   - 在 docker 容器内（`TERM=tmux-256color`，但**没有 `TMUX`**）只输出原始 OSC52。
2. Farport 的 ⌘C 只读取 tmux **复制模式**的选区（`selection_present`）。全屏模式的 Claude Code 自己处理鼠标选区，tmux 不在复制模式，所以永远读不到。
3. 端到端实测（独立 tmux socket，窗格内运行 `docker exec -it docker-claude claude`，用 `send-keys` 发送真实的 SGR 鼠标拖选）：
   - `set-clipboard external`（tmux 默认）：Claude 提示 “sent 13 chars via OSC 52”，但 tmux **没有生成任何 buffer**，内容丢失；
   - `set-clipboard on`：tmux 生成 `buffer0`（13 字节），同时把 OSC52 转发给外层终端。
4. 附件：`TerminalAttachments.prepare` 只在 `host == nil`（本机 tmux）时进入 Docker 流程；远端窗格前台是 `docker` 时，`TmuxService.target` 直接抛出“嵌套环境”错误。
5. Shift 拖选：`dataReceived` 处理新输出时，SwiftTerm 在鼠标上报开启的状态下会清除本地选区。

## 根因

- 复制：只支持 tmux 复制模式选区，不支持“程序自管选区 → 写入 tmux buffer”；容器内程序的 OSC52 又被 tmux 默认的 `set-clipboard external` 丢弃。
- 附件：远端 tmux + docker 没有实现识别和上传流程。
- Shift：持续输出与本地选区的鼠标上报状态冲突。

## 修复

- `TmuxService.copySelection(session:newBuffersSince:)`：先读复制模式选区；没有时，只接受**本次按下鼠标之后**新出现的 tmux buffer（按下时记录 buffer 名单，不依赖两台机器的时钟，也不会误取旧 buffer）。
- `clipboardRelay`/`acceptProgramClipboard`：⌘C 读不到内容、窗格前台是 docker/ssh 等，且 `set-clipboard` 不是 `on` 时，弹窗请用户确认，只对当前运行的 tmux 服务执行 `set-option -s set-clipboard on`，不改配置文件。
- 远端 Docker 附件：
  - `remoteDockerTerminal`：一次 SSH 内前后两次核对 tmux 窗格，并用 Linux `/proc` 或 macOS `ps` 读取前台 docker 进程参数；
  - `DockerAttachmentDaemon` 增加经 SSH 执行的模式，复用原有的上传和哈希校验；容器状态校验与 exec 在同一个远端 shell 内原子完成；
  - 粘贴时，在原有的原子条件中加入“前台 docker 进程 PID 与启动时间未变”。
- 能识别出原窗格容器时直接绑定，不再弹出选择框（本机流程同样适用）；参数无法解析但只有一个运行中容器时，使用该容器。
- `confirm` 合并 inspect 和 exec，远端去掉重复的 `docker info` 调用。远端截图从“摄取到插入”第 1/2 轮耗时由 17.4/10.8 秒降到 4.2/3.3 秒，本机由 7.6/3.6 秒降到 6.0/3.3 秒。
- Shift 拖选：存在本地选区或正在 Shift 拖选时，处理输出期间临时关闭鼠标上报。

## 验证

- 新增回归（本机与隔离 SSH 均覆盖，中英文）：程序 load-buffer 复制、点击前的旧 buffer 不被误取、OSC52 在 external/on 下的行为、docker 窗格的拦截识别与开启。
- `SWB_QA_DOCKER_SSH=1` 经回环 SSH 模拟“远端 macOS + tmux + docker exec”：真实 ⌘V 粘贴图片，自动识别容器，非 root 用户读回内容一致，只插入一次且不自动回车。
- 全量：workbench-tests、workbench-check、check-attachments、terminal-clipboard、check-tmux-copy --ssh、check-docker-attachments --ui/--models、check-preferred-tmux 全部通过。
- 已知偶发：`checkDragSnapshots` 在构建完成后紧接着运行时，出现过一次 12 秒等待超时（原有用例，非本次新增），重跑两次均通过。

## 未覆盖与限制

- 没有在用户的 mac-mini 上实测（本机没有该主机配置），用本机回环 SSH 加真实 docker-claude 代替。
- macOS 远端用 `ps -o args` 按空格切分参数，容器名或 `-w` 路径含空格时可能识别失败；失败时只在唯一运行中容器的情况下回退，否则明确报错。
- `set-clipboard on` 在 tmux 服务重启后失效，需要再次确认，或由用户写入 tmux 配置。

## 避免再犯

- 终端程序的复制有三条通道（tmux 复制模式、程序写 tmux buffer、OSC52 穿透），每条都要用真实程序做端到端测试，不能只测 tmux 自己的选区。
- 远端和容器链路必须有对应的回环测试，本机测试通过不能代表远端可用。
