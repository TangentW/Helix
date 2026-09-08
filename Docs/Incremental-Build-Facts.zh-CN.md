# 增量构建事实与产物发布

[English](Incremental-Build-Facts.md)

Helix 把“能覆盖多少原生 API”和“构建要花多少时间”分开处理。Prepare 会优先消费由
编译器生成的模块 Catalog，只让源码根 frontend 证明这些快照没有覆盖的 module 或具体
specialization。任何缓存事实在使用前都要重新匹配当前语义输入并完成校验。缓存命中只是
省时间，不是新的权威来源，也不能凭空增加能力。

本文说明 Live Reload 与 Hot Patch 共用的 schema 1 实现。项目不需要维护 API 清单，
不需要冻结，也不需要开发者配置缓存。默认缓存放在当前用户的
`~/Library/Caches/Helix/BuildFacts`；`HELIX_BUILD_CACHE_DIR` 只是测试和排障时可选的
覆盖入口。


声明发现可按逻辑文件限定范围，并在被消费的 AST/SIL 映射有歧义或缺失时排除有明确
源码归属的声明；无法证明归属时，排除整个已验证源文件并记录每个失败节点，
initializer/deinitializer 也作为闭包宿主。编译器 USR 与逻辑文件绑定整组 accessor/closure，不猜测候选，已收集
的局部 body operation 会回滚。编译器、源码、类型、ABI、Catalog 的全局校验仍须通过。
Live Reload 默认局部排除，Hot Patch/headless 默认严格，均可显式覆盖。策略进入
receipt/Prepare 缓存 identity，范围外源码仍保留整模块失效权威。Host Plan v2 承载范围，
不带新配置的 v1 继续可读。默认值、诊断与迁移边界见
[大型工程接入](Large-Project-Integration.zh-CN.md#声明范围与局部排除)。

## 分层复用什么

| 层级 | 复用内容 | 什么变化会让它失效 |
| --- | --- | --- |
| SDK identity | `xcrun` 返回的 SDK 路径和 build | Swift driver 实例、SDK 名、`DEVELOPER_DIR`、`TOOLCHAINS` |
| 模块 frontend | 已验证的 receipt、诊断和工具链 identity | 编译捕获内容、编译器指纹、非 SDK 模块/头文件接口快照、metadata、策略、catalog、配置，以及每个源码的逻辑路径、物理路径和内容 hash |
| 编译检查点 | 重新解析验证的 typed AST、identity SIL、semantic SIL 中间结果 | 编译捕获、精确工具链/编译器路径、frontend invocation 与 SDK、transform pipeline、完整 compiler-input digest，以及全部源码的逻辑/物理路径与内容 hash |
| Symbol graph | 已验证的 SDK 模块公开符号图 | 编译器指纹、SDK/frontend invocation、模块名 |
| 单候选探测 | 某个候选最终测得的操作及其原生签名类型 | 编译器指纹、变换流水线、SDK/frontend invocation、最低系统、规范化候选和边界类型 |
| Native API Catalog | canonical 模块 Document，以及能确定性重建它的不透明 compiler projection | Xcode/SDK/compiler、target/deployment/language mode、模块内容/搜索/依赖 digest、规范化模块加载语义与变换流水线 |
| Hot Patch Prepare | 完整 Shell 目录和函数计数 | Prepare 精确输入，或输出中的路径、字节、权限、额外文件发生任何变化 |
| Release 能力投影 | canonical schema 1 Native Capability Manifest 与 digest | Release/Shell identity、capability，以及所有 device-emitted Descriptor、Key、Contract 与 capability 的完整有序集合 |
| Adapter Pack source | 按原生 module 分组的确定性 Swift Adapter | 编译器指纹、SDK/target/deployment、变换流水线、module、有序 imported module 集合与有序稳定调用 Key |
| Adapter Pack object | 单个 module Pack 的已验证 Mach-O | Pack source identity，再加工具链、Xcode build、规范化编译参数、完整非 SDK compiler-input 快照和 module map |
| 开发期 Adapter image | 只包含首次使用且缺失的 Swift Adapter body 的签名 Mach-O | compiler/Xcode/SDK identity、target/deployment/platform/architecture、依赖图、module、规范化语义参数与保留的链接参数、精确生成源码、有序 Descriptor/Key/type/contract 记录 |
| Application Bridge object | 排除一次性 Hub contract 后的稳定、已验证 Mach-O | profile、工具链、Xcode/SDK build、变换流水线、规范化编译参数、稳定生成源码、compiler input 和 module map |
| 最终 Bridge state | 已链接的 Bridge 与 C bootstrap Mach-O object | 包含 Hub contract 的全部生成源码、application/Pack 输入、Clang binary 和 bootstrap source |

持久缓存 key 使用 canonical JSON 和带版本的 hash domain，不依赖文件修改时间。
源码内容、编译捕获内容、编译器可执行文件指纹、SDK build、target、最低系统、优化
级别和 frontend 语义参数，都在会影响对应结果的层级进入 key。捕获的 `-g`、
`-gline-tables-only`、`-gnone` 按原顺序保留，因为声明解析会使用 SIL scope 来源。
实际函数定义、conformance 记录作用域、extension 访问默认值、结构化符号角色、
Clang runtime 拼写及独立 SIL 检查的修订更新了 transform hash，使旧 Shell/module
事实失效，不改变 Shell 或补丁产物 schema。详见[编译器身份](Compiler-Identity.zh-CN.md)。

Helix 会先从源码中提取真正使用的 Swift `import`，再与编译器 receipt 中的导入模块
交叉校验。Swift 与常见 Clang 搜索参数（`-I`、`-F`、`-Fsystem`、`-iquote`、
`-isystem` 等）下只对这些直接导入的非 SDK 模块接口做指纹，不会因为同一搜索目录里
碰巧新增了无关模块就让缓存失效。词法扫描覆盖常见属性、scoped import、条件编译、
注释、raw/multiline string、字符串插值和 extended regex literal；一旦扫描
不能完整确定结果，或结果不能覆盖编译器实际导入，Helix 会在 Typed AST 之后、任何
symbol graph/probe 缓存使用之前拒绝这个较窄身份，本次改走权威的无缓存 frontend。

经 `-Xcc` 传入的 Clang 搜索目录和显式输入单独处理。module map、bridging header、
公开头文件、PCM、VFS overlay 的 `external-contents`，以及 Xcode 二进制 header map
指向的头文件，都会进入有界内容快照。SDK 与 toolchain 目录由各自的
build/fingerprint 绑定，不会逐文件重复扫描；当前模块自己的输出和实现 object 会排除，
避免缓存自我失效。如果输入无法可靠解析或稳定读取、遇到无法证明安全的 symlink 模块
目录，或超过快照上限，本次会关闭模块和细粒度 frontend 复用，继续走权威的无缓存
构建，不会因为缓存功能而令正常编译失败。目录遍历到达条目上限时会立即停止；overlay
解析同时限制大小、节点数、引用数与深度。VFS overlay 和二进制 header map 内部的物理
路径会在 identity 中替换为结构角色，而每个映射实际到达的文件字节会绑定在对应角色下：
整体搬迁可以复用，但把某个虚拟名字改映射到另一份内容一定会失效。

模块 receipt 是范围最大的快路径；它失效后，权威 frontend 仍能继续复用 symbol
graph 和单个声明的探测结果。也就是说，业务代码做了一次普通修改，不会因此重新
扫描和探测一遍完全没变的 UIKit 或 Foundation。

编译成功而后续 receipt 分析失败时，已完成的编译阶段保留为用户私有的 UTF-8 检查点。
重试会重新解析每一阶段；AST 的源文件集合、编译器版本和 import 覆盖范围仍须匹配。
每次 compiler 调用后以及每次检查点命中后，都会重新核对源码和接口输入。输入发现
不完整时不启用检查点，编译或解析失败的结果也不会保存。检查点 key 不包含后续阶段
使用的策略、Catalog 选择和非编译配置，因此修正 receipt 冲突后可复用相同的编译工作；
源码、编译参数、工具链、SDK 或 transform 改变则不能复用。

每个检查点最多保存 256 MiB，超过时正常解析但不缓存。完整模块 receipt 成功存入缓存
后，会尝试非阻塞获取各自的 key 锁并清理三个中间 payload，保留锁 inode 以便其他进程协调。
清理是尽力执行；失败构建遗留的条目没有总磁盘配额，可在没有构建运行时删除当前用户
缓存中的 `v1/compiler_checkpoint` 目录。这些文件含编译器格式和源码路径，只适用于
精确的本地编译上下文，不是可移植 Catalog 或公开 ABI。后续 Prepare 或物化失败重试
仍优先使用已经完成且验证通过的完整 receipt。

探测失败也不是一概写缓存。只有经过递归拆分后、可确定复现的单候选拒绝才会缓存；
临时编译器故障不会变成永久“不支持”。正常探测和校验完成后，才保存候选的最终
结果。每条缓存还只保存该候选的 receiver、参数、回调或返回值实际引用的原生类型。
因此，签名里首次出现的新类型在缓存命中时不会丢失，结果也不会依赖它第一次恰好
与哪些候选被分到同一探测批次。

模块级 Catalog 是位于上述两种细粒度缓存之上的、更宽的一层独立缓存。Producer 会扫描
一个模块的具体公开调用面，复用同一套精确探针，再把 canonical Catalog 与可重建它的
compiler facts 一起保存。整份 Catalog 的 key 不包含消费方项目 module name，并会归一化
Swift/Clang 的物理搜索目录、module map、PCM、resource root 和 module cache 路径；参数
顺序与语义角色仍会保留，真正的模块字节、搜索空间含义和依赖则由单独计算的 identity
digest 表示。宏等非路径 Clang 参数保持精确，因此跨项目复用不会把不同语义误合并。

Catalog 命中时不会启动 Symbol Graph 或候选探针进程，但缓存中的 compiler projection
仍要重新规范化、重新分类，而且重建出的 entry 必须和缓存 Document 完全一致。Prepare
会先使用这些已验证 operation，只对缺失 module 集合执行源码根 Framework 扩展。Catalog
拥有的调用身份不会被消费项目自己的 source scope、typealias 或 call-site SIL ownership
改写；外部 TypeOps 也只保留真正穿过逻辑参数或返回值边界的类型。

Hot Patch 在发布生产能力基线前，会同步解析完整的可达 Catalog 闭包。Live Reload 则用
非阻塞 shared lock 读取：条目不存在或正由其他 producer 生成时，Prepare 都不会等待，
本次直接走权威源码根回退。在 frontend receipt 生成前发布仅当前用户可读的 canonical
预热任务，因此后续 frontend 失败不会再阻断 Catalog 自举。
utility worker 会重新确认任务仍匹配 compiler、SDK、plan 和 module input，再生成首批
miss，并递归跟进引用到的 module。任务文件以原子方式发布到 `0700` 目录，权限为
`0600`；读取使用 `O_NOFOLLOW`、大小上限和文件锁，重复 worker 不会破坏结果。

冷的全模块探测不会再对每个候选逐条查询文件缓存：外层 Catalog key 已经精确表示该
模块，而每个公开 API 再开一次 lock、读一次 manifest 只会增加线性 I/O，不能带来有效
复用。顶层每 256 条为一批，最多 4 个 worker；结果和错误按批次顺序 join，因此并发只
改变耗时，不改变输出字节、诊断、指标或缓存身份。源码根扩展仍使用细粒度探针缓存，
因为普通源码修改造成 module receipt miss 时，这些候选仍有实际复用价值。

## 命中前仍然要验证

`xcode post-compile --diagnose` 即使已有完整模块 receipt 缓存，也会运行当前 frontend
检查。它共用正常生成的依赖分析，重新解析验证 compiler checkpoint，成功或失败均
保留检查点，不发布模块 receipt、不回收检查点。修正后的正常构建可以复用编译再按
正常规则发布。诊断仅在所选检查需要时读取已有 Catalog，不执行冷编目或预热。
`--stages` 跳过无关的编译重放，后续完整诊断可复用局部检查成功的中间产物；使用缓存
的诊断在成功返回前仍复核输入。独立 SIL 检查可保留有效函数位置来诊断映射，但无效
SIL 输出不能作为整个阶段成功写入检查点。JSON schema 3 记录选择范围和显式的 `not_run` 状态，局部通过
不等于完整 receipt 通过；具体边界见
[大型工程接入](Large-Project-Integration.zh-CN.md#一次收集独立的-frontend-问题)。

每种缓存结果都由实际消费者重新解码并做语义校验：

- manifest 的 canonical 编码、schema、key、payload SHA-256 必须一致；
- 结构化 payload 继续检查其 canonical 编码；私有原始编译检查点必须是有效 UTF-8，
  并通过当前的 AST/SIL parser；
- receipt 必须完整通过结构校验，并匹配当前源码、metadata 和工具链；
- symbol graph、实测操作及其原生签名类型走与新生成结果相同的验证；
- Prepare state 会比较整个生成目录，包括文件权限和意外多出的条目；
- Adapter Pack、开发期 Adapter、application Bridge 与最终 Bridge state 都会重新检查
  Mach-O 架构和平台。开发期 Adapter 还会检查确定性 install name、UUID、代码签名
  command 与依赖前缀；最终 state 还会核对已发布 object 的大小与内容 hash。

新生成的 module、Prepare 或 Bridge 状态发布前，还会再次确认源码和编译器接口。
如果编辑器或另一个构建恰好在分析期间改了输入，Helix 会完成权威的无缓存流程，但
不会把输出错误地挂到较早的 identity 上。Bridge identity 还会独立哈希实际编译 C
bootstrap 的 Clang 二进制，不用 Swift frontend 指纹代替它。

没有缓存就运行正常 producer。缓存损坏或语义已经过期时，会隔离旧条目并重新生成。
缓存根目录不安全或不可用时，则直接绕过缓存走权威流程。因此缓存故障不能悄悄放宽
能力边界，也不能把本来不支持的源码伪装成支持。

## 本地安全与并发

构建事实只属于当前用户：目录权限是 `0700`，文件权限是 `0600`。符号链接、非当前
用户拥有的对象、group/world 可写根目录和不安全的可写祖先目录都会被拒绝；私有根
目录之上只接受 `/var` 这类由 root 管理的系统别名。读取使用 `O_NOFOLLOW`、有大小
上限的普通文件读取和内容 hash。

同一个 key 使用一把进程间 advisory lock。多个 Xcode 任务并发请求同一事实时，只有
一个 producer 真正生成，其他调用者等待发布后再验证读取。新条目先写入私有 staging
目录，再通过 rename 发布。缓存不会进入 App、补丁或签名输入，也不是安全信任根。

延迟敏感路径另有只读入口：它不会创建缓存目录、等待 producer、修复损坏条目或启动
任何新工作，只尝试取得非阻塞 shared lock；不可立即读取并完整验证时就返回 miss。

## Xcode 产物怎么更新

Shell 生成目录以一次原子目录切换发布。如果新旧目录的字节和权限完全相同，就什么
都不改，原 inode 和修改时间保持不变。只有部分文件变化时，未变化且由 Helix 生成的
普通文件会 hard-link 到 staging 目录，只重写真正变化的文件。意外文件和符号链接
不会被跟随或保留。

Hot Patch 的 Prepare 在“精确输入一致 + 完整输出 manifest 一致”时，可以在进入
frontend 前直接返回。Live Reload 不复用最终 Prepare state，因为 Hub invitation
只能消费一次，每次构建必须重新预留；但耗时最大的模块、symbol graph 和 probe 事实
照常复用，之后只重新生成很小的会话绑定合同。

进入 frontend 前，Prepare 会根据捕获的 compiler 参数和有序 module search 语义自动
计算 Catalog identity。生产路径会等待全部可达快照，开发路径只读取已经就绪的快照，
其余部分不阻塞回退。Frontend cache 与 Hot Patch Prepare identity 同时包含 canonical
Catalog Document 和不透明 compiler projection 的 digest，所以 module surface 变化只会
精确失效真正消费了它的构建事实。

Bridge 编译现在分成多层精确事实。Objective-C 与受支持的 C 调用使用固定 Runtime
Invoker；其余 Swift 调用按 module 归入确定性的 Adapter Pack，Pack source 和 Mach-O
object 分别缓存。稳定 application Bridge 编译时不包含一次性 Hub contract，并拥有独立
的内容寻址 Mach-O 缓存。Live Reload 会单独编译本次很小的 Hub contract，再把它与稳定
application object、各 Pack object 做 relocatable link；Hot Patch 根本不生成 Hub
contract source。

Hot Patch 使用受管生产策略：证明边界内所有合格候选都会标记为 device-emitted，并
写入 canonical `NativeCapabilities.json`。生成 Bridge 会根据 Shell import 得到同一
张表；Release audit 再把两份投影与 finalized archive 比对，把 digest 固定在
`ReleaseBaseline.json`，后续补丁还会把它写入签名 target。因此 Prepare 缓存可以复用
相同字节，却不能改变已发布 App 授权哪些调用。

受管开发未使用候选只保留为 Receipt 数据，不会膨胀稳定 Bridge 或 Pack object。
HLBC 构建完成后，Helix 会检查它真正使用的 import table。Objective-C 与受支持 C 的
首次使用不需要生成机器码；只有新引用的 Swift Adapter Key 才会渲染成一份最小开发
image。完全相同的请求在完整 Mach-O 校验后复用 owner-local cache。缓存仍只负责省时：
认证 payload 会携带 image 与精确 metadata，App 在发布能力 snapshot 前仍会独立复核。

Patch Compiler 只有在本次选中的 optimized 或 semantic SIL 确实包含 foreign call 时，
才会额外请求 Typed AST 声明映射。因此，Shell Catalog 即使包含 Objective-C 候选，
纯 Swift 修改也不会平白多跑一次 whole-module frontend。

最终 Bridge state 仍更严格：它包含包括当前 invitation 在内的每一份生成源码。因此，
新的 Live Reload reservation 会按设计让最终 state miss，但仍可命中分别验证的
application 与 Pack object cache。源码、module map、工具链、编译参数、SDK、平台或
object 漂移只会让它所影响的层失效。这样既保证每次 invitation 都是新的，又不需要重编
数 MB 的稳定 Bridge。

## 怎么看是否命中

schema 1 构建性能报告会记录决策，但不会泄露完整路径或编译参数。关键计数包括：

- `frontend_cache.module_hit_count`、`module_miss_count`、
  `module_repair_count`、`module_bypass_count`；
- `frontend_checkpoint.<typed_ast|identity_sil|semantic_sil>_<hit|generated|repaired|bypassed>_count`
  和 `frontend_checkpoint.retired_count`；
- `managed_native.symbol_graph_cache_hit_count`、`_miss_count`；
- `managed_native.probe_cache_hit_count`、`_miss_count`、
  `cached_rejection_count`；
- frontend 内的 `native_api_catalog.hit_module_count`、`miss_module_count` 和
  `entry_count`；
- `prepare.catalog_planned_module_count`、`catalog_hit_module_count`、
  `catalog_generated_module_count`、`catalog_miss_module_count`、
  `catalog_unresolved_module_count`、`catalog_entry_count`，以及后台预热已调度/启动失败
  计数；
- `prepare.state_hit_count`、`state_miss_count`、复用/写入产物数和
  `noop_publication_count`；
- `bridge.state_hit_count`、`state_miss_count`；
- `bridge.application_object_cache_hit_count`、`_generated_count`、
  `_bypassed_count`；
- `bridge.adapter_object_cache_hit_count`、`_generated_count`、
  `_bypassed_count`，以及 Pack 数量、entry 与 object 字节数。

真实 Demo 的优化前后数据记录在[构建性能观测与基线](Build-Performance-Baseline.zh-CN.md)。
缓存、状态、观测、协议、产物和产品版本都继续保持 `1`，没有新增旧方案兼容分支。

## 大模块编译重放

Canonical SIL 使用单独的私有输出文件。包含 bridging PCH 的 driver job 可能把 `-o -`
输出写到 stderr；进程成功退出但没有有效 SIL 时，现在会在声明分析前明确报错。
因此 subprocess stdout 字节不再包含 SIL 文件；对应 payload 仍通过
`frontend.identity_sil_bytes`、`frontend.semantic_sil_bytes` 统计。
系统框架混合重放、无 GUI 安装、编译器 launcher 串联及资源边界见
[大型工程接入](Large-Project-Integration.zh-CN.md)。

编译调用超过 3,000 个参数或 128 KiB 参数字节时，自动使用仅当前用户可访问、
每次调用独立的 Swift response file。嵌套 response file 保留调用的工作目录；
成功或启动失败后均清理临时文件，避免 Foundation 参数数量超限直接 abort。
捕获的 bridging header、PCH 输出目录和 C++ 互操作模式与 Clang 参数一起重放。
直接 typed-AST、typecheck 和 SIL 调用从选中的工具链解析默认宏插件路径，
也适用于 `/usr/bin/swiftc` Xcode shim。这覆盖 `@TaskLocal` 等工具链宏；
archive 校验仍拒绝任意插件加载参数。编译输入变化仍要求完整构建。

这些编译重放语义更新了 transform pipeline identity。旧 Shell 需完整重建
以更新构建事实；持久化 ABI 和 archive schema 不变。

每次 SIL 解析只提取一次 nominal 声明和 error storage 事实。闭合协议派发重写复用这份
记录，并在函数体变化时重新分析 factory。五个固定的声明语法正则只编译一次，以不可变
对象共享；源码相关的动态表达式不会留在全局缓存。这减少了大模块的重复解析，同时
保留声明错误、factory 失效规则及原有 canonical SIL/receipt 身份。

## 搜索路径与 Catalog 预热续跑

不存在或不可读的 `-F`、`-I`、`-Fsystem` 输入会产生 `HLXBLD001` warning，指出对应
的 Xcode 搜索路径设置，并在输入发现时跳过。已有但不可读的目录会禁用缓存复用；
不存在的目录仍保留在输入指纹中，之后创建它会使旧事实失效。误放的
`@executable_path`、`@loader_path`、`@rpath` 搜索路径会作为字面编译参数保留，并提示
检查 `LD_RUNPATH_SEARCH_PATHS`，不会被当作 response file 打开。真正缺失的 response
file 仍会报错；嵌套相对 response file 按 Swift 行为相对于捕获的工作目录解析。

Catalog 依赖扩展只规划本轮新发现的模块，避免反复扫描已经处理过的模块输入目录。
整个依赖闭包仍限制为 256 个模块，分轮扩展不能绕过总量限制，也不会复用未验证的
模块身份。

同一次同步 Catalog 规划内，各模块还会共用有总量限制的目录记录。复用前检查根目录
及各子目录的 device/inode、权限、mtime 和 ctime，变化后重新列目录。遍历以流式执行，
保留原有单搜索根目录上限，不跟随目录符号链接；整个规划最多保留 250,000 条根目录/目录项
记录，不跨规划调用或任务共享。每个模块选中的 module map 和接口文件仍通过稳定读取
路径重新读取、计算内容 hash。路径筛选直接检查路径组成，不再仅为检查文件名后缀
创建可能触发文件系统查询的 URL。

位于搜索根目录的 module map 现在会包含该目录内没有模块名前缀的辅助头文件；修改
这些头文件会使输入 hash 失效。这修正了这种目录布局下失效不完整的问题，其他稳定
模块 snapshot 保持原有身份。

Live Reload Prepare 成功后，私有任务与日志位于
`<profile-output>/.NativeAPICatalogPrewarm/<hash>.json` 和 `<hash>.log`。
正常构建仍自动启动后台 worker。中断后手动续跑时，在任务捕获的工程工作目录执行：

```sh
helix xcode catalog-prewarm --job "/absolute/path/to/job.json" --max-modules 1
```

`--max-modules` 接受 1 到 256，限制单次新生成的模块数，已经验证的缓存命中不占额度。
达到上限后成功退出并保留任务，再次运行同一命令会复用已经完成的模块；全部完成后
才删除任务。中断 compiler probe 后，尚未完成的那个模块可能需要重新生成。并发 worker
由任务文件锁协调，已有 worker 时新调用会提示任务正在运行。compiler、SDK 或模块
输入发生变化后，需要重新 Prepare 生成任务。

预热填充后续构建使用的同一用户缓存，默认为 `~/Library/Caches/Helix/BuildFacts`，
也可以是任务捕获的 `HELIX_BUILD_CACHE_DIR`。因此可以提前准备本机缓存；这里没有新增
跳过校验的跨机器 Catalog 导入。工具链、SDK、target、语义参数、模块字节和 transform
身份仍须匹配。冷生成成本取决于各模块实际 API 面，不能把 UIKit 历史约 230 秒的单点
数据乘以 import 数量，当成已经测得的大工程预热时间。

compiler proxy 现在在编译前保存 `FrontendAttempt.hlxswiftc`，供 `helix xcode preflight`
使用（默认 `inputs,typed-ast`）。只有成功编译才更新 `FrontendInvocation.hlxswiftc` 并运行
post-compile。仅输入预检不生成 AST/SIL，也不扫描依赖缓存；typed 检查仍需要可用的编译
依赖，局部检查通过不代表完整 receipt 或 runtime 支持。见[预检说明](Large-Project-Integration.zh-CN.md#成功构建前的预检)。

Compiler input Snapshot schema 1 新增可选诊断字段 `incompleteReasons`，完整快照和旧
快照均省略该字段，原有编码和 content hash 不变；不完整快照仍不能复用。Catalog
规划按 unresolved 模块暴露这些原因。`prepare.catalog_miss_module_count` 只计真正
待生成的缓存条目，前置条件阻塞仍计入 `prepare.catalog_unresolved_module_count`。
import 扫描每次只持有一份源码，并保留每个失败逻辑路径。目录符号链接仍禁用缓存，
不追随可能成环的目录树。私有 Catalog pipeline identity 因具体 nominal 过滤和
Symbol Graph 工作目录传递而推进，公开 Catalog wire rules 与 runtime ABI 不变。
参见[从 capture 自举](Large-Project-Integration.zh-CN.md#从-compiler-capture-自举-catalog)。
