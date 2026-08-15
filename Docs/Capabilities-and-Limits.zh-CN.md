# 能力与限制

[English](Capabilities-and-Limits.md)

Helix 有意采用 fail-closed 策略。“Swift 编译器接受这个文件”不等于“字节码后端支持这个语法”，“编译器能为声明生成 SIL”也不等于“当前 HLBC Lowerer 与 Shell capability surface 支持它”。本文给出当前实际边界。

## 产品状态概览

| 范围 | 已实现 | 尚未认证或实现 |
| --- | --- | --- |
| Release Shell | 精确 frontend 索引、Derived Sources、Interface Archive、永久 Bridge、NativeImport 发现、Xcode 集成、bundle 泄漏审计 | 大型真实业务迁移和长期 CI 矩阵 |
| 生产 HLBC | HLBC 1.0 / HLXI 1.0 编译链、Verifier、HLVM、签名包、安全安装、不可变激活、回滚与吊销；仓库内业务 corpus | App Store 分发批准、外部 top-200 corpus、长时间 fuzz/sanitizer、真机 macro 性能与 hosted UIKit 页面 soak |
| 开发期 Live Reload | 精确构建捕获、稳定快照、body 差分、会话绑定的验证后 HLBC、认证传输、原子激活、UIKit/SwiftUI 刷新、逻辑源码映射与 128 代进程内 soak | 真实 iPhone 矩阵、真机长时间 soak、交互式字节码单步调试、大型工程延迟资格 |
| Helix Hub | SwiftUI 菜单栏应用、工程发现、Hot Patch/Live Reload 事务接入、安全 helper 发现、统一 Service、精确 Build Context registry、Xcode 自动邀请与手动四位码配对 | 分发签名/公证与大范围第三方工程迁移矩阵 |
| Native 实验 | 仅显式选择的 Dynamic Replacement builder、递归/previous 测试、签名 dylib 与 loader probe | 产品支持；自动路由有意不选择它 |
| 控制面 | 客户端包与 policy 合同 | 生产 Registry、HSM 运维、审批、灰度、遥测和设备群协调服务 |

完整 SwiftPM 测试、warnings-as-errors、优化 Release 构建、iOS fixture 与仓库 Demo 分别作为证据 Gate。全部通过也不等于已经完成真实设备或分发通道认证。

## 生产 HLBC 1.0 的 Swift 子集

### 已实现

