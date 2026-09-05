# 使用入门

[English](Getting-Started.md)

Helix 的默认接入路径只有三步：打开 Helix，选择 Xcode 工程，点击 **Enable Helix**。普通 iOS App 不需要拆 target、预先创建共享 Scheme、导入 Helix module、编写启动代码、维护源码列表、配置 API 白名单，或执行所谓“冻结”。

Helix 会在正常 Xcode 构建中自动读取编译器已经证明的事实，并在 DerivedData 里生成 Bridge。那些精确事实用于保证热重载和热补丁不会套用到错误的二进制；它们是自动生成的构建身份，不是项目接入时要维护的配置。

## 环境要求

- macOS 14 或更高版本；
- iOS 15 或更高版本；
- 带 Swift 6 工具链的 Xcode；
- 一个能由 Xcode 正常 Build/Run 的 iOS App target。

项目可以使用单 target，也可以已有多个 framework。Helix 默认直接使用 App target 的 Swift 源码；独立源码 target 只是已有模块化工程的可选映射，不是接入前置条件。

## 一键启用

在仓库中构建并打开 Helix：

```bash
Hub/Scripts/build-app.sh release
open Hub/.build/Helix.app
```

然后：

1. 选择 `.xcodeproj`、`.xcworkspace` 或包含它们的目录。
2. 保留需要的 Hot Patch 和 Live Reload 工作流。
3. 检查 Helix 自动识别的 App target、源码 target、Scheme 与 configuration。
4. 点击 **Enable Helix**。

对普通单 target App，Helix 默认选择同一个 App target 作为源码模块，Live Reload 使用 Debug，Hot Patch 使用 Release。没有共享 Scheme 时，Helix 会创建一份可运行、可归档的共享 Scheme。高级映射只用于自动识别不符合预期的特殊工程，不是正常接入步骤。

## Helix 自动修改什么

所有修改会在一次可回滚事务中完成；任一步失败都不会留下半套工程状态。

| 区域 | 自动行为 |
| --- | --- |
| Package | 复用已有 Helix Swift package；没有时添加官方 package reference |
| App product | 给 App target 链接统一的 `HelixAppIntegration` |
| Debug 支持 | 让 App target 可用动态 `HelixDevSupport`，但只在 Live Reload configuration 中链接和嵌入 |
| Swift 编译 | 用透明 compiler proxy 捕获所选 configuration 的真实成功编译；同一 App/源码 target 只使用一个空的 Hub-owned trigger 刷新增量 Run，并将它排除在业务 Shell 源码集合之外 |
| Bridge | 在 DerivedData 中生成并编译 `HelixBridge.o` 与自动启动 object；不把生成 Bridge Swift 加进工程 |
| Build settings | 用 configuration 级 wrapper 保留原 Base Configuration，再追加 Helix 设置 |
| Scheme | 自动创建或更新 Run 注册与 Release 审计 action |
| 本地网络 | 在 App 已有 embed/copy phase 之后、签名前幂等补齐已处理的 Live Reload plist；业务 plist、Xcode plist 设置与 Release 产物保持不变 |
| Hot Patch | 自动生成 Patch action、初始 recipe、资源嵌入和可选本地开发签名材料 |

Helix 不改业务 Swift 文件，不要求业务代码 import 或初始化 Runtime，也不要求维护 target 源码清单、Native API 清单、host、port、配对 secret、LLDB 脚本或 shell `PATH`。

## 随时修改或移除接入

首次识别出的映射不会被锁定。随时在 Helix 中重新打开工程，修改 App target、源码 target、Scheme 或 configuration，再点击 **Apply Changes**。Hub 会按原 PBX identity 恢复已不再使用的 Base Configuration 引用，移除旧 compiler trigger、product、phase、Patch target 与 Scheme action，然后幂等应用当前映射。已有 Scheme 的 Run/Archive configuration 和所有非 Helix action 都不会被改写。

生成的 Host Plan 是 target 与 module identity 的唯一事实来源。Hub registry 不再保存第二份可漂移的 target 映射，因此重新打开或重复应用工程时不会复活旧映射。
owner-only registry 只保留最近一次接入计划作为自动移除快照，因此即使生成文件意外丢失，**Remove Helix** 仍能恢复工程；构建和重配置都不会把该快照作为输入。

关闭其中一个工作流即可只移除该工作流；两个都关闭后点击 **Remove Helix**，工程会自动恢复。Hub 只删除生成文件所有权清单中记录的文件，独立放进接入目录的未知文件不会被认领或删除；业务源码、业务配置、Patch recipe 与签名材料都会保留。重配置和移除同样使用可回滚事务，并拒绝符号链接或越界路径。

## Runtime 自动启动

App 侧只有一个长期生产产品：`HelixAppIntegration`。Hub 生成的隐藏启动 object 决定当前工作流：

- Live Reload configuration 调用 `HelixDevSupport` 的开发启动入口；
- Hot Patch configuration 调用 `HelixAppIntegration` 的生产启动入口。

选择依据来自具体 Helix profile，而不是 configuration 是否恰好叫 `Debug`、是否定义某个编译宏，或业务代码中的条件分支。开发 Runtime 被放在独立动态 framework 中，并由 Release bundle 审计明确禁止；生产产品不依赖开发传输、动态加载或调试 UI。

