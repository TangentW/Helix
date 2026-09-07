# 大型工程接入

[English](Large-Project-Integration.md)

源码数量、依赖广度、编译配置是三个不同维度。2,500 个标量源码文件的基准，不能代表
导入 100 个原生模块的 2,500 文件应用。请结合[构建性能记录](Build-Performance-Baseline.zh-CN.md)
中的计数器测量具体工程。

## 无 GUI 安装

Mac CLI 可以检查工程，并安装手写或已有的 Host Plan。它复用 Hub 的事务安装器，
处理 PBX、package、scheme、配置和生成文件；同一 plan 重复安装保持幂等。
目标映射无效或 Hot Patch 输入缺失时，在发布工程修改之前失败。

```sh
helix xcode inspect --project Example.xcodeproj --json
helix xcode validate --plan HostPlan.json --json
helix xcode install --project Example.xcodeproj --plan HostPlan.json --json
helix xcode doctor --plan .helix/xcode/HostPlan.json --profile live --static
```

手写 plan 放在工程旁，也可以使用已安装的副本。plan 内路径始终相对工程源码根目录。
单 target Live Reload 的最小结构如下；target、module、scheme、configuration 和 bundle
标识应改为实际工程值：

```json
{
  "schemaVersion": 2,
  "projectPath": "Example.xcodeproj",
  "integrationRoot": ".helix/xcode",
  "features": [
    { "id": "app", "targetName": "Example", "moduleName": "Example" }
  ],
  "profiles": [
    {
      "id": "live",
      "workflow": "liveReload",
      "schemeName": "Example",
      "applicationTargetName": "Example",
      "configurationName": "Debug",
      "bundleIdentifier": "dev.example.app",
      "namespaceSeed": "example-development",
      "featureID": "app"
    }
  ]
}
```

`inspect` 只读，列出 target、配置和 shared scheme。`install --json` 返回安装后的 plan
路径与写入文件的相对路径。安装保留传入 plan，包括明确填写的
`deviceNativeMatrixQualified`；省略该字段沿用现有真机后端策略，安装本身不构成真机资格证明。

Hot Patch 安装前须在 plan 指定位置准备 recipe、trusted root 和 signing certificate。
CLI 不自动创建签名身份，私钥由后续签名步骤使用。Live Reload 仍需要正常 Build/Run
及运行中的 Helix 服务。`generate` 继续用于单独生成 kit，`install` 则同时修改工程。
静态 Doctor 不能替代真实 Xcode 构建。

PBX 安装、重配置和移除按原始语法坐标修改变化的值与数组成员。未变化的对象、字段、
引号、注释和源文件条目保留原始字节，追加 trigger 不会重排大型 Sources phase。
新值遵守 OpenStep 的 ASCII 裸 token 规则，`libc++`、`@executable_path/Frameworks`、
`*.xcassets` 和条件 build setting key 都会正确加引号；转义字符串保持解码后的值。
系统 property-list parser 独立校验输入和输出；所有 PBX 修改在写入前校验，并在共享
文件事务提交前重新读回，发现内容变化或格式错误即回滚。该校验确认语法和预期字段值，
完整 Xcode 构建图仍需通过 `xcodebuild -list` 和实际构建验证。

## 与现有编译基础设施共存

所选源码 target/configuration 的有效 `SWIFT_EXEC` 必须指向生成的 Helix proxy。
target 层或命令行覆盖可能压过生成的 xcconfig，需要合并这些设置。Helix 在保留
`$(inherited)` 的基础上追加必要 `OTHER_SWIFT_FLAGS`、Bridge 链接输入及 Runtime 配置，
不接管 `CC` 或 `LD`。

要串联已有编译器 launcher，在启动构建的进程环境中导出绝对可执行路径：

```sh
HELIX_SWIFT_COMPILER_WRAPPER=/absolute/path/to/swift-launcher \
  xcodebuild -project Example.xcodeproj -scheme Example -configuration Debug build
```

launcher 的第一个参数是选中的真实 `swiftc`/`swift-driver`，后续参数是原始编译参数。
透明转发脚本如下；若要接入编译缓存或构建服务，应使用该工具实际支持的调用约定：

