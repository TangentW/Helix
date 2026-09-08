# 构建性能观测与基线

[English](Build-Performance-Baseline.md)

本文记录 Helix Xcode 构建侧的可执行性能基线。它回答两个问题：时间实际花在哪里，以及后续优化有没有在不缩减热重载、热修复能力的前提下生效。

## 观测边界

Xcode 集成会在当前 profile 的 DerivedData 输出目录写入以下本地报告：

```text
HelixGenerated/<profile>/BuildPerformance.prepare.json
HelixGenerated/<profile>/BuildPerformance.bridge.json
HelixGenerated/<profile>/BuildPerformance.finalize.json
HelixGenerated/<profile>/BuildPerformance.patch.json
```

报告 schema 固定为 `1`，记录：

- 本次操作、Live Reload/Hot Patch 工作流、成功或失败；
- 使用单调时钟测得的总耗时和具名阶段耗时；
- Swift frontend 子进程按用途和可执行文件名聚合后的次数、失败数、耗时及输出字节数；
- 源码、候选 API、探测批次、函数、NativeImport 等计数；
- 生成产物的相对路径和字节数。

阶段可能嵌套。例如 `prepare.frontend_receipt` 包含多个 `frontend.*` 阶段，不能把报告中所有阶段直接相加。子进程记录也只保存用途和可执行文件的 basename，不保存完整命令行、源码路径、SDK 路径或签名材料。

这些报告只用于本机构建诊断。耗时、计数和报告字节都不会进入 HLBC、HLXI、`.hlxp`、签名输入、Shell hash、Release baseline identity 或 App bundle，因此不会破坏可复现构建，也不会改变任何产品协议版本。报告写入失败会令对应成功构建阶段失败；原始构建失败时，Helix 会尽力写一份 `outcome = failure` 的部分报告，同时保留原始错误。

## 2026-08-26 Demo 基线

测量命令使用 `Helix Live Reload Demo`、Debug、通用 iOS Simulator destination 和独立 DerivedData。测试机当时磁盘空间紧张，因此下表只用于定位数量级与阶段占比，不作为跨机器性能承诺。

| 场景 | 未加观测时 | 加观测后 | 结论 |
| --- | ---: | ---: | --- |
| 全新 DerivedData 冷构建 | 55.73 s | 61.72 s | 冷构建受磁盘与 SwiftPM/Xcode 缓存波动影响较大 |
| 同一 DerivedData、源码无变化的立即重构建 | 39.13 s | 39.10 s | 观测本身没有造成可见的增量构建回退 |

一次成功的无变化重构建中，Helix 自身的关键阶段如下：

| 阶段 | 耗时 | 占 Prepare |
| --- | ---: | ---: |
| `prepare` 总计 | 29.144 s | 100% |
| `prepare.frontend_receipt` | 28.111 s | 96.5% |
| `frontend.expand_managed_debug_surface` | 24.688 s | 84.7% |
| `prepare.materialize_shell` | 0.911 s | 3.1% |
| `prepare.publish_artifacts` | 0.037 s | 0.1% |
| `bridge` 总计 | 4.692 s | — |
| `bridge.compile_swift` | 4.645 s | Bridge 的 99.0% |

表格保留了当时报告里的历史指标名。现在同一阶段名为
`frontend.expand_managed_native_surface`，因为 Release 与开发共用实测调用面，只采用
不同的发布策略。

一个代表性的冷 Prepare 报告还给出了更细的调用量：

- 1 次 UIKit symbol graph 提取耗时约 14.74 s；
- 800 个公开候选被归并为 96 个探测批次，最终测得 469 个操作；
- 97 次 Typed AST 调用中有 56 次探测性失败；这些失败表示该候选批次不能由当前 frontend 精确类型检查，不是构建错误；
- 42 次 canonical SIL 调用；
- SDK path 与 SDK build 各查询 140 次，也就是 280 次重复 `xcrun`；
- 最终生成 476 个 NativeImport、24 个 native type；
- Shell 目录约 3.6 MiB，其中 `ShellBuildReceipt.json` 约 1.05 MiB、NativeImport Swift shard 约 0.97 MiB、主 Bridge Swift 约 0.83 MiB；Bridge 共编译 5 个源文件、约 1.87 MiB，产生约 4.40 MiB object。

