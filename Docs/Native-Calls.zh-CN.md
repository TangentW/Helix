# 原生调用身份与 Catalog

本文记录 Helix 已实现的版本 1 原生调用基线：HLBC 要调用 App 中已有代码时，如何描述这次调用、如何确定稳定身份，以及每一层如何验证权限。稳定 Descriptor、Key、Catalog、Archive、Bytecode、Verifier、Objective-C 通用消息调用器、受限 C 调用器与可复用 Swift Adapter Pack 都已经落地；基于 Catalog 的开发期按需 Adapter 已用于认证后的 Simulator/macOS Live Reload，生产 `NativeCapability.Manifest`、签名补丁绑定与设备侧校验也已经落地。

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

## Release Native Capability Manifest

Release Prepare 使用受管生产调用面策略。它会把本次成功 App 构建已经证明的 imported native type 边界内，所有经编译器逐项验证合格的 Catalog 候选自动发布出去；项目不需要维护 API 白名单。baseline 已使用项和这批候选共同形成唯一的 schema 1 `NativeCapability.Manifest`，每条记录都有连续紧凑 ID、精确 Key、Descriptor、Contract 与 required capability。

这个范围以编译证据为准：它覆盖 App frontend 已经证明、完整 Bridge 类型和 ABI 均可表示的 imported native type 成员，以及已证明的具体泛型 specialization。它不是“所有已链接 Framework 的任意声明”通配符，也不会凭空加入新的 boundary type、开放泛型 specialization、任意 selector、C symbol 或 Swift ABI 调用。补丁可以第一次使用已发布 Manifest 中的任意 entry；不存在完全一致的 entry 时，Patch Compiler 会直接说明需要正常发布新版 App。

生成 Bridge 会根据代码签名保护的 Shell 表重建同一份 Manifest；Prepare 同时输出 canonical `NativeCapabilities.json` 供审计。Release finalize 会把它与最终 Archive 独立比对，并将 SHA-256 固定到 Release baseline。每个签名补丁 target 还会同时携带 Manifest hash、Shell interface hash 与 Mach-O UUID，所以能力内容或 Release 身份只要有一处变化，target 验证就会失败。

生产 Runtime 安装前，Helix 要求 Manifest、Shell 以及不可变的同步/异步 Registry 在条目集合和条目内容上完全一致。Objective-C entry 还会在当前设备重新解析声明 class、selector、派发目标、参数个数与完整 runtime type encoding。C runtime 没有同等的签名反射能力，因此它会验证编译期绑定地址、有限 trampoline 配置、availability 与 policy，绝不接受补丁提供的 pointer 或 signature。设备 ABI 首次成功后会为该 Runtime Engine 固定唯一 Manifest hash 并复用证据；换成另一份 hash 会被拒绝，结构一致性每条入口仍会检查，失败也不会进入缓存。

## Objective-C 通用执行路径

如果编译器已经证明一条 Objective-C 声明的逻辑类型和物理类型落在支持矩阵内，它会直接绑定到同一个 `Runtime.ObjectiveCInvoker`。Bridge Generator 只输出结构化 Descriptor，不再为每个 selector 生成一段 Swift wrapper。当前通用矩阵包括 Objective-C object/Optional object、精确位宽的整数和浮点数、`Bool`、常见 CoreGraphics/UIKit struct、属性、实例/类方法、initializer、受支持的 `NSError **` 导入，以及一组可复用的同步 Objective-C Block 形状。无法证明表示等价的 Swift value overlay 仍然走精确生成的 Swift Adapter。

模块归属不会根据 `UI`/`NS` 前缀或 class 所在模块猜测。普通方法和属性会用精确 Clang USR 查询已导入模块索引，因此 category 可以属于另一个 Framework；继承 initializer 则以 Swift 构造表达式的具体 class 模块为准，实际分配该具体类型，而不是错误地分配 `init` 声明所在的 superclass。归属不唯一时继续走 Swift Adapter。