```sh
#!/bin/sh
set -eu
compiler=$1
shift
exec "$compiler" "$@"
```

launcher 须支持编译器发现调用，保持参数语义，产出请求的本地构建文件，并传播编译器退出码。
它必须调用传入的编译器，不能再次解析 `SWIFT_EXEC`。Helix 拒绝相对/不存在的 launcher、
自引用及递归 proxy。捕获记录保存真实编译器与原始参数，只有编译成功后才执行 post-compile。
后续分析直接重放真实编译器，因此不能仅在 wrapper 内添加隐藏语义参数；应把这些参数写入
Xcode 可捕获的设置。特定第三方缓存是否兼容，仍需该工具的集成测试。

XCBuild 不会把任意自定义 xcconfig 设置导出给编译器进程。因此，仅把
`HELIX_SWIFT_COMPILER_WRAPPER` 写进 xcconfig 并不等于环境导出。若明确导出
`HELIX_REAL_SWIFT_EXEC`，它必须指向真实 Swift 编译器，不能指向另一个 launcher；
否则 proxy 通过 `xcrun` 解析所选编译器。

### 构建设置与接入代价

| 设置 | Helix 的行为与影响 |
| --- | --- |
| `PRODUCT_MODULE_NAME` | 使用 Host Plan 选择的源码 module |
| `SWIFT_EXEC` | 接管源码 target 的编译入口；既有 launcher 通过上述合同链式调用 |
| `SWIFT_USE_INTEGRATED_DRIVER` | 设为 `NO`，用于完整 target 捕获与 post-compile hook；所选 configuration 无法使用 Xcode 自带 Swift 编译缓存 |
| `SWIFT_GENERATE_ADDITIONAL_LINKER_ARGS` | 设为 `NO`；当前 driver 路径不会生成 XCBuild 所需的额外 linker response file。导入 framework/library 仍由 Swift object autolinking 提供链接输入 |
| `OTHER_SWIFT_FLAGS` | 在继承值后追加 private-import、implicit-dynamic、replacement-chaining 与 user-module-version 参数 |
| `LD_DYLIB_INSTALL_NAME` | 源码 target 使用 `@rpath/$(EXECUTABLE_PATH)` |
| `OTHER_LDFLAGS` | 追加生成的 Bridge/bootstrap object 及所选工作流的 runtime 链接输入 |
| `ENABLE_USER_SCRIPT_SANDBOXING` | 设为 `NO`，供生成 phase 发现编译输入、写入 DerivedData 产物 |

Doctor 用 `HLXXC015` 提示 driver 与缓存代价，用 `HLXXC016` 拒绝实际观察到的源码
target driver 覆盖，并同时检查安装 manifest 和当前工具的生成模板。升级 Helix 后，
在 Hub 重新应用接入，或对工程和既有 Host Plan 执行 `xcode install`，一起更新设置
和生成文件所有权记录。`generate` 只负责独立 kit，已安装工程应通过 `install` 刷新。
Helix 自身的构建事实缓存及合格的下游 launcher 均不能恢复 Xcode 内建 Swift 缓存。

Xcode 26.6 混合样板在开启 explicit modules、保留旧 driver 设置时，复现了缺少
`*-linker-args.resp` 的链接错误；增加生成的 `SWIFT_GENERATE_ADDITIONAL_LINKER_ARGS=NO`
后，同一 Swift/ObjC++ App 编译链接通过。直接打开 integrated driver 仍不可行：仅有
proxy 时工具查找失败；补充相邻的真实 `swift` 后虽然构建成功，却没有生成 Helix target
捕获。因此 integrated driver 下的捕获和 post-compile 调度仍未取得支持证据。这些结果
不能用于比较两种 driver 的性能，也不代表所有定制 linker 配置均已验证。

## 编译身份与失败重试

[身份来源清单](Compiler-Identity.zh-CN.md)列出前端链路的键、作用域、拒绝规则及冲突诊断必须包含的依据。

