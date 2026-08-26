# 原生调用身份与 Catalog

本文记录 Helix 已实现的版本 1 原生调用基线：HLBC 要调用 App 中已有代码时，如何描述这次调用、如何确定稳定身份，以及每一层如何验证权限。这里不会把后续能力提前写成已经完成：稳定 Descriptor、Key、Catalog、Archive、Bytecode、Verifier 与 Objective-C 通用消息调用器已经落地；受限 C 调用器和可复用 Swift Adapter Pack 会在后续阶段接入。

## 两种 ID，各做一件事

`NativeCall.Key` 是一条原生 API 调用的稳定身份。Helix 先把 `NativeCall.Descriptor` 规范化，再使用 `HLX.NativeCall.v1` hash domain 计算 SHA-256。项目 namespace、Shell build number、本次表中的位置、执行时限和运行策略都不参与计算。因此，只要 Descriptor 一样，在不同项目或构建中得到的 Key 就一样。

`NativeImportID` 只是某一个 Shell 或 HLBC image 中从 0 开始的紧凑表下标，用来缩小 Bytecode 和 Runtime 表。它本身不是权限。Patch 中每条 import 还必须携带稳定 Key、完整 Descriptor、Contract 和 Capability。

## Descriptor 具体记录什么

一份规范化 Descriptor 包含：

- backend、module、owner、member、entry point、派发方式，以及明确的 instance receiver 参数；
- Swift 逻辑参数和返回值、参数 label、ownership、闭包生命周期、autoclosure、throws、async 和 isolation；
- 物理调用约定、ABI value 类型、原生 encoding 和 layout、Swift direct/guaranteed/indirect convention、默认参数来源和错误约定；
- Objective-C backend 使用的 runtime class、method family、词法 superclass、property accessor 身份，以及受支持的 `NSError **` 失败约定；
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

## Objective-C 通用执行路径

如果编译器已经证明一条 Objective-C 声明的逻辑类型和物理类型落在支持矩阵内，它会直接绑定到同一个 `Runtime.ObjectiveCInvoker`。Bridge Generator 只输出结构化 Descriptor，不再为每个 selector 生成一段 Swift wrapper。当前通用矩阵包括 Objective-C object/Optional object、精确位宽的整数和浮点数、`Bool`、常见 CoreGraphics/UIKit struct、属性、实例/类方法、initializer、受支持的 `NSError **` 导入，以及一组可复用的同步 Objective-C Block 形状。无法证明表示等价的 Swift value overlay 仍然走精确生成的 Swift Adapter。

模块归属不会根据 `UI`/`NS` 前缀或 class 所在模块猜测。普通方法和属性会用精确 Clang USR 查询已导入模块索引，因此 category 可以属于另一个 Framework；继承 initializer 则以 Swift 构造表达式的具体 class 模块为准，实际分配该具体类型，而不是错误地分配 `init` 声明所在的 superclass。归属不唯一时继续走 Swift Adapter。

自定义 Objective-C 属性 accessor 还必须通过编译器 `#selector` 探针恢复精确 getter 或 setter，不能从 Swift 源码名称猜 selector。Descriptor 会把“API 声明 class”和“类消息/初始化实际派发 class”分开记录。例如，继承来的 `UIButton.setAnimationsEnabled` 以 `UIView` 声明做权限和 ABI 校验，但类消息仍发给 `UIButton`；继承来的 `UIViewController()` 在 `NSObject` 上解析 `init`，实际分配的仍是 `UIViewController`。两种身份都会进入稳定 Key。只有 Typed AST mangling 能精确证明源码 metatype 或构造结果时，Compiler 才使用这条通用路径；否则保留 Swift Adapter。

普通 Objective-C 动态派发与词法 `super` 派发也使用不同的稳定调用身份，方法和属性都
一样。编译器会把 Typed AST 表达式对应到唯一的 SIL 指令，只为 `super` 记录词法父类。
证据缺失或存在歧义时，Helix 会拒绝该通用路径或保留精确 Swift Adapter，绝不会悄悄
把 `super` 调用降级成动态派发。

Swift 层先把已经验证的 VM value 和 callback 权限投影成 ABI slot；一个很小的 Objective-C shim 再到 Catalog 指定的声明 class（或已固定的词法 superclass）上解析精确 selector，逐项比较运行时 type encoding 和 storage kind，并验证另行记录的 class 派发目标确实继承该声明 class，然后通过 `NSInvocation` 调用实际 receiver。这样既保留普通 Objective-C override 的动态派发，也不会让只存在于意外动态子类上的 selector 扩张 Catalog 权限。receiver 继承关系直接从 Objective-C runtime 的真实 class hierarchy 读取，不依赖可被对象重写的 `isKindOfClass:`；普通动态 override 的完整 ABI 也必须与目录声明一致后才能执行。属性调用直接使用编译器已经证明的 accessor selector，不要求系统运行时一定保留可选的 Objective-C property metadata；UIKit 等系统 Framework 即使裁掉这类元数据也能正常调用。Shim 还会捕获 Objective-C exception，处理 initializer 与 retained/autoreleased method family，并在一个明确的 ownership 边界把 object result 交回 Swift。Runtime 解码前会再次检查 receiver class、平台 availability、nilability、struct encoding/size/alignment、deadline、MainActor 入口、临时存储上限和返回长度。

这条路径消除了受支持 Objective-C 调用的逐方法可执行 Bridge，但它绝不是任意 selector 入口：每次调用仍必须对应当前 Shell 已发出的精确 Descriptor。源码已经出现的调用和当前 managed Debug SDK surface 现在可以使用通用 binding；仅仅因为 Runtime 有通用调用器，并不会让当前 Shell 中从未发出的公开 API 自动获得权限。完整的 Catalog 开发期查询和签名 Release capability 投影在后续阶段完成。C 调用与复杂纯 Swift 调用在 C Invoker 和 Adapter Pack 落地前，也仍需要现有的精确 binding。

产品、协议、Catalog、Archive 和 Bytecode 版本全部保持为 1。