## Stage 1 实测结果

第一阶段没有缩减 Demo 源码或原生 API 发现范围，只增加精确的可复用事实和按内容发布。
下面是同一台机器上的单次实测，不代表跨机器指标或 P95：

| 工作流 | 首次构建 | 源码不变立即重构建 | 结果 |
| --- | ---: | ---: | --- |
| Live Reload Debug | 42.38 s | 12.15 s | Prepare 从优化前基线的 29.144 s 降到 1.252 s；frontend receipt 从 28.111 s 降到 0.237 s |
| Hot Patch Release | 62.51 s | 8.26 s | Prepare state 命中耗时 0.154 s，Bridge state 命中耗时 0.343 s |

优化后的 Live Reload frontend key 只检查源码直接使用的 5 个非 SDK 输入，共 533
字节，不再扫描 Xcode 搜索目录中的无关产物。无变化重构建没有再执行 Typed AST、SIL
或 symbol graph。Live Reload 仍需领取一次性的 Hub invitation，因此会话合同源码每次
都会变化；当前尚未切换到通用 Invoker 的 Bridge 仍需编译 5 个文件（约 1.96 MiB），
本次耗时 5.196 s。不过按内容发布已复用 15 个未变化文件，只重写 3 个会话相关文件。
Hot Patch 输入稳定，重复构建既没有重新生成 frontend，也没有重新编译 Swift/C Bridge。
两条快速路径返回前都重新验证了完整输出 manifest。

## 已确认的瓶颈与阶段结论

这组证据说明瓶颈不在文件发布，也不应通过删减 API 覆盖来解决：

1. 最大成本是每次 Prepare 都重新展开相同 SDK 调用面，包括 symbol graph、候选生成、递归二分探测和重复 SDK identity 查询。
2. 源码没有变化时，仍会重新生成约 3.6 MiB Shell、重新编译约 1.87 MiB Bridge 源码。
3. Hot Patch 与 Live Reload 都会重新获取相同的工具链、SDK、frontend 与归档事实，后续应共享内容寻址缓存，而不是各自维护一套猜测式快路径。

Stage 1 已在对应缓存 key 中纳入工具链、SDK build、target、minimum OS、语义参数、
输入内容 hash 和生成器版本；只复用经过验证的确定性事实与产物；未命中时完整回退到
权威 frontend；相同字节不重写。这个优化没有降低未来原生 API 的覆盖目标。
转换指纹也覆盖生成 Interface 与 NativeCall Descriptor 的语义；工具更新后会自动让
旧的本地事实失效，不要求开发者手工清理 DerivedData，也不需要修改协议版本。

剩余的结构性成本来自生成调用面的体积：Live Reload 会话可能改变 Bridge 输入，真正
miss 时编译大量固定 Swift wrapper 仍然昂贵。后续由 descriptor 驱动的 Objective-C/C
通用调用器和可缓存 Swift Adapter Pack 会解决这部分成本，同时不会重新引入手工 API
白名单。

## Stage 3 实测结果

Objective-C 通用执行阶段使用真实 Demo 做了 8 代连续 Live Reload。测试在同一个模拟器
进程中覆盖了 view hierarchy 修改、按钮配置、动画 completion、页面 present、dismiss
以及恢复基线。最终 Shell 一共有 479 条 NativeImport，其中 388 条复用同一个
Objective-C Invoker，87 条保留精确生成的 Swift Adapter，另有 4 条 builtin factory。

这个结果证明，落在支持矩阵内的 Objective-C selector 已经不会再各自生成一段 Swift
调用函数。同时，实测也明确暴露了下一处结构性成本，没有把它包装成已经解决：

