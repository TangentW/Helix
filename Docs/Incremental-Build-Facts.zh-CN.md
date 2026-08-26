# 增量构建事实与产物发布

[English](Incremental-Build-Facts.md)

Helix 把“能覆盖多少原生 API”和“构建要花多少时间”分开处理。Prepare 仍然用当前
Xcode 实际捕获的 Swift frontend 去证明完整调用面；只有所有语义输入完全一致时，
才复用之前已经证明过的结果。缓存命中只是省时间，不是新的权威来源，也不能凭空
增加能力。

本文说明 Live Reload 与 Hot Patch 共用的 schema 1 实现。项目不需要维护 API 清单，
不需要冻结，也不需要开发者配置缓存。默认缓存放在当前用户的
`~/Library/Caches/Helix/BuildFacts`；`HELIX_BUILD_CACHE_DIR` 只是测试和排障时可选的
覆盖入口。

## 分层复用什么

| 层级 | 复用内容 | 什么变化会让它失效 |
| --- | --- | --- |
| SDK identity | `xcrun` 返回的 SDK 路径和 build | Swift driver 实例、SDK 名、`DEVELOPER_DIR`、`TOOLCHAINS` |
| 模块 frontend | 已验证的 receipt、诊断和工具链 identity | 编译捕获内容、编译器指纹、非 SDK 模块/头文件接口快照、metadata、策略、catalog、配置，以及每个源码的逻辑路径、物理路径和内容 hash |
| Symbol graph | 已验证的 SDK 模块公开符号图 | 编译器指纹、SDK/frontend invocation、模块名 |
| 单候选探测 | 某个候选最终测得的零个或多个操作 | 编译器指纹、变换流水线、SDK/frontend invocation、最低系统、规范化候选和边界类型 |
| Hot Patch Prepare | 完整 Shell 目录和函数计数 | Prepare 精确输入，或输出中的路径、字节、权限、额外文件发生任何变化 |
| Adapter Pack source | 按原生 module 分组的确定性 Swift Adapter | 编译器指纹、SDK/target/deployment、变换流水线、module、有序 imported module 集合与有序稳定调用 Key |
| Adapter Pack object | 单个 module Pack 的已验证 Mach-O | Pack source identity，再加工具链、Xcode build、规范化编译参数、完整非 SDK compiler-input 快照和 module map |
| 开发期 Adapter image | 只包含首次使用且缺失的 Swift Adapter body 的签名 Mach-O | compiler/Xcode/SDK identity、target/deployment/platform/architecture、依赖图、module、规范化语义参数与保留的链接参数、精确生成源码、有序 Descriptor/Key/type/contract 记录 |
| Application Bridge object | 排除一次性 Hub contract 后的稳定、已验证 Mach-O | profile、工具链、Xcode/SDK build、变换流水线、规范化编译参数、稳定生成源码、compiler input 和 module map |
| 最终 Bridge state | 已链接的 Bridge 与 C bootstrap Mach-O object | 包含 Hub contract 的全部生成源码、application/Pack 输入、Clang binary 和 bootstrap source |

持久缓存 key 使用 canonical JSON 和带版本的 hash domain，不依赖文件修改时间。
源码内容、编译捕获内容、编译器可执行文件指纹、SDK build、target、最低系统、优化
级别和 frontend 语义参数，都在会影响对应结果的层级进入 key。

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
采用有大小上限的迭代解析，不会先把无界目录或深层结构完整装入内存。

模块 receipt 是范围最大的快路径；它失效后，权威 frontend 仍能继续复用 symbol
graph 和单个声明的探测结果。也就是说，业务代码做了一次普通修改，不会因此重新
扫描和探测一遍完全没变的 UIKit 或 Foundation。

探测失败也不是一概写缓存。只有经过递归拆分后、可确定复现的单候选拒绝才会缓存；
临时编译器故障不会变成永久“不支持”。正常探测和校验完成后，才保存候选的最终
结果。

## 命中前仍然要验证

每种缓存结果都由实际消费者重新解码并做语义校验：

- canonical 编码、schema、key、payload SHA-256 必须一致；
- receipt 必须完整通过结构校验，并匹配当前源码、metadata 和工具链；
- symbol graph 和实测操作走与新生成结果相同的验证；
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

## Xcode 产物怎么更新

Shell 生成目录以一次原子目录切换发布。如果新旧目录的字节和权限完全相同，就什么
都不改，原 inode 和修改时间保持不变。只有部分文件变化时，未变化且由 Helix 生成的
普通文件会 hard-link 到 staging 目录，只重写真正变化的文件。意外文件和符号链接
不会被跟随或保留。

Hot Patch 的 Prepare 在“精确输入一致 + 完整输出 manifest 一致”时，可以在进入
frontend 前直接返回。Live Reload 不复用最终 Prepare state，因为 Hub invitation
只能消费一次，每次构建必须重新预留；但耗时最大的模块、symbol graph 和 probe 事实
照常复用，之后只重新生成很小的会话绑定合同。

Bridge 编译现在分成多层精确事实。Objective-C 与受支持的 C 调用使用固定 Runtime
Invoker；其余 Swift 调用按 module 归入确定性的 Adapter Pack，Pack source 和 Mach-O
object 分别缓存。稳定 application Bridge 编译时不包含一次性 Hub contract，并拥有独立
的内容寻址 Mach-O 缓存。Live Reload 会单独编译本次很小的 Hub contract，再把它与稳定
application object、各 Pack object 做 relocatable link；Hot Patch 根本不生成 Hub
contract source。

受管 Debug 未使用候选只保留为 Receipt 数据，不会膨胀稳定 Bridge 或 Pack object。
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
- `managed_debug.symbol_graph_cache_hit_count`、`_miss_count`；
- `managed_debug.probe_cache_hit_count`、`_miss_count`、
  `cached_rejection_count`；
- `prepare.state_hit_count`、`state_miss_count`、复用/写入产物数和
  `noop_publication_count`；
- `bridge.state_hit_count`、`state_miss_count`；
- `bridge.application_object_cache_hit_count`、`_generated_count`、
  `_bypassed_count`；
- `bridge.adapter_object_cache_hit_count`、`_generated_count`、
  `_bypassed_count`，以及 Pack 数量、entry 与 object 字节数。

真实 Demo 的优化前后数据记录在[构建性能观测与基线](Build-Performance-Baseline.zh-CN.md)。
缓存、状态、观测、协议、产物和产品版本都继续保持 `1`，没有新增旧方案兼容分支。
