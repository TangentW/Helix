# 能力与限制

[English](Capabilities-and-Limits.md)

Helix 有意采用 fail-closed 策略。“Swift 编译器接受这个文件”不等于“生产字节码后端支持这个语法”，“理论上 dylib 能装下这个声明”也不等于“当前 Live Reload 生成器已经会收集它”。本文给出当前实际边界。

## 产品状态概览

| 范围 | 已实现 | 尚未认证或实现 |
| --- | --- | --- |
| Release Shell | 精确 frontend 索引、Derived Sources、Interface Archive、永久 Bridge、NativeImport 发现、Xcode 集成、bundle 泄漏审计 | 大型真实业务迁移和长期 CI 矩阵 |
| 生产 HLBC | HLBC 1.9 / HLXI 2.4 编译链、Verifier、HLVM、签名包、安全安装、不可变激活、回滚与吊销 | App Store 分发批准、top-200 业务 corpus、长时间 fuzz/sanitizer、真机 macro 性能 |
| Native Live Reload | 精确构建捕获、稳定快照、typed AST body 重建、递归/previous 处理、签名 dylib、认证传输、`dlopen`、UIKit/SwiftUI 刷新 | 真实 iPhone 矩阵、连续 100 代 soak、LLDB 自动符号加载、大型工程延迟资格 |
| 开发期 HLBC | 后端路由和会话绑定的验证后 HLBC artifact | 与 Native 编译器相同的源码覆盖；不支持的 root 仍需完整构建 |
| 控制面 | 客户端包与 policy 合同 | 生产 Registry、HSM 运维、审批、灰度、遥测和设备群协调服务 |

当前 SwiftPM 基线包含 381 个测试、63 个 suite，记录的 Debug、warnings-as-errors 与优化 Release 回归均通过。iOS Simulator target 覆盖 8 个 Runtime 与 UI 用例。这些数字代表仓库证据，不代表真机或分发认证。

## 生产 HLBC 1.9 的 Swift 子集

### 已实现

- `Bool`、有/无符号定宽整数、`Float` 与 `Double`，包括已声明的算术、位运算、比较、移位和数值转换规则。
- `String` 字面量、拼接、支持标量的插值、count/empty、比较以及常见 prefix/suffix/contains 判断。
- Tuple、`Void` 与 `Optional`，包括 `if let`、`guard let`、`??` 和 `try?` 产生的普通控制流。
- Array 值语义、append、迭代、安全下标和返回新值的更新；支持键值类型下的 Dictionary 构建、查找、更新与迭代。
- 结构化分支、循环、switch、调用、递归、显式业务错误边和带 payload 的局部 Error 值。
- 补丁内非递归 stored struct/enum、具体 `Result`、字段读取、enum switch 与支持的 mutating helper。它们是 VM 值，不是新加载的 Swift metadata。
- 同步补丁内 `inout` 与 `mutating` helper，并受 Address、access、alias、ownership、同 frame/同 block 规则验证。
- 捕获 copyable VM-managed 值的同步非逃逸补丁内 closure，以及不再包含 archetype、metadata 或 witness 依赖的编译器完全具体化 specialization。
- 顶层无 suspension 的 `async`、`async throws` 和 `@MainActor async` entry。生成的精确 Swift wrapper 保留 ABI，HLVM 只执行已经证明不会挂起的 body。
- 调用同 image helper、eligible Shell entry 与目标 Shell 已经生成的精确 allowlisted NativeImport。

### 拒绝或有意未完成

- generic root，以及仍需要运行时 generic metadata、witness table、reabstraction 或动态 specialization 的执行。
- 真正 suspension：`await`、continuation、Task、async callee、async closure、cancellation，以及跨 suspension ownership 或 generation lease。
- actor-isolated instance root、custom global actor 和任意 executor hop；上面的受限 `@MainActor async` leaf 是不同能力。
- escaping、throwing、async、nested-capture 或跨 Native 边界的 closure。
- 新原生 class、跨补丁边界可见的新 Swift metadata、retroactive conformance、layout、superclass 与 enum case 变化。
- Generic 或 `inout` Shell entry、noncopyable root、任意 borrowing/consuming ABI、typed-throws root、`rethrows` 与通用 unwind cleanup。
- 不受限 pointer、`unsafeBitCast`、任意 Objective-C selector/IMP、`dlopen`/`dlsym`、Mirror 字段修改与未知 builtin。
- 已发布 Shell 中没有精确 `NativeImportID` 的原生调用，即使 App 中存在名字相似的 Swift 函数。

