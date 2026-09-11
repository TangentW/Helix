# 编译器身份与诊断依据

[English](Compiler-Identity.md)

编译器打印出的名字只有在来源和作用域得到确认后才能参与身份判定。下表覆盖源码到
receipt 的主链路及 SIL、Catalog、缓存、工程安装边界，作为持续 review 的技术基线。
新的编译器输出或真实接入证据可能要求进一步收紧规则。

| 键的类别 | 权威来源与消歧维度 | 拒绝规则与使用方 |
| --- | --- | --- |
| 源码成员 | 单次编译中的规范物理路径；receipt 中的逻辑路径和内容 hash | Request 拒绝重复逻辑路径及物理路径别名；typed AST 必须精确覆盖请求的文件集合 |
| 源码 nominal 声明 | 编译器 USR，private 声明再带逻辑文件作用域；限定名仅用于作用域内查找 | `SourceNominalIndex` 分开查找各文件的私有声明；USR 和同作用域同名冲突报告双方证据；有歧义的私有类型打印布局不能用于冻结值布局 |
| Imported nominal | 先确认 runtime/ABI 身份，再用已证实的 module 根规范化限定/非限定 Swift 拼写 | discovery、merge、alias 和 binding 共用 `ImportedNominalIdentity`；模块、表示或 isolation 事实冲突仍失败，有 runtime 证据的 Clang 扁平拼写不再视为另一 Swift overlay，不合并无关嵌套类型 |
| Imported operation 与 selector | 声明 USR/descriptor、签名、owner、dispatch、accessor 与测得的 ABI；selector probe 还绑定导入模块上下文 | 共用实现符号不代表同一 API；candidate 先去重再划分互不重叠的 probe batch，生成的序号只标识该 batch 中的成员 |
| SIL 函数 | 同一 SIL 文件中实际的 `sil @symbol : $type { ... }` 定义 | 重复定义报告双方 SIL 行号和类型；函数索引随公开数组修改而更新，排除重名项；typed AST 优先匹配精确符号；同位置候选由编译器结构化符号角色和闭包 discriminator 消歧，未知角色继续保留，不能按顺序选取 |
| SIL debug scope | 单个 SIL 文档内的数字 scope ID；继承位置不改变 scope 自身身份 | 重复 ID 报告双方原始记录；只有存在实际函数定义时，`parent @name` 才能提供函数声明位置；`__unknown_macro__` 等只出现在调试信息中的名字不构成函数身份，各自位置仍按 scope ID 保留 |
| SIL witness table 记录 | 按 SIL 文档及行号保留每次记录，witness target 保留精确编译器符号与 module | 相同的类型/协议打印名可以属于不同局部声明；先保留全部记录，在条件与完整性过滤前隔离有歧义的类型查找，不能按顺序选 conformance |
| SIL 打印类型和成员别名 | 相关模块及源码作用域中唯一、经编译器证明的 nominal/type alias | `TypeEnvironment` 排除有歧义的私有类型摘要，所需布局或 dispatch 无法证明时失败，不能凭短名字选取布局 |
| SIL 源码模块映射 | 编译器明确输出的 `#fileID` 到路径映射 | 同一路径对应冲突模块时报告路径及双方模块；调试位置是来源依据，不是持久化身份 |
| Native Catalog 与 receipt 键 | 经验证的版本化 artifact identity、精确 compiler/toolchain/SDK/target、规范 descriptor 或 TypeID | snapshot/receipt 验证先于唯一键映射；hash 必须伴随经过认证或验证的记录，不能按显示名在运行时兜底查找 |
| 编译器事实与缓存 | 精确 toolchain、invocation、源码/依赖内容和 transform identity；checkpoint 还绑定物理路径 | `CachedAdapter` 先验证请求与源码唯一性，再建立映射并复核输入；checkpoint 命中重新解析；身份解释规则变化时更新 transform hash，防止旧模块 receipt 绕过新检查 |
| PBX 对象与配置 | 根 `objects` 字典中的对象 ID；所属 configuration list 中的配置名 | 重复字典键和重复配置名报告所属作用域与对象 ID；嵌套 `TargetAttributes` 的同名 key 不代表顶层 target 对象 |

