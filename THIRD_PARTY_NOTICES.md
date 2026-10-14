# 第三方组件

Farport 自有代码采用 [MIT 许可证](LICENSE)。第三方组件仍遵循各自的许可证。

## SwiftTerm 1.20.0

- 用途：macOS 终端模拟与原生终端视图。
- 来源：`https://github.com/migueldeicaza/SwiftTerm`，由 `Package.resolved` 锁定。
- 许可证：MIT。上游许可文本包含 Miguel de Icaza、xterm.js authors、SourceLair、Christopher Jeffrey 的署名。
- 完整许可随应用位于 `Contents/Resources/ThirdParty/SwiftTerm-LICENSE.txt`；构建时从锁定版本的依赖中复制，不改写许可。

## OpenSSH

客户端调用 macOS 系统自带的 `ssh`，未将另一份 OpenSSH 二进制打包到应用中。

## Swift Argument Parser

- 来源：`https://github.com/apple/swift-argument-parser`。
- 许可证：Apache 2.0，附 Swift Runtime Library Exception，详见上游 `LICENSE.txt`。
- 由 SwiftTerm 的工具目标引入并记录在 `Package.resolved`，Farport 的应用目标不直接链接此组件。

## Haven

Haven 仅用作功能和交互参考，未复制或链接其源码。其许可证不作为本项目第三方代码许可证声明。