自定义 Objective-C 属性 accessor 还必须通过编译器 `#selector` 探针恢复精确 getter 或 setter，不能从 Swift 源码名称猜 selector。Descriptor 会把“API 声明 class”和“类消息/初始化实际派发 class”分开记录。例如，继承来的 `UIButton.setAnimationsEnabled` 以 `UIView` 声明做权限和 ABI 校验，但类消息仍发给 `UIButton`；继承来的 `UIViewController()` 在 `NSObject` 上解析 `init`，实际分配的仍是 `UIViewController`。两种身份都会进入稳定 Key。只有 Typed AST mangling 能精确证明源码 metatype 或构造结果时，Compiler 才使用这条通用路径；否则保留 Swift Adapter。

普通 Objective-C 动态派发与词法 `super` 派发也使用不同的稳定调用身份，方法和属性都
一样。编译器会把 Typed AST 表达式对应到唯一的 SIL 指令，只为 `super` 记录词法父类。
证据缺失或存在歧义时，Helix 会拒绝该通用路径或保留精确 Swift Adapter，绝不会悄悄
把 `super` 调用降级成动态派发。

Swift 层先把已经验证的 VM value 和 callback 权限投影成 ABI slot；一个很小的 Objective-C shim 再到 Catalog 指定的声明 class（或已固定的词法 superclass）上解析精确 selector，逐项比较运行时 type encoding 和 storage kind，并验证另行记录的 class 派发目标确实继承该声明 class，然后通过 `NSInvocation` 调用实际 receiver。这样既保留普通 Objective-C override 的动态派发，也不会让只存在于意外动态子类上的 selector 扩张 Catalog 权限。receiver 继承关系直接从 Objective-C runtime 的真实 class hierarchy 读取，不依赖可被对象重写的 `isKindOfClass:`；普通动态 override 的完整 ABI 也必须与目录声明一致后才能执行。属性调用直接使用编译器已经证明的 accessor selector，不要求系统运行时一定保留可选的 Objective-C property metadata；UIKit 等系统 Framework 即使裁掉这类元数据也能正常调用。Shim 还会捕获 Objective-C exception，处理 initializer 与 retained/autoreleased method family，并在一个明确的 ownership 边界把 object result 交回 Swift。Runtime 解码前会再次检查 receiver class、平台 availability、nilability、struct encoding/size/alignment、deadline、MainActor 入口、临时存储上限和返回长度。

这条路径消除了受支持 Objective-C 调用的逐方法可执行 Bridge，但它绝不是任意 selector 入口：每次调用仍必须有编译器证明的精确 Descriptor。已链接 Shell 用紧凑 ID 保存实际使用项，认证 Build Receipt 则保存尚未使用的受管开发候选。开发代码第一次使用候选时，Compiler 会在已链接前缀之后确定性分配 session-local ID，App 再从 Descriptor 构造同一个通用 Invoker；Shell interface hash 不会变化。这种 Registry 增长只允许发生在认证开发事务中，生产环境仍只能使用随 Release 发布的能力 Manifest。

## 受限 C 通用调用路径

当编译器证据能够证明物理 ABI 落在支持矩阵内时，imported C function 不再需要每个 symbol 各生成一个执行器。发现阶段会记录声明的 Clang USR、所属 module、精确 C entry point、逻辑 Swift signature、calling convention、layout、effect 与 availability。生成 Bridge 会直接取得这个已导入声明的 `@convention(c)` 函数地址，再交给同一个 `Runtime.CInvoker`；Runtime 不会拿源码字符串去进程里搜索 symbol。

实现使用有限、预先编译的 trampoline 矩阵，而不是 `dlsym`、`libffi`、由 Descriptor 驱动的 `unsafeBitCast` 或调用方提供的任意 pointer。生成 Bridge 只会把已经通过 Swift 编译器精确类型检查的 imported `@convention(c)` function 做一次地址擦除；它不会借此凭空构造调用签名。当前矩阵覆盖最多四个参数的有界同类标量调用，以及 Bridge 明确验证的常见 Apple geometry value shape。真正调用前会逐项检查 calling convention、字节宽度、alignment、参数个数、结果 shape、availability、deadline 与 MainActor 入口。混合 ABI、variadic、pointer、间接结果、throwing、callback 或其他陌生形状会保留精确 Swift Adapter，或明确拒绝，绝不会猜测执行。