| 实测项 | 结果 |
| --- | ---: |
| Descriptor 缓存失效后的冷 Prepare | 27.320 s |
| 冷 Prepare 中的 Managed Debug 展开 | 21.020 s |
| 当次 Bridge 总耗时 | 13.844 s |
| Bridge 中的 Swift 编译 | 13.017 s |
| 同一 Hub 会话内缓存预热后的无改动 Prepare | 2.085 s |
| 立即无改动 Bridge | 13.779 s |
| 生成的 Swift 源码总量 | 3,164,111 bytes |
| 主 Bridge 文件 | 2,825,004 bytes |
| NativeImport shards | 约 202 KiB |

预热后的 Prepare 没有再执行 Typed AST、SIL 或 symbol graph；frontend lookup 为
0.286 s，materialize 为 1.626 s。Bridge 仍然 miss，是因为每次构建都会生成新的 Live
Reload session contract，导致 3.1 MB 源码再次编译。现在主要体积来自主 Bridge 中较为
冗长的 Descriptor literal，而不是逐 selector 的可执行 wrapper。因此，本阶段改善了
执行架构并保留了覆盖能力，但没有声称已经达到最终无改动延迟目标。下面的 Stage 4
会把稳定 Bridge/Adapter Pack object 与一次性 Hub contract 拆开。

## Stage 4 实测结果

受限 C Invoker 与 Swift Adapter Pack 使用同一套真实 Simulator Demo 验证。Demo 中两类
不改变界面行为的探针会强制走完两条非 Objective-C 路径：`CACurrentMediaTime()` 使用
通用 C Invoker；两个 Foundation value-overlay 操作形成一份包含两个 entry 的
Foundation Adapter Pack。最终 Shell 报告 383 条 Objective-C Invoker、1 条 C Invoker、
84 条 application adapter 和 1 份可复用 Adapter Pack。

第一次 Bridge Build 使用新的 transform identity，因此会填充两层 object cache：

| 第一次 Bridge 项目 | 结果 |
| --- | ---: |
| Bridge 总计 | 17.044 s |
| 稳定 application Swift 编译 | 15.360 s |
| Application Bridge object | 6,978,432 bytes |
| Foundation Adapter Pack object | 22,008 bytes |
| 本次会话 Hub contract 编译 | 0.336 s |
| 最终 relocatable link | 0.170 s |

紧接着执行一次源码不变的 Xcode Build。因为它领取了新的一次性 Hub invitation，最终
Bridge 的精确 state 按设计 miss；但稳定部分没有重新编译：

| 重复 Bridge 项目 | 结果 |
| --- | ---: |
| Bridge 总计 | 1.353 s |
| Application object cache | hit |
| Adapter Pack object cache | hit |
| `bridge.compile_application_swift` | 报告中不存在 |
| 本次会话 Hub contract 编译 | 0.364 s |
| 最终 relocatable link | 0.064 s |
| 预热后的 Prepare | 2.366 s |

在这台测试机上，重复 Bridge 因此省掉了 15.360 秒，同时没有复用旧邀请码，也没有缩减
SDK API 发现范围。会话合同单独编译成一个很小的 object，再与已验证的稳定 application
object 和各 module Pack object 一起链接。最终 state identity 仍覆盖全部生成源码、
Pack key、compiler input、module map、toolchain、SDK、Clang binary 与 bootstrap source；
只有能够独立证明安全的中间 object 才会复用。

当前剩余 Bridge 成本主要是 import 扫描（0.348 s）、小 Hub-contract Swift 编译
（0.364 s）以及 toolchain/Pack 规划。它们已经变成次要且有界的成本，不再构成缩减 SDK
覆盖范围的理由。所有缓存和报告 schema 继续保持版本 1。

## Stage 5 Catalog-first 稳态实测

2026-08-28 又在真实 arm64 iPhone 17 Simulator destination 上测量了最终
Catalog-first 接入。后台预热已经发布 2 个 module、4,609 条 entry 的完整能力面后，使用
新 transform identity 的第一次构建填充当前 Shell 与 object：Prepare 为 15.505 秒，
其中 Catalog 读取及完整校验 1.905 秒、application frontend 4.691 秒、紧凑 Shell
materialize 7.834 秒；Bridge 为 1.961 秒，其中 application Swift object 编译 0.784 秒、
两份 Adapter Pack object 物化 0.370 秒。紧接着的源码不变构建进入稳定状态：

