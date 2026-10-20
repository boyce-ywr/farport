# DOCKER_HOST 本机附件误拦截与真实 docker-claude 验收

- 发现日期：2026-10-20。
- 影响版本：0.1.13 预览构建 17；修复进入构建 18，不覆盖已发布的 0.1.12 正式包。
- 严重程度：中；合法的本机 Docker 连接不能发送附件，没有发生错误目标发送。
- 修复提交：与本文一同提交，使用 `git log -1 -- Sources/WorkbenchCore/DockerUnixEndpoint.swift` 定位。

## 现象

用户在本机 tmux 的 Docker Claude 中粘贴图片，Farport 提示“容器附件暂不支持 DOCKER_HOST，请使用本机 Unix socket 的 Docker context”。下方 Claude 的 API 429 报错属于独立模型调用链，附件在进入上传前已经被 Farport 拦住。

此前夹具只覆盖了 context 连接，未覆盖通过 `DOCKER_HOST` 指向本机 Unix socket 的等价使用方式。上一版把所有 `DOCKER_HOST` 一概拒绝，安全范围收得过窄；不是用户需要改配置的错误。

## 复现与根因

在独立 tmux 测试服务中启动真实 `docker exec -it`，只给 Docker 客户端设置 `DOCKER_HOST=unix:///…` 并去掉 `DOCKER_CONTEXT`，保持已有本机 daemon 与两个无网络的测试容器。运行：

```sh
SWB_QA_DOCKER_ENDPOINT_MODE=host bash scripts/check-docker-attachments.sh
```

修复前稳定返回与截图相同的拒绝消息。`DockerAttachmentDaemon.discover` 的 guard 在解析 endpoint 前就拒绝 DOCKER_HOST，未区分 Unix socket 与远程 TCP/SSH。

## 修复边界

1. 不手写可能因 Docker 版本不同而变化的环境优先级。保留前台 Docker 的明确 `--context/-c`、`--host/-H` 和必要环境变量，由同一 Docker CLI 的 `context show` / `context inspect` 读取其实际选择的 endpoint；这些是本地配置查询。
2. 解析后仅接受有绝对路径、无 authority/凭据、无 query/fragment/控制字符的 `unix:///…`。远程 `tcp://`、`ssh://`、畸形 URI 仍在接触 daemon 之前拒绝，不因允许 DOCKER_HOST 放开远程环境。
3. 确认后的 inspect/exec/上传/校验通过固定 `--host <已核实socket>` 调用；复核 daemon ID、容器完整 ID/启动状态与原 tmux 前台进程不变，不回退到当前默认 context。context 来源额外复核其原配置 endpoint 没有变化；直接 host 来源不受无关默认 context 文件修改影响。
4. `DockerTerminalCommand` 补齐 `-H`、`--host`、`--host=`、紧凑写法；host/context 同时指定、重复 host、缺少参数直接拒绝。原窗格、用户、目录、文件内容、暂停/重启和不自动回车的检查不变。
5. 选择框显示“Docker 连接”而不是把每个来源都标成 context，便于用户核对真实 socket。

官方依据：2026-10-20 实际获取 Docker CLI 官方源码 `https://raw.githubusercontent.com/docker/cli/master/cli/command/cli.go` 的 `resolveContextName`、`getServerHost`，以及 Docker 环境变量文档 `https://docs.docker.com/reference/cli/docker/`。本机 CLI 为 28.0.2；没有用文档概述代替实际 CLI 的优先级解析，也没有要求用户修改全局环境。

## 用户要求的真实验证

- 在本机构建机器上找到用户的 `docker-claude` 启动脚本，先只执行快速路径检查，确认已有容器、挂载及连接满足要求，不需要重建容器或调整网络。
- 创建仅含一张无敏感信息 PNG 的独立工作目录和唯一 tmux 会话，执行真实 `docker-claude`，使用新的 Claude session ID，不恢复或输入到已有工作会话。只对这个新建目录完成信任确认，没有传入用户提示、跳过权限参数或自动提交图片。
- 从 Farport 新建的测试实例附着这条 tmux 会话，执行真实 `⌘V`、原生容器确认按钮、内容与接收用户读回校验，然后定向插入容器内路径。
- Claude Code v2.1.296 的输入框实际出现 **`❯ [Image #1]`**。没有发送 Enter，所以只证明真实 Claude 输入端已经识别图片，不声称模型已读取或回复。容器 ID/启动时间前后相同，没有重启容器。
- 专用测试会话保留，测试上传和图片留在私有暂存位置，便于用户查看；不删除容器或用户会话。截图/文本保存在 `.test/docker-claude-live.*/`，不提交到仓库。

## 回归与产物

- 增加 URI 安全检查、host/context 参数冲突、`DOCKER_HOST` 与 `-H/--host` 真实连接回归；context 旧路径也需重跑。
- 中英文 UI 夹具增加 `SWB_QA_DOCKER_ENDPOINT_MODE=host`，真实前台 Docker 进程必须带此环境，不能只在测试主进程设置却误测默认 context。
- 核心断言、三连接路径、预览包启动及 SHA-256 结果以 `docs/releases/0.1.13-preview.md` 的构建 18 记录为准。过程日志在 `.test/continue-diagnostics/docker-host-*.log`、`docker-claude-live-ui.log`。
- 当前验证：2578 项 ARM64 Release 核心断言、947 条英文资源检查通过；context、DOCKER_HOST、--host 真实隔离容器路径全部通过，DOCKER_HOST 中英文前台开发版也通过。构建 18 新包尝试前台检查时构建机再次锁屏，停在窗口激活；保留失败记录，不作为已通过结果。
- 构建 18 新预览包经 LaunchServices 完成中英文非前台完整处理链，退出状态为 0；日志为 `docker-host-package-models.log`，不代替尚受锁屏影响的包内前台键盘检查。

## 避免再次返工

Docker 连接入口不能只测一种环境：context、DOCKER_HOST、本机 host 参数要通过相同真实前台进程链验证。产品测试和真实工具验收分开记录；只有通用输入接收器通过，不能声称真实 Claude 已识别图片。