| 事实 | 归一入口与依据 |
| --- | --- |
| 源码 nominal | Compiler declaration USR 加逻辑文件作用域区分 file-private 同名声明；显示名称不能单独作为身份 |
| Imported nominal | 按已建立的 ABI/runtime 身份分组，利用有证据的 module root 统一限定/非限定 Swift 拼写，再进入所有 merge 与 alias 消费点 |
| Imported operation | 精确声明/Descriptor、签名、owner module 和实测 ABI 是依据；共享 SIL 实现不代表两个 API 声明相同 |
| 源码与依赖输入 | 逻辑源码成员、内容 hash，以及编译器输入角色和字节；私有 compiler checkpoint 还绑定源码物理路径 |
| 可复用编译事实 | 精确 toolchain、SDK、target、语义参数、源码/依赖内容和 transform identity；仅拼写相同不能授权复用 |

因此 `Progress` 与 `Foundation.Progress` 可以归入同一 `NSProgress`，同时保留不同模块、
嵌套作用域间的真实区别。真正冲突会报告具体拼写、canonical/runtime 身份、声明/导入模块、
表示与隔离证据，并为每组不同事实给出一个源码位置。诊断位置只留在内存，不改变持久化身份。

Prepare 后期失败时，保留已分别校验的 typed AST、identity SIL 与 semantic SIL。
只修正后续 policy/Catalog 问题且编译器输入不变时，可复用这三个输出。命中仍会重新解析并
确认输入；编译器或 parser 失败不会入缓存。源码、依赖、toolchain、语义设置变化都会使
checkpoint 失效。完整 receipt 成功入缓存后，锁可用的中间大文件会被回收。
逐阶段确认输入会增加大依赖树的扫描工作，商业工程的冷路径及重试成本仍需实测。
隔离、失效规则及计数器见[增量构建事实](Incremental-Build-Facts.zh-CN.md)。

Bridging header、C++ interoperability 和工具链宏使用同一重放路径。driver 专属的
explicit-module 调度不直接复制进 AST 分析；捕获到的 module-loading 输入仍经过重放校验。
Canonical SIL 改从单独的私有输出文件读取，因为包含 bridging PCH 的 driver job 可能把
`-o -` 的 SIL 写到 stderr。诊断输出不会作为 SIL 解析。

常见源码写法的身份边界如下；详细依据见[编译器身份清单](Compiler-Identity.zh-CN.md)。

| 场景 | 当前行为 |
| --- | --- |
| 不同函数内的同名协议 conformer | 保留各条 witness table，不用类型/协议打印名做全局唯一断言；无法证明唯一性的类型及后代不提供布局、泛型或 dispatch 事实 |
| `private` / `fileprivate extension` 内省略访问修饰符的 class/struct | 继承 extension 默认级别；显式成员修饰符与私有父类型限制分别处理，重名私有布局保持隔离 |
| `optional ?? { ... }()` 的同位置闭包 | 用编译器符号角色区分 autoclosure 与显式闭包，再结合 discriminator；剩余歧义报告完整候选 |
| private static SDK overlay 属性 | 根据 `Static`/getter 结构证据匹配 AST `CoreFoundation.CGFloat` 与 SIL `CoreGraphics.CGFloat`，不误选共用坐标的 addressor |
| C callback 与 reabstraction thunk | 根据编译器适配属性和 thunk 角色排除生成入口；未知形态保留完整冲突证据 |
| `NS_SWIFT_NAME` 嵌套类与 Clang 扁平名称 | 以已证实的 Objective-C runtime 身份归一，保留泛型参数，不合并无关嵌套类型 |

## 声明范围与局部排除

Live Reload 默认采用 `excludeUnresolved`：被消费的 AST/SIL 映射存在歧义或缺失时，
排除对应源码声明，让其他已验证入口继续接入。Hot Patch 和原有 headless receipt API
默认保持 `strict`。headless 调用方可通过可选的 `FrontendReceipt.Request.indexing`
显式选择同一策略。这不会放开不支持的 Swift ABI，也不会容忍无效的编译器、类型或
Catalog 事实。

外层函数拥有其闭包和局部函数，属性/下标拥有其 accessor。排除身份绑定编译器声明
USR 与逻辑源码路径，同时保留位置和全部候选证据。函数体发现遇到内部映射失败时，
回滚此前收集的 operation；属性生成按整组 accessor 回滚。未被消费的合成 backing
声明不属于源码入口候选，实际消费者仍须验证 SIL。没有可信源码归属、源码集合不符、
SIL 损坏，以及类型、ABI 或 Catalog 冲突仍会阻止发布。