开发期第一次使用 C API 时，只有“地址绑定”这一步不同：认证编译器先选中 Receipt 中的精确候选，App 才可以按该 Descriptor 固定的 C entry point 在当前已链接进程中解析地址，再交给同一套有限 `Runtime.CInvoker`。Patch 字节不能提交任意 symbol 或 ABI；Descriptor/Key 重算、SDK/target 身份、进程链接状态和 Runtime ABI 检查必须全部通过。Release 路径仍使用发布 Bridge/能力表在构建时绑定的地址。

真实 UIKit Demo 保留了一次不改变行为的 `CACurrentMediaTime()` 探针，因此普通 Xcode Build 会完整经过 C Descriptor、精确函数地址、通用 Runtime Invoker、MainActor policy、返回值解码与最终 object link。

## 可复用 Swift Adapter Pack

需要 Swift 语义的调用，例如 value overlay 或通用调用器矩阵以外的 ABI，仍然必须由 Swift Compiler 生成。现在 Helix 会按声明的稳定 Swift USR 与原生 module 分类，把同一 module 的条目归入一份确定性的 Adapter Pack，并按 `NativeCallKey` 排序。大型 application Bridge 只引用稳定 C ABI factory；每个 factory 返回类型擦除后的同步或挂起 native adapter body，真正的 Swift 调用仍留在对应原生 module 的编译上下文中。

Pack source 与 Pack object 是两层独立的内容寻址事实。source identity 包含 compiler、SDK、target、deployment、transform 环境、module、精确有序的 imported module 集合和精确有序 Key；object identity 另外包含工具链二进制、Xcode build、规范化编译参数、完整非 SDK compiler-input 快照、module map 与 source hash。缓存 object 每次 materialize 都会重新校验 Mach-O 架构和平台；损坏条目会隔离并重建。不同 module 的 Pack 分别编译，最后与稳定 application Bridge 做 relocatable link，因此一个 Pack 变化不会迫使其他 module Pack 一起重编。

这里做的是“生成边界上的类型擦除”，不是动态调用 Swift 私有泛型 ABI。Release 执行仍必须拥有精确 Descriptor 与随 App 发布的 Pack entry；公共 Runtime 不能只凭函数名凭空构造任意 Swift ABI。

认证 Live Reload 会把未使用候选保留为纯数据，不把它们提前展开成永久 Bridge 机器码。新 HLBC 确实引用到缺失 Swift 候选时，Hub 才使用捕获到的真实 compiler job，仅生成这些 Key 对应的 Adapter body，签名并校验一份确定性的 Mach-O image。缓存身份包含 compiler、Xcode/SDK、target、deployment、依赖图、规范化编译/链接参数、生成源码、Descriptor 与 Contract；Objective-C 和 C 候选不会进入这条编译路径。

版本 1 `DevelopmentPayload` 会把 HLBC、精确提升的 import、Adapter image 描述、hash 和 image bytes 组成一个认证事务。App 会重新检查 compiler fingerprint、SDK build、target、Shell hash、Descriptor/Key、Mach-O 架构/平台/install name/UUID、代码签名、依赖规则与导出 symbol。随后先构造“baseline + 当前 session”的候选原生表，用它验证 HLBC，最后才原子激活 generation。失败事务即使已经映射了不可卸载 image，也只会把它计入进程预算，不会发布 import，更不会替换当前代码。每个 generation 以及 escaping callback 的 lease 都固定一份不可变能力快照。

两次重叠保存可能在彼此尚未激活时分别编译同一个缺失 Adapter。对 session 内完全等价的 import，发布是幂等的：第二次激活会复用已经发布的 invoker，不再映射或重复计费多余 image。这不是按名字兜底；identity、Descriptor、ABI、contract 或 binding 只要有任何差异就会 fail closed，而混合事务仍会在发布前加载真正新增 import 所需的全部 image。

当前只认证 Simulator 与 macOS 的按需 Swift Adapter；物理 iOS 会明确拒绝并要求重新构建 App，直到开发签名与加载矩阵有独立证据。开发传输也不再接受裸 HLBC：即使没有 Adapter，仍使用版本 1 envelope。重连 identity 会报告已发布的开发 Key 与已映射 Adapter 资源，Hub 可以复用同一 session Registry，而不重复编译已经激活的 Adapter。

产品、协议、Catalog、Archive 和 Bytecode 版本全部保持为 1。
