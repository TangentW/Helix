<p align="center">
  <img src="Assets/Brand/Helix.Header.svg" alt="HELIX" width="680"><br>
  <strong>Swift 线上热修复与实时热重载系统 —— 这就是黑魔法</strong>
</p>

<p align="center"><a href="README.md">English</a> | <strong>简体中文</strong></p>

Helix 让 Swift 真正拥有线上热修复与实时热重载能力。开发阶段改完代码按下保存 —— 变化即刻出现在正在运行的 App 中；线上遇到问题 —— 把修复构建成补丁包，直接应用到线上。

真正的黑魔法来自 HLBC 与 HLVM：Swift 代码被编译成经过验证的字节码，再由虚拟机直接执行。一套强大的虚拟机核心，同时驱动实时热重载与线上热修复。

> **现状：** Helix 正在持续开发和测试，并逐步覆盖更多项目与使用场景。

![Helix 系统架构](Assets/Helix.Architecture.zh-CN.svg)

## 从这里开始

| 目标 | 指南 |
| --- | --- |
| 运行仓库内的 UIKit Demo，完整体验线上热修复与实时热重载 | [UIKit Demo](Demo/README.md) |
| 为现有 App 添加对应的 App 端模块、Xcode 集成与项目配置 | [使用入门](Docs/Getting-Started.zh-CN.md) |
| 确认当前支持哪些 Swift 代码修改，以及哪些修改仍需正常重新构建 | [能力与限制](Docs/Capabilities-and-Limits.zh-CN.md) |
| 理解 Swift 编译、HLBC、HLVM、补丁激活与两条工作流的隔离设计 | [总体架构](Docs/Architecture.zh-CN.md) |
| 准备 Release Shell，构建并签名 `.hlxp` 补丁，然后完成安装、激活与回滚 | [生产热补丁](Docs/Production-Hot-Patching.zh-CN.md) |
| 跟踪一次 Swift 代码保存如何经过编译、认证传输、运行时激活与 UIKit/SwiftUI 刷新 | [开发期热重载](Docs/Development-Live-Reload.zh-CN.md) |
| 使用 CocoaPods 把聚合 App 端模块接入项目 | [CocoaPods 接入](CocoaPods/README.md) |
| 使用 Helix Mac 助手发现项目、配置两条工作流并管理开发会话 | [Helix Hub](Hub/README.md) |

## App 端模块

Helix 为线上热修复和实时热重载提供两套独立的 App 端产品。每个 App target 只
链接其中一个；同一工程需要两项能力时，请分别配置 Release 和 Debug App target。

| 使用场景 | 引入模块 | 提供的能力 |
| --- | --- | --- |
| 线上热修复（Release） | `HelixAppRuntime` | 验证并执行 HLBC 补丁，管理安装、激活、恢复、吊销和回滚 |
| 实时热重载（Debug） | `HelixDevAppRuntime` | 接收并验证开发期更新，提供诊断并刷新 UIKit 或 SwiftUI；改动仅对当前 Debug 进程生效 |

编译器、Helix Hub 和 CLI 只在 Mac 上运行，不要把这些构建工具链接进 iOS
Release App。

## 环境要求

- 构建侧工具和 Helix 应用要求 macOS 14 或更高版本。
- App Runtime target 要求 iOS 15 或更高版本。
- 编译器集成与 fixture 需要包含 Swift 6 工具链的 Xcode。
- Live Reload 或 Release Shell finalize 前，需要先完成一次正常签名 Xcode 构建。

Package Manifest 使用 Swift tools 6.1。补丁与 Live Reload 产物会绑定目标 Shell
捕获到的编译器、SDK、源码、设置和二进制身份。

## 许可证

Helix 使用 [Apache License 2.0](LICENSE) 授权。