这些编译器身份修改不改变已发布的 Shell/补丁 wire schema、nominal ID 或公共符号拼写。
本地 transform identity 会变化，相关缓存 Shell 事实需要重建。同一真实函数的相同
声明位置仍合法；如果一个名字看起来像占位符、却确实有 SIL 函数定义，它仍必须遵守
函数唯一性规则。

Fail-closed 消息必须包含判定点已有的冲突值、各自来源，以及每类不同事实的可定位
示例。例如声明位置冲突包含函数符号、双方 scope ID 与文件/行/列；源码 nominal
冲突包含 USR、限定名、逻辑文件、UTF-8 offset、kind 和作用域。调试信息用于诊断，
不额外写入持久化身份。仓库 review 约定也包含同一要求。

调试占位父名称的回归用例是依据报告中编译器输出构造的 SIL 语法 fixture。真实系统
框架集成测试另行开启 `-g` 并确认实际 SIL 有 debug scope；重放按原顺序保留 `-g`、`-gline-tables-only`、`-gnone`，另行覆盖Objective-C bridging、C++ 互操作、标准库宏和 explicit
module 编译，验证这些配置能共同工作；它不代表已经找到产生 `__unknown_macro__`
的最小 Swift 程序。

SIL 声明摘要中的 `private`/`fileprivate extension` 为直接成员提供默认访问级别；
成员的显式修饰符可覆盖这个默认值，但私有 nominal 父类型仍限制其子类型。存在歧义的
私有布局及后代保持不可用。Witness table 保留每条同名记录，包括没有成员的 marker
conformance；有歧义的类型及其后代不能通过打印名提供布局、静态 witness、泛型证明或
existential 分支。其他声明仍可分析，精确 witness 符号按 module 建立成员索引。
这不代表已支持降低这些有歧义的局部类型本身。

精确 AST USR/SIL 符号命中保留快速路径。按源码坐标回退时，receipt 分析批量调用
捕获工具链的 `swift-demangle --expand --tree-only`，单候选也必须通过角色验证。
`Static` 包装层保留底层 getter/function 角色；addressor、witness/reabstraction helper、
partial-apply forwarder 和 Objective-C/C 适配属性不能替代 Swift 源码声明。显式 closure
与 autoclosure 保持独立，只用闭包实体自己的 discriminator 约束匹配。未知包装层、
未知角色及仍有歧义的同角色候选保持 fail closed，错误包含全部符号、ABI、包装层、
角色和位置。分析先集中收集回退候选，单独出现的闭包也使用有界批次；精确 USR
命中不需要 symbol-tree 子进程。