| 稳态 Live Reload 项目 | 结果 |
| --- | ---: |
| Xcode Build 墙钟 | 约 14.3 s |
| Prepare 总计 | 0.179 s |
| Prepare state | 命中 |
| Catalog 读取 / application frontend / Shell materialize | 未发生 |
| Bridge 总计 | 0.421 s |
| Bridge state | 命中 |
| Application 与 Adapter Pack 编译 | 未发生 |

尚未消费的一次性 Hub reservation 可以由精确 state hit 安全复用；一旦被消费，或任何
语义输入变化，仍会走正常的会话相关路径。真实 Swift 6 Demo 预热生成了约 8.1 MiB 的
UIKit Catalog；同一 canonical job 从用户缓存精确复跑，包括完整 payload 与 projection
校验，耗时 1.911 秒。这些仍是本机单次观测，不是 P95，但足以证明分钟级 SDK 扫描已经
移出无变化 Xcode Build 的延迟路径。

## 模块 Catalog 冷生成证据

模块级 Catalog Producer 已经对当前安装的 iPhone Simulator SDK 中真实 UIKit 做过验证，
不是只跑小型人造 fixture。显式开启的集成测试从空的私有缓存开始，并要求最终 Catalog
确实包含 `UIView.backgroundColor`、`UIViewController.present` 与 `UIView.animate` 三条
精确 Objective-C 记录，以及
`UIActivityViewController.init(activityItems:applicationActivities:)` 的精确 MainActor
Swift Adapter。最近一次 2026-08-28 冷运行耗时 229.653 秒；增加该断言前，2026-08-27
的一次运行耗时 195.123 秒。这证明全 SDK 覆盖链路能成立，也证明冷索引本身代价很大；
它绝不是可接受的每次 Prepare 耗时，文档也不会把它写成普通构建性能。

顺序执行的早期版本运行约 5 分钟后被主动停止。改成最多 4 个 worker 的有界调度后，
采样到的测试进程 CPU 利用率从约 14% 提高到约 95%，内存占比仍约 2%；成功运行期间的
进程快照没有出现超过 4 个 frontend 子进程。常规测试还用 260 条 API 强制跨过 256 条批次
边界，在两个独立冷缓存中分别生成，并要求 Catalog 字节语义完全一致；记录的一次运行
耗时 2.503 秒。

UIKit 还暴露了小 fixture 没发现的两条正确性边界：不同 overlay 类型可能共享一个泛型
Swift SIL 实现，模块图也可能展示由其他模块声明的 protocol 默认实现。Catalog 现在用
owner、USR 与完整签名区分前者，并从错误模块中剔除后者；普通源码分析仍保持失败关闭，
Objective-C/C 模块权限也没有被放宽。真实 Swift 6 Demo 还证明，SDK 子类可能继承
MainActor 却不在自己的 Symbol Graph 行重复标注，历史 imported global 也可能被诊断为
并发不安全共享可变状态。前者会带着继承 actor 权限重新测量；后者只确定性拒绝该候选，
不会中止整个模块。

因此产品结论很明确：完整 SDK Catalog 只能按 SDK/模块身份做一次后台生成。Catalog-first
Prepare 必须读取经过验证的命中，或只对源码当前需要的 API 做小范围查询，绝不能把这次
约 230 秒扫描重新塞回每次本地构建。schema、协议、产物与产品版本全部继续保持 1。

## 最终 Hot Patch Release 证据

2026-08-28 还使用仓库内 Release Demo 和同一台 arm64 iPhone 17 Simulator 对最终实现
做了完整验收。发布出的 schema 1 capability manifest 含 3,657 条 entry。新 transform
identity 完成一次冷填充后，源码不变的 Release Build 中 Prepare state 命中耗时 0.406
秒，Bridge state 命中耗时 2.824 秒；当时磁盘仅剩约 469 MiB，完整 Xcode 调用耗时
20.83 秒。该次 Bridge 命中没有重新执行 Swift 编译。