首次可先限定较小范围：把 Host Plan 升为 schema 2，在 feature 中加入 `indexing`，
然后重新执行 `xcode install`：

```json
{
  "id": "app",
  "targetName": "Example",
  "moduleName": "Example",
  "indexing": {
    "include": ["Sources/Feature/**"],
    "exclude": ["Sources/Feature/Generated/**"],
    "failurePolicy": "excludeUnresolved"
  }
}
```

模式匹配捕获到的逻辑源码路径，沿用 patch configuration 的 `*`、`**`、`?` 规则。
显式提供 options 对象但省略字段时，默认值是 `include: ["**"]`、`exclude: []`、
`failurePolicy: "strict"`。没有任何捕获源码匹配时，在 compiler replay 前拒绝。
所有捕获源码仍参与编译、源码/依赖 hash、nominal 和 imported-type 事实验证。
范围只缩小 Helix 的声明和源码 operation 发现，不代表整模块 Swift emission 会更便宜，
也不会屏蔽全局冲突或移除显式 Catalog 的权威能力。

`HLXIDX024` 会把每个排除声明及完整原因写入 `FrontendDiagnostics.json` 和诊断报告。
CLI 会显示排除数量与诊断路径，未变化的 Prepare 快路径也保留这些信息。模块 receipt
和 Prepare identity 包含 indexing 配置，切换策略或范围不会错误复用结果；修改范围外
源码仍会使整模块编译事实失效。原始 compiler checkpoint 只有在全部编译输入一致时，
才可跨策略变更复用。

不带 indexing 或 runtime package 配置的 Host Plan schema 1 继续可读，并保持原 canonical bytes 的往返。
indexing 配置要求 schema 2，让旧工具明确拒绝，而不是忽略范围。新建计划默认 schema 2。
原有公开 request/feature initializer 继续保留，新 overload 是增量 API。receipt 和设备
wire format 不变。PrepareState schema 1 增加可选的信息字段 `excludedDeclarationCount`；
旧文件缺省表示没有这项历史计数，复用仍由独立的 input hash 控制。

## 一次收集独立的 frontend 问题

可以使用 target 的编译器记录诊断 receipt。成功记录继续使用原有命令，
失败编译的 attempt 入口见下方预检说明：

```sh
helix xcode post-compile --plan .helix/xcode/HostPlan.json --profile live \
  --capture /absolute/DerivedData/path/FrontendInvocation.hlxswiftc \
  --diagnose --json
```

不加 `--json` 时输出可读文本和各检查耗时。报告包含 `passed`、带
`passed`/`failed`/`blocked` 状态和判定依据的 `checks`、声明资格诊断，以及分析启动后
的性能 trace。单个声明的资格诊断本身不代表分析失败。

仅排查 nominal 发现时，可跳过 SIL 重放和 Catalog 读取：

```sh
helix xcode post-compile --plan .helix/xcode/HostPlan.json --profile live \
  --capture /absolute/DerivedData/path/FrontendInvocation.hlxswiftc \
  --diagnose --stages source-nominals,imported-types --json
```

`--stages` 用逗号分隔检查入口，自动包含依赖，跳过未选择的分支；空列表和未知名称报错。

| 选择项 | 所需工作 |
| --- | --- |
| `inputs` | 请求、源字节和工具链检查；不生成 AST/SIL、不读取 Catalog 或依赖缓存清单 |
| `typed-ast` | 请求、源码、工具链校验及 typed AST 生成/解析 |
| `identity-sil`、`semantic-sil` | 对应 SIL 重放及其组件检查，不生成 typed AST |
| `source-nominals`、`imported-types` | Typed AST 和类型 demangling，不读取 SIL 或 Catalog |
| `source-mappings` | Typed AST、两种 SIL 重放/组件检查及 AST/SIL 映射 |
| `imported-operations` | Typed AST、类型 demangling 和 semantic SIL，不读取 identity SIL 或 Catalog |
| `catalogs` | Typed AST imports、工具链事实和已有 Catalog 校验，不读取 SIL |
| `receipt` | 完整 frontend receipt 分析与组装 |