声明发现可按逻辑文件限定范围，并在被消费的 AST/SIL 映射有歧义或缺失时排除有明确
源码归属的声明；无法证明归属时，排除整个已验证源文件并记录每个失败节点，
initializer/deinitializer 也作为闭包宿主。编译器 USR 与逻辑文件绑定整组 accessor/closure，不猜测候选，已收集
的局部 body operation 会回滚。编译器、源码、类型、ABI、Catalog 的全局校验仍须通过。
Live Reload 默认局部排除，Hot Patch/headless 默认严格，均可显式覆盖。策略进入
receipt/Prepare 缓存 identity，范围外源码仍保留整模块失效权威。Host Plan v2 承载范围，
不带新配置的 v1 继续可读。默认值、诊断与迁移边界见
[大型工程接入](Large-Project-Integration.zh-CN.md#声明范围与局部排除)。


Objective-C 扁平 runtime 名及其已知 module、`__C` / `__ObjC` 限定形式，只有在
reference/runtime 证据明确时才视为 ABI 拼写，不再与 `NS_SWIFT_NAME` 嵌套 overlay
竞争。非泛型的已归一和原始观察按同一 runtime 权威重新分组；同一 canonical 身份的 runtime
事实矛盾仍须先报错。Objective-C 轻量泛型在 runtime 擦除后仍保留类型参数区别。不同的嵌套 Swift 拼写或
不同 runtime class 不能据此任意合并。

SIL 检查分别报告各组件的依据。AST 映射的函数位置只能来自通过校验的函数定义与
scope；无效的类型摘要或 conformance 不提供类型及 operation 事实。独立映射冲突
一起汇总，共用正常 parser 的实现，不构造部分有效的 File。诊断 JSON 单独迁移到
schema 3，显式列出 `not_run` 检查并保留可选 `requestedStages`；旧报告字段缺省表示完整 receipt 范围。
局部通过只证明所选检查及其依赖通过，具体见[诊断指南](Large-Project-Integration.zh-CN.md#一次收集独立的-frontend-问题)。

compiler proxy 现在在编译前保存 `FrontendAttempt.hlxswiftc`，供 `helix xcode preflight`
使用（默认 `inputs,typed-ast,catalogs`）。只有成功编译才更新 `FrontendInvocation.hlxswiftc` 并运行
post-compile。仅输入预检不生成 AST/SIL，也不扫描依赖缓存；typed 检查仍需要可用的编译
依赖，局部检查通过不代表完整 receipt 或 runtime 支持。见[预检说明](Large-Project-Integration.zh-CN.md#成功构建前的预检)。

编译器 archetype（`τ_0_0.Element`、未替换的 `Self`、opened existential 和错误
占位符）不能进入 imported nominal 或 alias 身份集合。上下文泛型拼写被移除时，
独立证明的 Clang runtime 事实仍保留并校验，矛盾的 runtime 身份不会因此被隐藏。
`NS` 前缀或共有的嵌套名称前缀不能证明 Clang alias。扁平 `NS` 重命名必须在两侧
具有相同的精确 Objective-C runtime class 和 reference 表示，或具有编译器明确
证明的 `__C.` alias。`NSWidgets.Item` 与 `Widgets.Item` 这类独立身份仍保持分离。

## Frontend 身份权威清单

以下清单记录本次复核的查找边界。候选索引可以加速检索，但不能证明实体相同；
消费者必须保留冲突，直到对应权威证据完成消歧。

| 键或观察值 | 权威及作用域 | 碰撞与非身份值处理 |
| --- | --- | --- |
| Source nominal USR | 已验证 module/source 清单中的 typed AST 编译器 USR | 同名类型按源码作用域保留；有歧义的布局和后代不能提供类型事实 |
| SIL mangled symbol | 一次模块输出及一种 SIL purpose | 函数校验前保留重复候选；identity SIL 与 semantic SIL 是不同编译产物 |
| 路径 + 行 + 列 | Debug metadata 查找位置，不是声明身份 | 使用实测角色、accessor/static 种类和闭包 discriminator 筛选；未知角色仍保留歧义 |
| SIL scope 编号 | 单份 SIL 文档 | 拒绝冲突定义与环；不跨编译输出复用编号 |
| 打印的 conformance 类型/协议名 | 模块内候选分组，不保证全局唯一 | 保留所有 witness-table 条目；歧义名称不能证明 dispatch/layout |
| Imported Objective-C reference | 精确 Clang/runtime class 身份及 reference 表示 | 保留嵌套 Swift overlay 和所有 runtime 冲突；擦除后的 runtime class 不能合并不同泛型实例 |
| Swift 类型/alias 拼写 | 具体 nominal 候选索引，由 runtime 或 Catalog 声明证据进一步约束 | 排除 archetype/opened/error 占位符；import 列表不能单独证明声明归属 |
| Native operation | 编译器声明 USR 及已验证的 call/ABI projection | 上下文显示名和同后缀不能合并重载或 ABI 冲突 |
| 模块 frontend 缓存 | Capture、工具链/依赖、invocation、源字节、Catalog 身份、配置和 indexing 策略 | 私有 key revision 3 使旧归一/排除结果失效；所有源码仍使整模块失效 |
| 排除节点序号 | 一份已验证 AST 清单，仅用于诊断 | 不是声明或持久产物身份；无宿主失败按已验证源文件隔离 |