把 Demo 中唯一标记的计价函数改为修复值后，生成、签名、验证并投递一条 entry 的补丁
共耗时 19.101 秒。安装后的 Release App 在 generation 1 把实际显示的运费从 `¥19.99`
改为 `¥0.00`，随后回滚又恢复到经过审计的原始实现。这证明紧凑的 Catalog-backed
manifest、通用调用器、生成式 Swift Adapter Pack、补丁编译器和运行时激活链在当前
schema 1 合同下能够端到端一致工作；这些仍是本机功能实测，不是跨机器延迟承诺。

## 2026-09-05 大模块索引实测

根据接入报告，新增了单模块 2,500 文件的合成基准，共 2,500 个 public 标量函数、
147,780 字节源码，没有外部 import。Helix 使用 arm64 macOS 上的 Debug 测试构建，
Apple Swift 6.3.3、Simulator SDK build `23F81a`，目标为
`arm64-apple-ios15.0-simulator`。每个场景单次运行，期间没有其他并发构建。
计时不含工具链发现和 fixture 创建；冷路径使用空的 Helix fixture 缓存，系统编译缓存
可能已经预热。

下表只比较 SIL resolver 复用前后：两次运行都已包含大参数重放与文件作用域身份修正。
CPU 采样发现，源码索引原本在每个声明上重建整个模块的 symbol/location 映射，并反复
解析文件路径。现在每个 SIL 模块只创建一次不可变 resolver，函数、属性、observer
共用它；建立索引时，每个不同源文件路径只解析一次。新增
`frontend.index_sil_functions` 阶段记录这次建立成本。

| Receipt 操作 | 复用前 | 复用后 |
| --- | ---: | ---: |
| 冷 receipt | 99.020 s | 12.884 s |
| 无改动 receipt 缓存命中 | 0.829 s | 0.828 s |
| 单个函数体修改，receipt miss | 100.116 s | 12.806 s |
| 冷路径中的源码声明索引子阶段 | 86.598 s | 0.439 s |

新的 resolver 建立耗时 0.036 秒。无改动命中没有启动编译子进程；每次 miss 均记录
7 次子进程调用，仍索引全部 2,500 个声明。Receipt 约 7.04 MB。回归测试检查命中/失效、
无改动 receipt 一致性、函数体变化触发失效和 root symbol 稳定性，已有负例继续验证
location 歧义会被拒绝。[可复现 fixture](../Tests/HelixBuildToolsTests/BuildToolsTests.LargeModulePerformance.swift)
可通过 `HELIX_LARGE_MODULE_REPORT` 导出精确工具链、阶段与子进程数据，中间测量文件
不作为仓库产物保存。

在仓库根目录复现大规模运行：

```sh
HELIX_LARGE_MODULE_SOURCE_COUNT=2500 \
HELIX_LARGE_MODULE_REPORT=/tmp/helix-large-module.json \
swift test --scratch-path .build/validation --filter LargeModulePerformance
```

