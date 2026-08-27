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