- `Bool`、有/无符号定宽整数、`Float`、`Double` 与 64 位 Apple 平台的 `CGFloat`，包括已声明的算术、位运算、比较、移位和数值转换规则。完全具体化的标量 `min`/`max` 与有符号数值 `abs` 会保留 Swift 的操作数顺序、溢出、正负零和 NaN 语义。HLBC 常量和 HLVM 值按目标位宽原样保留 bits：可表示完整 `UInt64` 值域，binary32 也不会先转成 binary64 存储，因此 infinity、正负零、NaN payload 与 signaling 状态都能穿过 canonical 编码和强类型 Bridge 往返。常用具体标量标准库 API 统一按“操作 + 现场值类型”lowering，而不是按 SDK receiver 加特例。定宽整数覆盖 `min`/`max`、`bitWidth`、`isSigned`、`magnitude`、置位/前导零/尾随零计数、`byteSwapped`、`bigEndian`/`littleEndian`、`signum()`、clamping/truncating 转换、`isMultiple(of:)`、`quotientAndRemainder(dividingBy:)`、全宽乘除和五种 reporting-overflow 运算。`Float`/`Double` 覆盖常用常量、bit-pattern 往返、exponent/significand 分解属性、分类判断、`magnitude`、`squareRoot()`、`ulp`、`nextUp`、`binade`、`significand`、`sign`、全部 rounding 规则、IEEE/截断余数、融合 `addingProduct`/`addProduct`、total ordering，以及四种感知 NaN 和正负零的 min/max；其常见 mutating 形式归一到相同的强类型操作。除零、无法表示的全宽商、有符号最小值除以负一、正负零、subnormal 与 signaling NaN 都保留 Swift 行为；对零未定义的底层 count builtin 会明确拒绝，不做猜测。
- `String` 字面量、拼接、支持标量的插值、Unicode `uppercased`/`lowercased`、count/empty、比较以及常见 prefix/suffix/contains 判断。可变大小转换会在分配前预留已经证明的输出上界，最终只按实际 UTF-8 结果计费。常见的 `String.contains(Character)` 可以使用单 grapheme 的 `Character` 字面量，而不暴露 Swift 私有 Character 布局。
- Tuple、`Void` 与 `Optional`，包括 `if let`、`guard let`、`??` 和 `try?` 产生的普通控制流，也包括 Dictionary semantic SIL 产生的地址型 Optional projection。
- Array 值语义、append、`first`/`last`、`popLast`、迭代、安全下标和返回新值的更新；支持键值类型下的 Dictionary 构建、查找、更新、`removeValue(forKey:)` 与迭代。Set 支持空值、字面量、Array/Set 构造，`count`、`isEmpty`、`first`、`contains`、`insert`、`update`、`remove`、`popFirst`、`removeFirst`、`removeAll`、容量提示、迭代，union/intersection/subtraction/symmetric-difference 系列，以及常见 equality/subset/superset/disjoint 关系。Set 的顺序不会参与相等性；HLVM 只在同一个值内保留确定的迭代顺序，以保证执行和诊断可复现。Dictionary key 与 Set element 共用一套 VM 定义的 Hashable 语义：Bool、定宽整数、浮点、String，以及递归受支持的 Optional、Array、Dictionary 与 Set。下载代码不能执行任意用户 hashing/equality，因此自定义 `Hashable` witness 会 fail closed。完全具体、底层来源为 Array 的 `map`、`filter`、`compactMap`、`reduce`、`forEach`、`first(where:)`、`contains(where:)` 与 `allSatisfy` 会降低成经过验证的 closure 控制流，并使用 invocation-local 的线性 Array builder，避免反复 copy-on-write append。payload 可表示为补丁内局部值时，`Optional.map`/`flatMap` 与具体 `Result.map`/`mapError`/`flatMap`/`flatMapError` 统一使用带显式 payload ownership 的选定 case 变换；`Result.get()` 会把 success/failure 投影到经过验证的 normal/error 边。局部 `Result` 当前不能嵌入 native handle。
- 结构化分支、循环、switch、调用、递归、显式业务错误边和带 payload 的局部 Error 值。真实 frontend 语料已覆盖三元表达式、`repeat-while`、带标签的 `break`/`continue`、Tuple 与 Optional 模式匹配、`for case`、`while let`、`fallthrough`、提前返回，以及循环与返回清理路径上的 `defer`。
- 所有已支持有/无符号定宽整数的 `Range`/`ClosedRange` `for` 循环，以及这些整数、`Float`、`Double` 和 64 位 `CGFloat` 的 `stride(from:to:by:)`、`stride(from:through:by:)`。`Range.contains`/`ClosedRange.contains` 还支持已支持整数、浮点和 String 边界。Lowerer 统一生成以 Optional 为 cursor 的强类型 HLBC progression，不依赖标准库 Iterator ABI；零步长、非法区间边界保留 Swift trap，整数极值也不使用会碰撞的 sentinel。
- 可在现有受监视文件中新加、且不导出到原生 ABI 的文件或 module scope 补丁内非递归 stored struct/enum；支持具体 `Result`、字段读取、enum switch、实例/静态计算 getter/setter 与受支持的 mutating helper。嵌套声明保留完整 namespace identity。它们是仅属于当前 generation 的 VM 值，不是新加载的 Swift metadata。
- 新增普通函数、private 方法和计算属性会作为同一 image 的普通函数、getter 或 setter 被传递发现并编译，不要求它们预先出现在 Shell EntryIndex 中。patch-local `final class` 具有 HLVM 自己的引用 identity、字段 storage 和方法调用；纯 HLVM class 仍不能跨原生边界。
- 新增 `final` class 可以选择一个 HLXI 已冻结、`NSObject` 兼容的 reference superclass。Runtime 为每个不可变 image 注册 Objective-C host，使对象能以该 superclass（包括 `UIViewController` 或项目基类）的身份交给原生代码。当前 hosted profile 仅支持继承的无参初始化、无新增 stored property，以及无参或单个 `Bool` 参数的 `Void` override；原生侧不能识别补丁新增的 Swift 具体类型。
- 同步补丁内 `inout` 与 `mutating` helper，并受 Address、access、alias、ownership、同 frame/同 block 规则验证；其中包括编译器为捕获可变局部变量的 `defer` helper 生成的 `@inout_aliasable` / `@closureCapture $*T` 物理 convention。
- 捕获 copyable VM-managed 值的同步补丁内 closure，包括 nonthrowing 与 throwing 调用路径。可变局部值统一提升为与具体类型无关的 VM cell，可覆盖标量、String、Optional、Array、Dictionary、Set、Tuple、补丁内 struct、字段投影、嵌套捕获，以及 Swift 为 escaping closure 生成的 `{ var T }` box。字段敏感的“确定/可能初始化”分析还覆盖分支初始化、条件覆盖与清理，但不会把可能初始化的值当成可读值。它包括同 image helper 的 `@escaping` 参数、从同 image 函数把 closure 返回给调用者，以及 closure 再捕获另一个 closure。具体 closure ABI 会保留每个参数的 owned/borrowed convention，包括受支持高阶操作中的 `@in_guaranteed` Optional 与 imported SDK reference value。closure 值必须在同一次固定 generation 的 HLVM invocation 内用完。返回与嵌套捕获由 `escaping-closure-values-1` 门禁，managed cell 由 `mutable-captures-1` 门禁。另支持不再包含 archetype、metadata 或 witness 依赖的编译器完全具体化 specialization。
- 顶层无 suspension 的 `async`、`async throws` 和 `@MainActor async` entry。生成的精确 Swift wrapper 保留 ABI，HLVM 只执行已经证明不会挂起的 body。
- VM-owned `Any`、`is`、`as?`、`as!`，以及受支持 Optional/Array/Dictionary 的递归动态转换；Swift existential metadata、native object 和线性生命周期不会进入下载字节码。
- 完全具体的默认参数 generator。生产与开发编译器会把可达 `fA...` thunk 一起链接并纳入传递实现指纹；当前只承诺一个完整 module source set 内的 eligible 调用点。跨 module 的 public/package 默认值、非 eligible 调用点或仍需泛型 metadata 时要求完整构建。
- 普通 `Swift.print`，由所有新 Shell 自动冻结的同步 NativeImport 承载。支持常见 Bridge-compatible `Any` 值、separator/terminator 和 64 KiB 输出上限，不要求 App 手工配置 Catalog。
- 受管 Debug 会测量所有“已经冻结 imported native type”所属 module 的公开成员。捕获 toolchain 的 symbol graph 负责提名满足 minimum OS 的 API，同一 typed AST/canonical SIL 流程只冻结唯一且 Bridge-compatible 的 initializer、同步实例/静态 method 与可读/可写 property。这条通用路径覆盖 Swift 与 Objective-C 声明、Swift overlay/物理 alias、SDK actor 隔离，以及 Objective-C 实例方法被导入为逻辑 Swift `throws -> Void` 时已经证明的 canonical `NSError **` bridge；例如 `UIColor.black`、`UIColor.init(white:alpha:)`、`UIView.alpha`、`UIView.setNeedsLayout()`、`UIView.setAnimationsEnabled(_:)`、`URLCache.shared`、`Bundle.path(forResource:ofType:)` 与 `FileManager.removeItem(atPath:)`。生产 Shell 不会得到这组便利能力，它本身也不会引入新的 boundary type。
- 精确原生操作已冻结时的 Objective-C superclass dispatch 与 address-form Optional 控制流。同类型 receiver cast 只有在两端是同一 reference `TypeID` 时才作为 alias；Optional payload take 即使经过精确地址复制，也必须受 `.some` edge 支配。
- 调用同 image helper、eligible Shell entry 与目标 Shell 已经生成的精确 allowlisted NativeImport。发布基线已经使用、且 Typed AST 语义与 canonical SIL 物理 ABI 能够对齐的外部 API 可以自动冻结；当前覆盖 reference、raw enum、OptionSet、opaque copyable value、accessor、method、全局值/函数、简单 imported C value、Selector、upcast，以及已验证的 String/Array Objective-C bridge。