常规测试使用 32 个文件；显式基准允许 2 到 5,000 个文件。这些数字衡量 frontend
receipt 生成，不包含完整 Xcode Prepare、Bridge 编译或保存到设备激活、UI 刷新的延迟。
148 KB 的标量 fixture 不能代表报告中商业模块的业务复杂度、100 个原生 import 和
240 MB compiler inputs。报告中的失败冷 Prepare 405.3 秒、typed AST 约 89 秒是接入方
观察，不能作为这个 fixture 的优化前数据。商业工程稳态保存和完整冷 Catalog 闭包
仍需要在该工程测量。已支持的暂停、续跑与本机缓存预热操作见
[增量构建事实](Incremental-Build-Facts.zh-CN.md#搜索路径与-catalog-预热续跑)。

后续解析优化在闭合派发重写前后复用声明记录，五个固定声明正则只编译一次。
用相同工具链再次运行同一 2,500 文件 fixture，冷 receipt 为 10.144 秒，函数体修改后
为 10.093 秒，无改动命中为 0.843 秒。Identity 与 semantic SIL 解析各约 1.93 秒，
上表运行时各约 3.30 秒。这仍是同一 receipt 测量边界内的单次 Debug 构建观察。
`CompilerTests.ModuleParsing` 覆盖 factory body 替换和多个模块的并发解析。

## 大量依赖的输入规划

2026-09-05 的规划 fixture 创建 100 个 framework 目录，每个包含 20 个头文件和一个
module map，共 2,100 个输入文件、4,137,190 字节。同机 Debug Helix 构建下，规划
100 个模块身份耗时从目录记录复用和路径筛选优化前的 14.034 秒降到 2.560 秒。
前后 100 个模块的内容 hash 全部一致；回归测试还逐个对照独立重新捕获的身份。

这里只计时 Catalog 输入规划，fixture 创建、首次整体输入捕获和参考结果校验均不在
计时内，没有编译依赖或生成其 API Catalog。这是单次观察，不代表商业工程完整
240 MB 输入集。目录创建/删除、子目录变化、权限变化、目录链接、内容修改和保留数量
上限都有单独回归覆盖。

```sh
HELIX_DEPENDENCY_MODULE_COUNT=100 \
HELIX_DEPENDENCY_PLANNING_REPORT=/tmp/helix-dependency-planning.json \
swift test --scratch-path .build/validation --filter DependencyPlanning
```

常规测试使用 8 个模块，显式测量接受 1 到 256 个。Fixture 位于
[BuildToolsTests.DependencyPlanning](../Tests/HelixBuildToolsTests/BuildToolsTests.DependencyPlanning.swift)。

## 可恢复编译阶段的成本

加入经过验证的编译检查点后，再次运行相同的 2,500 文件标量 fixture。本机冷 receipt
为 10.532 秒，无改动命中 0.892 秒，正文修改后 miss 为 10.577 秒。每次 miss 记录六次
子进程，完整 receipt 保存后清理全部三个中间 payload；无改动命中不启动子进程。
本次单次观察接近此前 parser 优化后的 10.144/0.843/10.093 秒。检查点主要降低失败
重试的成本，不减少冷编译本身的工作。

`BuildToolsTests.CompilerCheckpoints` 使用真实编译器完成三个阶段，再故意触发源码
value 与原生 codec 的冲突；仅修正该配置后，要求三个检查点全部命中、不重复发起
AST/SIL 编译，并将恢复的 receipt 与完整无缓存结果逐项比较。输入改变、非法输出、
数据损坏、条目被锁和符号链接另有回归覆盖。这些证据不等同于商业工程约 380 秒的
失败 Prepare 实测。

## 真实系统框架混合接入

2026-09-05，系统框架 fixture 在同一模块中编译并生成通过校验的 receipt，包含
Foundation、UIKit、AVFoundation 与 Photos。配置同时覆盖限定/非限定 `Progress`、
Objective-C bridging header、`gnu++20` C++ interoperability、`@TaskLocal` 宏、
implicit dynamic replacement，以及开启 explicit modules 的初始 driver 编译。
目标为 `arm64-apple-ios15.0-simulator`，iPhone Simulator SDK build `23F81a`，
Swift 6.3.3。每次测量使用空的私有 Helix 缓存，不清空系统或工具链缓存。

| 源码文件数 | 源码字节 | 初始 explicit-module 编译 | 冷 receipt | 无改动 receipt 命中 |
| --- | --- | --- | --- | --- |
| 32 | 4,014 | 7.118 秒 | 16.956 秒 | 0.016 秒 |
| 2,500 | 280,628 | 7.385 秒 | 30.010 秒 | 0.924 秒 |

两次均要求 warm receipt 与 cold 相同，且 warm 不启动编译子进程。大档记录
2,504 declarations、6 native types、4 native imports、三个生成并清理的 checkpoint，
以及四个声明模块的 symbol graph。这些是源码按需 SDK 查询，不是四个完整 Native API
Catalog，也不代表 100 模块冷预热、商业工程保存到屏幕延迟、Bridge 链接或真机激活。

该 fixture 额外发现：含 bridging PCH job 时，Swift driver 把 `-o -` 的 SIL 写入 stderr。
现改为读取明确指定的私有 SIL 文件，分析前验证 canonical header。混编回归覆盖两个 SIL
入口，没有输出时立即报错。

```sh
HELIX_SYSTEM_FRAMEWORK_SOURCE_COUNT=2500 \
HELIX_SYSTEM_FRAMEWORK_REPORT=/tmp/helix-system-frameworks.json \
swift test --scratch-path .build/validation --no-parallel --filter SystemFrameworkIntegrationTests
```

常规测试使用 8 文件；测量接受 2 至 2,500 文件。JSON 保存 SDK/toolchain 身份、target、
耗时和 cold trace。安装、编译器包装器合同及当前资源上限见
[大型工程接入](Large-Project-Integration.zh-CN.md)。

## SIL 调试元数据扫描

2026-09-07 使用固定的合成 SIL 文本（14,211,961 UTF-8 字节、120,000 条指令行、
30,000 个含位置的 scope、2,500 个文件映射），在 Apple M4（10 个逻辑 CPU、16 GiB 内存）上，以 Swift 6.3.3、`swiftc -O` 测量。
独立 harness 编译实际 `CanonicalSIL.DebugMetadata` 源码，仅以最小 stub 提供位置和
错误类型。每个操作在单进程内运行五次，下表为中位值；每次的结果数量/校验和一致。
原始输入、harness、源码快照和测量值保存为仓库外验收证据。

| 操作 | 优化前 | 优化后 | 降幅 |
| --- | ---: | ---: | ---: |
| 源码模块映射 | 221.229 ms | 177.750 ms | 19.7% |
| Debug scope | 278.743 ms | 266.322 ms | 4.5% |
| 指令元数据 | 447.516 ms | 272.310 ms | 39.1% |

优化包括按前缀跳过无关行、按 UTF-8 分隔符扫描注释、跳过未转义路径的解码，以及对
尾部锚定正则只取一次匹配。scope 继承另外改为迭代遍历，记忆不存在的位置；独立的
30,000 层长链回归覆盖含位置、不含位置及循环诊断。表中测量含位置的 scope，并非
此前无位置长链产生的平方级开销。

这些数据只隔离解析操作，不含编译器发射、AST 发现、Catalog 生成、Bridge 编译、传输
或激活，不能作为商业工程冷构建或保存到生效延迟。模块共享事实仍按完整编译输入失效，
不意味着按文件 WMO 缓存或并行 frontend 发射已实现。

现有两组 2,500 文件集成基准也在同一 Swift/SDK 下重新运行。标量样板（147,780 字节）
冷 receipt 9.240 秒、不变命中 0.804 秒、单个函数体修改后 9.256 秒。混合系统框架样板
（280,761 字节）explicit-module 编译 7.509 秒、冷 receipt 30.155 秒、不变命中
0.944 秒。每份源码仍包含在 receipt 中，热命中不发射 AST/SIL。这些是当前回归观测，
并非与此前源码/配置不同的运行进行隔离性能对比。

## 导入类型别名归一化（第六轮）

冷 Catalog 回归采样显示，导入 nominal 合并反复扫描全量观察记录。Catalog 别名匹配
改为按每个精确名称建索引，从最小候选集合开始，仍保留所有竞争事实，并执行完整的
别名包含关系和表示校验。Clang 别名归一化为精确 canonical name 建索引；名称
改变时同步更新索引，保留按顺序处理别名链的原有语义。不会仅凭短名称推断身份。

同一 macOS debug 测试配置下，8,000 条合成观察记录（2,000 组 Catalog 对和 2,000 组
Clang 对）在改动前后均产出相同的 4,000 个类型，canonical 输出 hash 完全一致。
三次合并的中位耗时从 23.741 秒降至 0.228 秒，约 104 倍。输入逆序和重复合并同样通过。
这是该合并步骤的测量，不是整个 Prepare、冷 Catalog、商业工程或 save-to-active
的提速结论。普通回归默认 128 组；设置 `HELIX_ALIAS_TYPE_COUNT=2000` 和
`HELIX_ALIAS_REPORT=/absolute/path/report.json`，配合
`--filter measuresAliasNormalization` 可重跑较大基准。原始本地证据不放入仓库。
Identity SIL 与 semantic SIL 仍是用途不同的 compiler 产物，本次优化不混用两者。