因此 App 中不再需要这样的代码：

```swift
// 不需要 import Helix...
// 不需要创建或强持有 ApplicationSession
// 不需要在 AppDelegate / SceneDelegate 中调用 start
```

高级诊断工具仍可读取公开状态 API，但普通接入不依赖它。

## 第一次 Live Reload

1. 保持 Helix 在菜单栏运行。
2. 在 Xcode 中选择已配置 Scheme，正常 Run。
3. 打开要测试的页面。
4. 修改一个已有 Swift 实现并保存，不需要再次 Build。
5. 在 Helix 中查看 compile、transfer、activation 与 UI refresh 状态。

Xcode 启动的 App 会自动发现唯一 `_helix._tcp` 服务，验证构建时写入的 Host Identity pin，并兑换一次性邀请。无需自定义 LLDB、环境变量、host 或端口。从桌面直接打开同一个调试包时仍使用四位码确认用户在场；短码之外还必须通过 pinned TLS 与精确 App 构建身份验证。

UIKit 的常见 controller/view layout、drawing 与 configuration callback 会自动定位存活实例并执行安全 invalidation。`present`/`dismiss`、常见 Foundation/UIKit API、同步 closure 与原生 callback 走编译器证明后生成的通用 Bridge；不是按 Demo API 写特例。确实需要重放业务初始化或重建页面时，才使用显式 reload hook 或 factory。

## 第一次 Hot Patch

1. 正常 Build 或 Archive 配置好的 Release configuration。
2. Helix 自动记录该产物的编译器、SDK、源码接口、Bridge 与 executable 身份，并审计最终 App bundle。
3. 修改受支持的实现。
4. Build Helix 自动创建的 Patch Scheme，生成已验证并签名的 `.hlxp`。
5. 通过产品自己的分发通道下发；App Runtime 完成验签、安装、激活、健康确认与回滚。

Hub 生成的本地开发身份和初始 recipe 用于快速验证完整流程。真正生产下发时，信任根、签名服务、审批、rollout 与合规策略属于不可省略的安全决策；它们不是日常 Live Reload 或项目接入配置，也不能由工具替产品方猜测。

## “当前构建身份”不是用户冻结

Helix 在每次正常 Xcode 构建中自动捕获：

- Swift compiler、SDK、target triple 与语义编译参数；
- Xcode 实际编译的源码 membership；
- 可替换声明的签名、隔离、ownership 与实现 anchor；
- 从 typed AST、canonical SIL 与 SDK symbol graph 证明的原生类型和 API adapter；
- 最终 executable UUID、bundle 与签名相关身份。

开发者不编辑这些记录，也不为新增常用 API 更新白名单。保存代码时，Helix 会在同一编译上下文重新 type-check，并尽可能自动生成所需的具体 NativeImport。若修改了函数签名、stored layout、继承、conformance、target membership、依赖或 Build Settings，执行一次普通 Xcode Build 即可让 Helix 重新捕获；这与 Swift 二进制和对象布局实际变化一致，不是额外的 Helix 配置流程。

HLBC 仍不是“在设备上执行任意 Swift”。无法证明的 ABI、运行时 metadata、任意指针、未受控并发或越过签名/沙箱的行为会被拒绝。这些是 iOS、Swift ABI 和补丁安全的硬边界，不会被伪装成可关闭的易用性开关。当前常见语法与 API 覆盖见[能力与限制](Capabilities-and-Limits.zh-CN.md)。

## 可选诊断

CI 和脚本接入可使用 `helix xcode inspect` 与
`helix xcode install --project PATH --plan PATH`，安装复用 Hub 的事务工程修改引擎。
完整 plan 示例、编译器包装器串联、重试行为及规模边界见[大型工程接入](Large-Project-Integration.zh-CN.md)。

正常使用不需要命令行。排查工程状态时可以运行：

```bash
swift run helix xcode doctor \
  --plan .helix/xcode/HostPlan.json \
  --profile live \
  --static
```

常见处理：

| 现象 | 处理 |
| --- | --- |
| App 构建设置或源码刚发生结构变化 | 正常 Build/Run 一次，Helix 会自动重新捕获 |
| 保存后编译失败 | 查看 Helix 给出的源码位置和具体不支持形状；上一个成功 generation 仍保持激活 |
| 代码已激活但页面未变化 | 当前实例可能不在可见图中，或该生命周期需要显式幂等 hook/factory |
| Release 审计发现开发模块 | 检查该 configuration 是否被手工链接或嵌入 `HelixDevSupport`；Hub 生成路径不会把它带入 Release |
| Scheme 或生成文件被外部工具覆盖 | 在 Helix 中重新执行 **Apply Changes**；生成目录由 Hub 管理，不应手改 |

本地协议、schema、ABI 与产品版本目前统一保持为 1。项目仍处于发布前开发阶段，不保留废弃接入方案的兼容层。

继续阅读[总体架构](Architecture.zh-CN.md)、[开发期热重载](Development-Live-Reload.zh-CN.md)和[生产热补丁](Production-Hot-Patching.zh-CN.md)。