### 拒绝或有意未完成

- generic root，以及仍需要运行时 generic metadata、witness table、reabstraction 或动态 specialization 的执行。
- 真正 suspension：`await`、continuation、Task、async callee、async closure、cancellation，以及跨 suspension ownership 或 generation lease。
- actor-isolated instance root、custom global actor 和任意 executor hop；上面的受限 `@MainActor async` leaf 是不同能力。
- 穿过 Shell Entry 或 NativeImport 边界、持久化到 native/global/property 状态，或者存活时间超过当前 HLVM invocation/generation 的 closure。async、`@Sendable`，以及 closure 自身参数或返回值仍是 closure 的高阶签名暂不支持。捕获调用者拥有的 `inout` 参数也仍会 fail closed，因为它需要显式写回调用者；普通可变局部值与 Swift escape box 走上面的 managed-cell 路径。
- 上述受限字面量判断以外的一般 `Character` 值/API；超出上述定宽整数和浮点迭代面的 progression element type、把 Range/stride 值导出到 Shell 或 NativeImport 边界，以及函数局部 nominal type 声明。把不导出的补丁内 struct/enum 移到现有受监视文件的文件/module scope 后即可随补丁编译；只要它仍是 image 私有声明，就不要求重建 Shell。
- Dictionary key 或 Set element 的用户自定义 `Hashable` 语义，以及 VM-owned `Any` 内的动态 Set payload。强类型 Set Shell bridge 已受支持，但有界 dynamic-Any codec 不会猜测 element type。
- 任意新 Swift metadata、原生侧可识别的补丁具体 class、retroactive conformance，以及修改 Shell 已有类型的 layout、superclass 或 enum case。上面的 hosted Objective-C subclass 是冻结 superclass projection，不是动态生成任意 Swift metadata。
- Generic 或 `inout` Shell entry、noncopyable root、任意 borrowing/consuming ABI、typed-throws root、上述具体标准库操作之外的通用 `rethrows`，以及通用 unwind cleanup。
- 不受限 pointer、`unsafeBitCast`、任意 Objective-C selector/IMP、`dlopen`/`dlsym`、Mirror 字段修改与未知 builtin。
- 目标 Shell 中没有精确 `NativeImportID` 的原生调用，即使 App 中存在名字相似的 Swift 函数。生产补丁也不能给旧 Shell 新增 framework，或首次使用发布时未冻结的 SDK 操作。上面的受管 Debug 调色板之所以可用，正是因为正常 Debug Build 已经逐项冻结了这些 ID。

