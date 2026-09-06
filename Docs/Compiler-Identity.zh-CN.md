# 编译器身份与诊断依据

[English](Compiler-Identity.md)

编译器打印出的名字只有在来源和作用域得到确认后才能参与身份判定。下表覆盖源码到
receipt 的主链路及 SIL、Catalog、缓存、工程安装边界，作为持续 review 的技术基线。
新的编译器输出或真实接入证据可能要求进一步收紧规则。

| 键的类别 | 权威来源与消歧维度 | 拒绝规则与使用方 |
| --- | --- | --- |
| 源码成员 | 单次编译中的规范物理路径；receipt 中的逻辑路径和内容 hash | Request 拒绝重复逻辑路径及物理路径别名；typed AST 必须精确覆盖请求的文件集合 |
| 源码 nominal 声明 | 编译器 USR，private 声明再带逻辑文件作用域；限定名仅用于作用域内查找 | `SourceNominalIndex` 分开查找各文件的私有声明；USR 和同作用域同名冲突报告双方证据；有歧义的私有类型打印布局不能用于冻结值布局 |
| Imported nominal | 先确认 runtime/ABI 身份，再用已证实的 module 根规范化限定/非限定 Swift 拼写 | discovery、merge、alias 和 binding 共用 `ImportedNominalIdentity`；模块、表示或 isolation 事实冲突仍失败，不合并无关的嵌套类型 |
| Imported operation 与 selector | 声明 USR/descriptor、签名、owner、dispatch、accessor 与测得的 ABI；selector probe 还绑定导入模块上下文 | 共用实现符号不代表同一 API；candidate 先去重再划分互不重叠的 probe batch，生成的序号只标识该 batch 中的成员 |
| SIL 函数 | 同一 SIL 文件中实际的 `sil @symbol : $type { ... }` 定义 | 重复定义报告双方 SIL 行号和类型；函数索引随公开数组修改而更新，排除重名项；typed AST 通过精确符号或唯一源码位置解析，拒绝按顺序选取歧义候选 |
| SIL debug scope | 单个 SIL 文档内的数字 scope ID；继承位置不改变 scope 自身身份 | 重复 ID 报告双方原始记录；只有存在实际函数定义时，`parent @name` 才能提供函数声明位置；`__unknown_macro__` 等只出现在调试信息中的名字不构成函数身份，各自位置仍按 scope ID 保留 |
| SIL 打印类型和成员别名 | 相关模块及源码作用域中唯一、经编译器证明的 nominal/type alias | `TypeEnvironment` 排除有歧义的私有类型摘要，所需布局或 dispatch 无法证明时失败，不能凭短名字选取布局 |
| SIL 源码模块映射 | 编译器明确输出的 `#fileID` 到路径映射 | 同一路径对应冲突模块时报告路径及双方模块；调试位置是来源依据，不是持久化身份 |
| Native Catalog 与 receipt 键 | 经验证的版本化 artifact identity、精确 compiler/toolchain/SDK/target、规范 descriptor 或 TypeID | snapshot/receipt 验证先于唯一键映射；hash 必须伴随经过认证或验证的记录，不能按显示名在运行时兜底查找 |
| 编译器事实与缓存 | 精确 toolchain、invocation、源码/依赖内容和 transform identity；checkpoint 还绑定物理路径 | `CachedAdapter` 先验证请求与源码唯一性，再建立映射并复核输入；checkpoint 命中重新解析；身份解释规则变化时更新 transform hash，防止旧模块 receipt 绕过新检查 |
| PBX 对象与配置 | 根 `objects` 字典中的对象 ID；所属 configuration list 中的配置名 | 重复字典键和重复配置名报告所属作用域与对象 ID；嵌套 `TargetAttributes` 的同名 key 不代表顶层 target 对象 |

本次 debug scope 修改不改变已发布的 wire schema、nominal ID 或公共符号拼写。
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
