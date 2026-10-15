# 开发与构建

日常使用直接下载 [Release 安装包](https://github.com/boyce-ywr/farport/releases/latest)，不需要安装 Swift、Xcode、Docker 或 GitHub CLI。

## 本地构建

需要 macOS、Swift 6 工具链及 Xcode Command Line Tools。项目使用 Swift Package Manager，部署目标为 macOS 14。

```bash
git clone https://github.com/boyce-ywr/farport.git
cd farport
bash scripts/package.sh --debug
open dist/Farport.app
```

完整发行构建：

```bash
bash scripts/package.sh
```

输出 `dist/Farport-<版本>-arm64.dmg`、`-x86_64.dmg`、`-universal.dmg`，以及各自 ZIP 和 SHA-256 清单。`dist/Farport.app` 是当前机器架构的副本。自有代码的 MIT 许可证和第三方声明会随新构建包提供。

当前 CLT 环境使用 `--build-system native`。Intel 构建还需要脚本中的运行时兼容参数，不建议手动删掉；原因见 [构建兼容记录](issues/2026-10-13-命令行工具链构建兼容.md) 和 [Intel 链接记录](issues/2026-10-13-Intel兼容库链接.md)。

脚本在检测到本机 `127.0.0.1:7897` 代理时，仅为本次 Git 网络请求启用它，不修改全局配置。生产分发目前使用 ad-hoc 签名；Developer ID 签名和 Apple 公证尚未完成。

## 测试

```bash
bash scripts/check.sh                 # 构建与核心断言
bash scripts/check.sh --integration   # Docker 隔离 SSH 环境与集成检查
bash scripts/check-workbench-ux.sh    # 实际界面回归，需要先准备隔离主机
bash scripts/check-attachments.sh    # 附件上传、回读和 tmux
bash scripts/check-file-preview.sh   # 中英文、目录历史、源码高亮与媒体播放
bash scripts/check-host-monitor.sh  # 本机/Linux监控、菜单及附件策略
```

完整范围和仍未覆盖的项目见 [验证记录](validation.md)。不要把本机 Apple Silicon 的验证结果当成 Intel 或所有 macOS 版本的实测。

`SWB_HOME` 可指定独立配置目录。测试凭据、原始截图、诊断报告和产物放在 `.test/`、`dist/`，不提交 Git。

## 更新介绍截图

```bash
bash scripts/test-environment.sh
bash scripts/capture-readme.sh
```

脚本只连接两个回环地址测试容器，真实打开终端、tmux、文件预览和传输页面。截图输出到 `docs/images/`；提交前必须逐张检查，不能用真实主机、账号、文件、令牌 URL 或 Agent 对话代替演示内容。

首页图片来自原生视图快照，不是设计稿。现有普通 QA 截图留在 `docs/screenshots/` 或 `.test/`，不要整体取消这些目录的忽略规则。

## 项目与发布

界面和自有错误使用 `L10n.text`，英文资源位于 `Sources/WorkbenchCore/Resources/en.json`；保留插值占位符，不翻译文件名、路径、枚举存储标识或协议内容。`FARPORT_LANGUAGE=en` 可用于独立英文回归；`workbench-tests --english-check` 验证英文资源，普通测试默认中文以兼容历史断言。

- [模块边界](architecture.md)：核心模型、OpenSSH/SFTP 和 macOS 界面的职责。
- [问题记录](issues/)：非平凡问题的定位和修复过程。
- [版本说明](releases/)：各版本变更。
- [第三方组件](../THIRD_PARTY_NOTICES.md)：许可证归属。

发布前检查版本号、三种安装包架构、签名、校验和与实际下载；不覆盖已有版本的安装包。`scripts/publish-private.sh` 是早期私有仓库交付脚本，会拒绝公开仓库，不用于目前的公开发布。