诊断 JSON 现在输出 **schema 2**，可选 `requestedStages` 记录去重、排序后的选择项。
字段缺省（包括 schema 1 报告）表示完整范围。选择项不含 `receipt` 时，`passed: true`
和退出码 0 只表示所选检查及依赖通过，不能代表完整 receipt 通过。读取报告的工具需识别
版本 2 并检查范围。不传 `--stages` 或选择 `receipt` 时仍执行完整 frontend 验证。
此次诊断格式迁移不改变 Shell 或补丁产物 schema。

正常生成与诊断共用同一套有明确依赖关系的分析。诊断汇总独立的请求、源文件和编译
阶段错误；每份 SIL 内的函数定义、debug scope、源码模块、conformance 和 nominal
声明分别检查。函数定义和 debug scope 有效时，即使无关的 conformance 或布局失败，
仍能绑定函数位置并检查 AST/SIL 映射，汇总独立声明的映射冲突。类型环境、imported
operation 和 receipt 在依赖事实无效时保持 blocked，不构造空的替代 `CanonicalSIL.File`。

组件检查名位于 `frontend.identity_sil.*`、`frontend.semantic_sil.*` 下，性能 trace
包含各项耗时，以及 CLI 输入准备和所需的 Catalog 读取。嵌套计时互相重叠，不能把所有
阶段时间相加当作总耗时。捕获或上下文无效时无法继续编译；最终 receipt 组装仍在首个
错误处停止，该模式不承诺从无效输入中枚举所有可能问题。

诊断只读取所需且已有、验证通过的 Catalog，报告缺失的生产覆盖，不启动冷编目或后台
预热。它绕过完整模块 receipt 缓存，确保执行当前检查，但复用并保留逐阶段验证的
compiler checkpoint。SIL 的局部有效事实不会作为整个 SIL 成功写入检查点。
不发布模块 receipt、Shell、Bridge、Prepare state 或 Hub reservation。
链接、服务连接及 runtime 激活仍须通过正常 Build/Run 验证。

## 混合配置回归

[`Tests/Fixtures/MixedOnboarding`](../Tests/Fixtures/MixedOnboarding/README.md)
是真实的小型 Xcode App，包含两个 `@TaskLocal` 展开、同名局部协议 conformer、继承
`fileprivate extension` 访问级别的 class/struct、`?? { ... }()` 闭包、带与不带 module
前缀的 SDK 名称，以及 UIKit 的 `NS_SWIFT_NAME` 嵌套类型 `UIPencilInteraction.Tap`
（iOS 17.5）。同时包含 Foundation/UIKit/AVFoundation/Photos、Objective-C bridging header、
C++ interop、`-g`，并在工程设置中开启 explicit modules。可选集成测试实际编译链接，
捕获全部 5 个 Swift 文件，连续安装两次，用 `plutil` 校验 PBX、用 `xcodebuild -list`
读取安装后的工程，再执行局部 nominal 检查和完整 receipt 诊断，核对 SIL 组件及
AST/SIL 映射。driver 探测分别记录构建结果与捕获是否存在。
直接编译的 `SystemFrameworkIntegration` 测试另外执行 `-explicit-module-build`，
并核对输出确实包含 debug scope。

样板验证配置之间的相互作用，不代表 100-module Catalog 基准或物理设备激活验收。
debug 占位符身份另有 SIL 语法回归；小型 Swift 宏样板不声称复现商业工程编译器输出的
`__unknown_macro__` 拼写。

## 安排 Catalog 冷编目

历史 UIKit 冷 Catalog 约 230 秒，是特定 SDK/toolchain 的单模块测量。模块数量不能单独
预测总成本：API 广度、依赖重叠、候选拒绝和有效缓存命中都会影响结果。目前没有实测的
100 模块完整冷编目总时长，不能用 UIKit 数字乘以 100，也不能引用标量源码基准代替它。

分别记录冷 Prepare、Catalog job 完成时间、产物字节和后续命中。后台 job 支持限额续跑：

```sh
helix xcode catalog-prewarm --job /absolute/path/to/job.json --max-modules 1
```