## 开发期 Live Reload 边界

默认 Live Reload 使用与生产相同的 canonical SIL、Verifier 与 HLVM 核心。开发路径改变的是 session、传输、生命周期与诊断策略，不会用下载的机器码兜底不受支持的字节码。

| 修改 | 当前结果 |
| --- | --- |
| 修改已索引的 global 函数体 | canonical SIL 位于文档子集内时支持 |
| 修改已索引的源码 class 实例方法体 | 支持；生成 TypeOps 会把精确 `self` 引用传入 HLVM |
| 修改 Shell 已有 struct/enum/actor 实例 root 或已有原生 static/class 方法 | 在 Shell value writeback、executor 与 native metatype ABI 实现前拒绝；这不限制 image-local 值类型的 accessor/helper |
| 从函数体调用已有 private/internal/public 声明 | 仅在解析为同 image 函数、eligible Shell Entry 或实际生成的精确 NativeImport 时支持 |
| 在受管 Debug body 中首次使用公开 SDK 成员 | 对唯一测得的同步 initializer、实例/静态 method 或可读/可写 property 支持，前提是所有 boundary type 已能由冻结 imported/Bridge 类型面表达，且声明满足 Shell minimum OS；陌生 `NSError` bridge、async/generic/带 closure 的成员、subscript 与不可表达签名需要完整构建 |
| 在现有源码文件新增普通顶层 helper、class private 实例方法或计算 accessor | 能从变化 root 到达、且具体签名与函数体落在 HLBC 子集内时支持；声明仅属于该 image |
| 普通直接递归 | 解析到同一不可变 HLBC image 内的函数 |
| 从源码有意调用上一代 | HLBC 不支持；应保存/激活一个恢复 generation |
| 使用受支持的局部 closure，或调用已经索引且带 `@escaping` closure 参数的同 image helper | 降入同一 image；closure 的返回和捕获只能发生在固定的 VM invocation 内 |
| 使用整数 `Range`/`ClosedRange` 迭代、数值 `stride` 或标量 `contains` | 对上述具体且局部的类型族支持；边界、方向、开闭端点、零步长 trap 与整数极值均保留已验证的 Swift 语义。progression 值仍只属于 image，不能穿过 Shell/NativeImport 边界 |
| 在受支持的 `String.contains` 中使用单 grapheme Character 字面量 | 以编译器内部 String 表示支持，不代表一般 Character 存储/API 已支持 |
| 声明补丁内 struct 或 enum | 新增的不导出类型在文件/module scope 支持，包括 namespace 嵌套和受支持的计算 accessor；函数局部 nominal 会用精确类型诊断拒绝 |
| 声明补丁内 pure class | `final`、非泛型、只在同一 image 内使用时支持引用 identity、stored property、private/普通方法与计算 accessor；不能传给原生代码 |
| 声明继承现有项目类或系统类的 hosted class | superclass 必须已作为 `NSObject` 兼容 reference TypeOps 冻结；当前支持继承无参初始化、无新增 stored property及无参/Bool `Void` override，并以 superclass 身份交给 UIKit/原生 API |
| 新增无关声明、新原生 ABI 表面或新 Swift 文件 | 不会仅因声明存在而收集；source membership 或原生 ABI 变化需要完整构建 |
| 修改 stored property、签名、generic constraint、actor isolation、superclass、conformance 或 enum case | 拒绝，需要完整构建 |
| 修改 default argument 行为 | 完全具体的 generator 会与同一完整 module 内 eligible、已归档的调用点一起进入补丁；跨 module public/package 默认值、非 eligible 调用点或泛型 ABI 要求完整构建 |
| 修改 static/global initializer | 已经初始化的状态不会自动重放 |
| 新增 framework、package、macro/plugin 输入、bridging header 或 source membership | Dev Build Manifest 失效，需要完整构建 |
| 修改 storyboard、XIB、asset、strings、Core Data model、plist 或 entitlement | 不属于 Swift body Live Reload 路径 |

