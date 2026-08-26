# 原生调用身份与 Catalog

本文记录 Helix 已实现的版本 1 原生调用基线：HLBC 要调用 App 中已有代码时，如何描述这次调用、如何确定稳定身份，以及每一层如何验证权限。这里不会把后续能力提前写成已经完成：稳定 Descriptor、Key、Catalog、Archive、Bytecode、Verifier 与 Runtime 合同已经落地；Objective-C/C 通用调用器和可复用 Swift Adapter Pack 会在后续阶段接入。

## 两种 ID，各做一件事

`NativeCall.Key` 是一条原生 API 调用的稳定身份。Helix 先把 `NativeCall.Descriptor` 规范化，再使用 `HLX.NativeCall.v1` hash domain 计算 SHA-256。项目 namespace、Shell build number、本次表中的位置、执行时限和运行策略都不参与计算。因此，只要 Descriptor 一样，在不同项目或构建中得到的 Key 就一样。

`NativeImportID` 只是某一个 Shell 或 HLBC image 中从 0 开始的紧凑表下标，用来缩小 Bytecode 和 Runtime 表。它本身不是权限。Patch 中每条 import 还必须携带稳定 Key、完整 Descriptor、Contract 和 Capability。

## Descriptor 具体记录什么

一份规范化 Descriptor 包含：

- backend、module、owner、member、entry point、派发方式，以及明确的 instance receiver 参数；
- Swift 逻辑参数和返回值、参数 label、ownership、闭包生命周期、autoclosure、throws、async 和 isolation；
- 物理调用约定、ABI value 类型、原生 encoding 和 layout、Swift direct/guaranteed/indirect convention、默认参数来源和错误约定；
- effect 与各平台 availability。

Helix BridgeSlot 的 ownership 与底层原生调用 convention 是两回事。例如，一个值可以由 Helix 以 owned 方式持有，但底层 Swift 方法使用 `@in_guaranteed` 接收。现在编译器 ownership 标记不会再混在类型字符串里，而是单独保存在 ABI convention 字段中，避免两种不同的机器调用方式被误认为同一个 Key。

Descriptor 规范化会限制文本和数组大小、统一 Swift 类型写法、检查括号是否平衡、验证 layout 和 encoding、要求 receiver 与参数投影完整，并确保闭包生命周期信息没有缺口。`Optional.none` 默认值只能投影到 nullable 或 Swift Optional ABI 参数。Objective-C 和 C 描述也不能伪装成 Swift typed adapter。

`NativeImportContract` 不参与 API 身份计算。它负责执行时限、是否允许主线程、访问级别和闭包权限等策略；只调整时限不会给同一个 API 换 Key。但在每一个信任边界，Descriptor 与 Contract 仍然必须一起验证。

## Native API Catalog

`NativeAPICatalog.Document` 是 Helix 自动维护的模块 API 快照，使用 canonical JSON。项目开发者不需要手写。它的缓存身份包含：

- 来源、Xcode product build、SDK product build、编译器指纹；
- target triple、最低部署版本、Swift language mode；
- 模块内容、module search path 和依赖图 hash；
- Catalog rules version，目前仍为 1。

每条记录包含稳定 Key 与 Descriptor、策略 Contract、Swift 查找名称、编译器符号、支持状态或准确拒绝原因，以及一种执行绑定。受支持的绑定必须声明目标 module。通用调用器不能偷偷挂一个逐 API Adapter ID；Swift 和 builtin 绑定则必须有稳定 Adapter ID。

Codec 会拒绝超大或非 canonical JSON。不可变 Registry 会拒绝“同一个缓存身份对应两份不同内容”，也会拒绝两个 Catalog 对同一个 Key 给出不同记录；重复加载同一快照是幂等的。Registry 可以按稳定 Key、Swift 名称、编译器符号和原生 entry point 查询，而且所有索引最终都回到同一份 Descriptor。

## 从 Patch 到 Runtime 的验证链

Release Archive 保存完整 Descriptor 和 Contract；设备投影保留相同调用权限，但不携带只在构建期使用的编译器符号。HLBC import requirement 再次写入 Key、Descriptor、Contract 和 Capability。Shell interface 与 Runtime registry 同时保留紧凑下标和稳定 Key。

真正执行前必须同时满足：

1. 紧凑下标确实存在于已安装 Shell；
2. Runtime policy 允许该稳定 Key；
3. Patch 与 Shell 中的 Descriptor、Contract、Capability 完全一致；
4. 根据 Descriptor 重新计算出的 Key 与记录值一致；
5. 逻辑类型、effect、闭包生命周期和物理参数投影内部一致。

重复下标和重复稳定 Key 都会被拒绝。诊断会携带稳定 Key；Source Map 可用时还会指出原始 Swift 文件、行和列。运行日志不再只能依赖某次构建临时分配的整数来定位 API。

## 当前执行边界

本阶段仍由现有的精确签名 Swift NativeImport factory 执行已经捕获的 Framework 和 App 调用。新的 Descriptor 与 Key 已经替换原先依赖项目 namespace 的身份，并贯穿 Archive、Bytecode、Verifier、Bridge 生成、Runtime 和 Patch BuildContract。Catalog 已经成为共用解析模型，但仅有一条 Catalog 记录还不能让从未安装过的 Objective-C、C 或纯 Swift 调用自动执行；后续通用调用器与 Adapter Pack 阶段仍需为它安装匹配 binding。

产品、协议、Catalog、Archive 和 Bytecode 版本全部保持为 1。