已验证命中不消耗该额度，完成的模块在中断后保留；被中断的未完成模块可能重做。
从捕获时的工作目录运行，job 锁阻止两个 worker 同时处理同一 job，重复命令即可续跑。
具体位置和生命周期见[搜索路径与 Catalog 续跑](Incremental-Build-Facts.zh-CN.md)。

团队可以在各开发者账号下，使用精确 toolchain/SDK 和输入执行预热。当前缓存是 owner-private，
没有受支持的可移植 Catalog 导入/导出协议或多人共享可写缓存协议。复制 DerivedData 或同事的
缓存本身不构成兼容性证据。

## 当前构建侧资源边界

以下是强制校验或缓存截止条件，不代表低于边界的任意工程都能低内存、快速编译。
MiB/GiB 按 1,024 计算。

| 环节 | 边界与行为 |
| --- | --- |
| 直接进程 argv | 超过 3,000 参数或 128 KiB 后，支持的编译器使用 response file；不支持的 executable 返回启动错误 |
| Swift 源码读取 | 每文件 64 MiB；Shell materialization 默认总量 512 MiB；超限在验证时失败 |
| Compiler input 扫描 | 每根目录 250,000 项、总计 100,000 文件/1 GiB 跟踪字节；扫描不完整或不稳定时禁用复用 |
| 显式扫描输入 | Module map 8 MiB、VFS overlay 16 MiB、bridging header/header map 64 MiB、其他显式编译器输入 512 MiB |
| Planning inventory | 单次同步 plan 最多保留 250,000 个根/目录项记录，不跨调用保存目录清单 |
| Catalog 闭包 | 含依赖扩展最多 256 模块 |
| Native API Catalog | 每模块 250,000 entries、编码文档 128 MiB；每 producer 最多 4 个 frontend probe worker，每批 256 候选 |
| 显式 NativeImport policy | 与模块 Catalog 不同：1,024 types、4,096 candidates、文档 8 MiB |
| Host Plan | 128 features、256 profiles、文档 1 MiB |
| Receipt/缓存 | Shell receipt 32 MiB、模块 frontend 缓存 payload 64 MiB、compiler checkpoint 每阶段 256 MiB；缓存 payload 超限时不存储 |

源码头文件应与生成缓存分开：bridging header 捕获会保守地指纹化邻近编译器接口文件，若把
module cache 放进源码头文件目录下，会扩大扫描输入并可能禁用复用。分析重复构建耗时前，
先检查 `frontend_cache.compiler_inputs_incomplete_count`。

当前没有宿主进程 RSS 硬预算，也没有缓存磁盘总配额。AST/SIL 输出和解析结构会进入内存。
4 workers 是每个 producer 的边界，不是整机信号量。失败 checkpoint 可能保留磁盘空间，
重置私有缓存前应停止使用它的构建进程。真机原生激活、商业工程保存到屏幕延迟，以及其
完整冷 Catalog 成本，仍须对应工程实测；宿主交叉编译不能证明这些路径。

Hub 读取并重新应用接入时保留已配置的 feature 索引范围及现有真机资格标记。共享源 target 的工作流可继承尚未指定的策略；两个显式策略冲突时，诊断会列出 profile、target、工程路径和冲突值。

## 成功构建前的预检

proxy 在调用编译器**之前**，将私有 `FrontendAttempt.hlxswiftc` 原子写入
`FrontendInvocation.hlxswiftc` 所在目录。编译器发现查询不生成 attempt。编译失败保留
上一份成功记录，不运行 post-compile hook。每次调用保留自己的私有记录直至退出，
不会把并发调用的 attempt 当作自己的成功记录。字节格式仍为 `HLX.SwiftInvocation.v1`；
新增文件名明确表示诊断输入，不构成成功构建证据。

```sh
helix xcode preflight --plan .helix/xcode/HostPlan.json --profile live \
  --capture /absolute/DerivedData/Build/Intermediates.noindex/Example.build/Debug-iphonesimulator/Example.build/Helix/FrontendAttempt.hlxswiftc \
  --stages inputs --json
```