捕获的编译器上下文会保留原 access control，但可见性本身不是 Runtime capability。一个操作无法表示成 HLBC、也没有精确生成的 Entry/NativeImport 时，即便普通 Swift 允许访问，编译仍会失败。

Simulator 与设备使用同一套 HLBC 协议和 Runtime。仓库 Simulator E2E 已在同一 App 进程中应用修改并恢复 baseline；另有 128 代进程内 soak 验证 active/rollback、失败保存、generation 高水位与压缩保持有界。真实 iPhone 运行和长时间内存压力 soak 仍需补齐，才能列为经过验证。Native Dynamic Replacement 只保留为必须显式选择的内部实验，不是产品 fallback。

## UI 刷新边界

代码替换决定下一次函数调用的行为；UI invalidation 决定用户是否立即看到结果。

- Helix 会从已展示实例的运行时 class 自动还原 controller/view identity，并支持沿 superclass 匹配；UIKit 不需要 type registry。
- 常见 render 与 layout callback 会自动推导 constraint、layout 和 display invalidation，并保留原页面实例与内存状态。
- 初始化或业务自有刷新逻辑可以使用幂等 `LiveReload.Reloadable` hook；它不是普通接入前置条件。
- 重建 Controller 需要注册 Factory、route context、state capture/restore 和容器支持。
- SwiftUI 需要 `liveReloadBoundary`；`invalidateBody` 尽量保留 identity，`recreateSubtree` 会重置该 boundary 的局部状态。
- Helix 不会自动重放 `viewDidLoad`、`loadView`、initializer、observer 注册、subscription 或任意生命周期 callback。
- 没有安全目标或规则时，代码可以保持激活，但结果会是 `manualRefreshRequired`。

仓库 fixture 已证明无需注册的 UIKit controller/view 与 superclass 自动匹配、invalidation、状态保持、SwiftUI pulse 路由和 Debug Overlay 行为；它们不能认证所有 custom container、navigation/sheet 交互、observation graph 或长期副作用模式。

## 诊断边界

Canonical Swift debug metadata 会降低成经过 Verifier 检查的 HLBC source map，以 function、block 与 instruction offset 定位。生产 artifact 只保留无歧义的逻辑源码路径，不携带构建机绝对路径。反汇编可以标注这些位置；HLVM trap 会给出结构化 program counter，`HelixRuntime` 再补充固定的 generation、Shell entry、函数名与逻辑 Swift 位置后通知 observer。

这属于源码级故障归因，不等于替代 LLDB。HLBC 的交互式 breakpoint、单步、表达式求值与 time-travel debugging 尚未实现。不支持的语法仍会在 Mac 编译阶段用原逻辑源码位置明确失败。

## 安全与资源边界

生产与开发路径都会对未知版本、capability、目标、身份、重复记录、畸形容器和资源超限 fail closed。生产字节码具有 fuel、deadline、stack、register、调用深度、值形状、NativeImport 和内存计量。可变大小 VM 操作会原子预留已验证的最坏分配上界、退回未使用部分并保留实际计费；下载与 live transfer 会在分配和执行前进行有界检查。

开发期 Live Reload 会限制 artifact 字节与保留 generation。同步 Swift NativeImport 无法被硬抢占；只有具备 deadline 与 checkpoint 的 bounded/cooperative import 才适合进入生产 Catalog。真实设备尾延迟和内存压力仍是 Gate。

## 兼容性与分发

Swift Package 的平台下限为 macOS 14 与 iOS 15。补丁绑定一个 finalized Shell interface 与目标身份，不得猜测某个 App build 的包与另一个 build 兼容。

当前 Release Builder 允许 internal 与 enterprise HLBC policy。App Store 通道仍是 `policyBlocked`，受控 Native Release 后端尚未实现。平台政策、签名与组织审批独立于字节码引擎是否在技术上能运行。

完整流程见[总体架构](Architecture.zh-CN.md)、[生产热补丁](Production-Hot-Patching.zh-CN.md)和[开发期热重载](Development-Live-Reload.zh-CN.md)。