## Native Live Reload 边界

Native Live Reload 由精确 Swift 编译器生成普通机器码与 metadata，因此能保留更多 Swift 语义；但当前生成器仍只面向已有声明 body。

| 修改 | 当前结果 |
| --- | --- |
| 修改已索引的 global、instance、static 或 class 函数体 | 在通过资格的 Native 目标上支持 |
| 从函数体调用已有 private/internal/public 声明 | 能在捕获 module 中解析并链接 Dev Shell 时支持 |
| 普通直接递归 | 通过 typed AST 精确身份重绑定到当前 generation |
| 有意调用上一代 | 使用受限的 `LiveReload.previous { ... }` marker |
| 在变化 body 内新增局部 helper、closure 或局部类型 | 是合法 Swift 时随 body 编译 |
| 新增任意文件级 helper/type/extension 或新 Swift 文件 | 当前生成器不收集，需要完整构建 |
| 修改 stored property、签名、generic constraint、actor isolation、superclass、conformance 或 enum case | 拒绝，需要完整构建 |
| 修改 default argument 行为 | 旧 call site 可能已经包含旧 generator；要可靠生效需要完整构建 |
| 修改 static/global initializer | 已经初始化的状态不会自动重放 |
| 新增 framework、package、macro/plugin 输入、bridging header 或 source membership | Dev Build Manifest 失效，需要完整构建 |
| 修改 storyboard、XIB、asset、strings、Core Data model、plist 或 entitlement | 不属于 Swift body Live Reload 路径 |

Native replacement 能访问 private 成员，是因为 Helix 使用原 source-file 身份和捕获到的 module 上下文编译它。这不代表任意进程符号都可调用，也不会绕过 linker、代码签名、Team ID、AMFI 或 Library Validation。

Simulator Native 是当前已经验证的路径。真实 iPhone Native 在每个精确编译器、系统、架构、签名身份、provisioning、Team ID 和依赖组合通过设备矩阵前仍是 experimental。

## UI 刷新边界

代码替换决定下一次函数调用的行为；UI invalidation 决定用户是否立即看到结果。

- 简单 render 与 layout 修改可以使用显式 constraint、layout 和 display hint。
- 有状态 UIKit 页面应实现幂等 `LiveReload.Reloadable` hook。
- 重建 Controller 需要注册 Factory、route context、state capture/restore 和容器支持。
- SwiftUI 需要 `liveReloadBoundary`；`invalidateBody` 尽量保留 identity，`recreateSubtree` 会重置该 boundary 的局部状态。
- Helix 不会自动重放 `viewDidLoad`、`loadView`、initializer、observer 注册、subscription 或任意生命周期 callback。
- 没有安全目标或规则时，代码可以保持激活，但结果会是 `manualRefreshRequired`。

仓库 fixture 已证明基础 UIKit 目标解析、invalidation、状态保持、SwiftUI pulse 路由和 Debug Overlay 行为；它们不能认证所有 custom container、navigation/sheet 交互、observation graph 或长期副作用模式。

## 安全与资源边界

生产与开发路径都会对未知版本、capability、目标、身份、重复记录、畸形容器和资源超限 fail closed。生产字节码具有 fuel、deadline、stack、register、调用深度、值形状、NativeImport 和内存计量；下载与 live transfer 会在分配和执行前进行有界检查。

Native Live Reload 会保留已加载 image，因此有明确的 image 与字节上限。同步 Swift NativeImport 无法被硬抢占；只有具备 deadline 与 checkpoint 的 bounded/cooperative import 才适合进入生产 Catalog。真实设备尾延迟和内存压力仍是 Gate。

## 兼容性与分发

Swift Package 的平台下限为 macOS 14 与 iOS 15。补丁绑定一个 finalized Shell interface 与目标身份，不得猜测某个 App build 的包与另一个 build 兼容。

当前 Release Builder 允许 internal 与 enterprise HLBC policy。App Store 通道仍是 `policyBlocked`，受控 Native Release 后端尚未实现。平台政策、签名与组织审批独立于字节码引擎是否在技术上能运行。

完整流程见[总体架构](Architecture.zh-CN.md)、[生产热补丁](Production-Hot-Patching.zh-CN.md)和[开发期热重载](Development-Live-Reload.zh-CN.md)。