省略 `--stages` 执行 `inputs,typed-ast`；选择 `source-mappings` 可进一步检查 SIL
身份映射并汇总声明排除。`inputs` 校验所选 compiler/SDK、调用参数、源码集合及字节，
不指纹化依赖缓存、不生成 AST/SIL。通过只代表输入检查成功，不代表类型检查或运行时
覆盖。typed 检查仍需要生成的依赖模块、头文件和插件。Xcode 至少需要运行到 target
compiler proxy 一次，预检不会凭空生成完整的构建参数。

`post-compile --diagnose` 也接受 attempt，正常 `post-compile` 拒绝使用它。预检不发布
receipt、Shell、Bridge、Prepare state 或 Hub reservation。混合样板用真实捕获参数
触发编译错误，再验证输入预检通过、typed 预检报告错误、成功记录保持原样。

SIL 元数据扫描先按记录前缀筛选，再分配字符串和执行正则；注释边界按 UTF-8 分隔符
扫描，未转义路径不再逐字节解码。scope 继承改为迭代遍历，并记忆没有位置的结果。
两种 SIL 重用选定的 AST 成员清单进行有界符号分类。具体测量边界见
[解析器对照](Build-Performance-Baseline.zh-CN.md#sil-调试元数据扫描)。完整模块编译输入
仍参与失效判断，不声称支持按文件 WMO 复用或并行 Swift frontend 发射。

## 团队 runtime 版本与卸载

Host Plan schema 2 可在顶层设置 `runtimePackageRequirement`：

```json
"runtimePackageRequirement": {
  "kind": "revision",
  "value": "<经过验证的 40 位小写十六进制 commit>"
}
```

将占位符替换为实际 commit。`kind: "exactVersion"` 接受规范的 `major.minor.patch`
发布版本；预发布或其他 tag 可使用其完整 commit。Xcode 负责解析引用。Helix 校验字段
并写入 requirement，不保证给定 revision 已存在，也不替团队验证工具/runtime 组合。
团队需在发布流程中选择并验证这组版本。

安装器复用已经匹配的远端引用，允许更新 Helix 自己创建的引用；用户自有引用与显式
pin 冲突、显式远端 pin 遇到本地包，或出现多个 runtime package authority 时，在发布
工程改动前拒绝，并列出 package ID、仓库/路径及 requirement。Hub 读取、编辑和重新
应用时保留该字段。schema 1 不允许携带此字段，旧计划字节及缺省行为保持兼容。

缺省保留现有 package requirement；不存在可复用引用时，兼容缺省仍为 canonical
仓库的 `main` 分支，不虚构已发布的默认 tag。团队计划应显式固定经过验证的 revision
或版本，并继续按正常流程把 Xcode package resolution 文件纳入版本控制。

无需 Hub GUI 即可卸载：

```sh
cp .helix/xcode/HostPlan.json HelixRemovalPlan.json
helix xcode uninstall --project Example.xcodeproj --plan HelixRemovalPlan.json --json
```

安装计划仍存在时，备份必须与其一致；生成文件已经移除后，可用备份重复执行或恢复
卸载。CLI 复用 Hub 的事务 ownership 清理和最小 PBX 修改，恢复原有 configuration
引用，保留业务源码、用户 package 引用、开发者文件和签名材料。不需要成功构建、
Catalog、recipe 或私钥。ownership 清单损坏时仍禁止扩大删除范围，未知文件保留。
该命令修改选定工程，不改动 GUI 注册记录。混合 Xcode 样板在移除后检查工程可读取且
真实构建成功，此项不包括物理设备 runtime 行为。

可移植 Catalog 导入/导出及共享可写缓存协议仍未实现。未来的 bundle 需要将 Catalog
和 compiler projection 与精确 compiler、SDK、依赖及 artifact identity 一并验证；
不能把当前 owner-private 缓存直接复制后就宣称支持跨机器兼容。

安装及两条卸载 API 在完整的读取、验证、写入期间持有 canonical `.xcodeproj` 目录的
非阻塞 advisory lock。同一工程上的其他 Helix 操作会在修改前拒绝，不同工程互不影响。
目录锁不受 PBX 文件原子替换影响，也不生成额外 lock 文件。它只协调 Helix 操作，
不协调未持有该锁的外部编辑器或 Git 命令。
