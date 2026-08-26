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

剩余的结构性成本来自生成调用面的体积：Live Reload 会话可能改变 Bridge 输入，真正
miss 时编译大量固定 Swift wrapper 仍然昂贵。后续由 descriptor 驱动的 Objective-C/C
通用调用器和可缓存 Swift Adapter Pack 会解决这部分成本，同时不会重新引入手工 API
白名单。
