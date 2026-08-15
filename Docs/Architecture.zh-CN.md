# Helix 总体架构

[English](Architecture.md)

Helix 的核心思路只有一套：工程师修改普通 Swift 源码；但生产热补丁与开发期热重载必须使用不同的产物、信任边界和生命周期。它们共享编译器事实与身份合同，不共享下发通道。

本文描述截至 2026 年 8 月 16 日仓库中已经存在的实现，不把尚未完成的资格验证写成产品承诺。

## 两条工作流

| 工作流 | 产物 | 执行方式 | 生命周期 | 用途 |
| --- | --- | --- | --- | --- |
| 生产热补丁 | 内含 HLBC 的签名 `.hlxp` | App 内预装的 Verifier 与 HLVM | 可持久化、可回滚的 generation | 处理已发布 Shell 中的线上缺陷 |
| 开发期热重载 | 会话绑定、经过认证的 HLBC live artifact | 开发期 Verifier 与 HLVM | 仅当前 Debug 进程 | 保存受支持的函数体后刷新正在运行的页面 |

两条产品路径都不会把 Swift 源码或原生机器码下载进 App。生产路径接受可持久化、绑定策略的签名包；开发路径接受仅绑定一次认证 Dev Session 的临时 artifact。这一隔离是架构边界，不是一个可随意切换的运行时开关。

```mermaid
flowchart TB
    S["普通 Swift 源码"] --> I["冻结的源码与声明身份"]
    I --> R["Release 函数体差分"]
    I --> D["开发期保存 transaction"]

    R --> SIL1["精确工具链的 canonical SIL"]
    SIL1 --> HLBC["HLIR → HLBC → Verifier"]
    HLBC --> PKG["绑定 Shell 的签名 .hlxp"]
    PKG --> PR["HelixAppRuntime"]

    D --> DSIL["精确工具链的 canonical SIL"]
    DSIL --> DHLBC["HLIR → 认证开发期 HLBC"]
    DHLBC --> DR["HelixDevAppRuntime Verifier + HLVM"]
    DR --> UI["自动 UIKit 实例 invalidation 或 SwiftUI pulse"]
```

## 共享合同

两条路径都依赖稳定且绑定具体构建的身份：

- `FunctionKey` 标识 Swift callable，并纳入 Helix 关心的 ABI 与 effect 信息。
- `EntryIndex` 是生产 Bridge 使用的紧凑 Shell 路由。
- `TypeID` 与 `NativeImportID` 标识预先声明的类型操作和原生调用能力，补丁中不保存进程地址。
- interface fingerprint 与传递 implementation fingerprint 用于区分函数体修改和 ABI、布局、源文件成员关系或依赖变化。
- 工具链、SDK、target triple、编译参数、module 源文件集合与二进制身份把每个产物绑定到对应 Shell。
- 经过验证的 debug metadata 把 HLBC 的 function/block/instruction 坐标映射到逻辑 Swift 文件、行、列。生产 artifact 会移除构建机绝对路径；trap 会补充精确 VM program counter 和固定的 generation。
- 不可变的 `Runtime.Generation` 保证一次激活涉及的所有路由原子可见；一次调用链会固定同一个 generation，避免在并发激活或回滚时看到混合状态。
- 可变 closure 捕获与集合转换不依赖 Swift runtime layout，而是使用 Verifier 私有的 storage value：managed cell 只能由同 image closure 共享；Array builder 是线性值，每条控制流路径都必须完成或销毁。两者都不能进入 Shell/Native 边界、局部值布局、stack slot 或函数返回值。
- Array、Dictionary 与 Set 是有明确类型的 VM value，不投影 Swift runtime 的私有布局。Set 使用不可变 COW storage，在同一值内保持稳定迭代；相等与哈希不依赖顺序，并限制在递归 VM-defined Hashable 类型族内。Verifier、边界校验和分配前资源计费会端到端执行同一模型。
- closure signature 会为每个调用参数携带 ownership convention。Compiler 会把具体 Swift `@in_guaranteed` 输入保留为 VM borrowed value，只在 owned 边界物化 copy；Verifier 则要求 signature 与 closure body 的参数前缀完全一致。这条规则由类型驱动，也覆盖线性的 imported SDK value，并不是针对某个 API 或 framework 的例外表。
- frame-local storage 与 heap-promoted storage 共享同一套字段敏感的 aggregate shape。Compiler 会提升跨 basic block 的生命周期，区分 initialize、assign、replace 与条件清理；Verifier 在 CFG 合流处分别计算“确定初始化”和“可能初始化”的叶节点。读取仍只允许确定初始化；runtime shape 与部分存储都计入 invocation budget。
- 激活时会把继承路由物化成自包含 snapshot。Registry 默认只强保留当前 snapshot 与其直接回滚前代；更旧 snapshot 只会在仍有 lease 固定时存活。全进程 generation ID 高水位不会因压缩而回退。普通激活不能复用旧 ID；经过验证的持久化恢复可以重新挂载完全相同的历史 package/ID，但不会降低高水位。

这些身份有意绑定具体 build。Helix 不试图让不同 App 版本之间的私有 Swift ABI 自动兼容。

## Release 架构

接入 Helix 的 Release 构建会产出 App Shell 和 finalized interface archive。生成的 Derived Sources 建立永久动态入口与强类型原生 Bridge，不修改手写 Swift 文件。最终归档记录精确编译环境、源码身份、可补丁 root、签名、能力以及最终可执行文件身份。

发生缺陷时，补丁构建器在归档环境中重新类型检查完整 module，确认只有 eligible implementation 发生变化，把当前支持的 canonical SIL 子集降成 HLBC，执行独立验证，再对补丁包签名。App 在产物进入不可变存储或激活为 generation 前会重新完成设备侧验证。

随 App 安装的 Runtime 已包含字节码解码器、Verifier、HLVM、Bridge Catalog、包信任链、激活日志、Crash Guard 与回滚逻辑。生产补丁无法凭空新增 Shell 发布时不存在的原生能力。

完整流程见[生产热补丁](Production-Hot-Patching.zh-CN.md)。

## 开发期架构

Xcode 工程只包含原始 Feature 源码和稳定 App Runtime import。Build pre-action 在 DerivedData 中 materialize Shell；App phase 根据捕获的 Feature 调用重建编译参数，把全部生成 Bridge 源码私下编译成一个经过校验的 relocatable object。App 链接时保留稳定 C provider 符号，`ApplicationSession` 因此无需 Bridge framework、生成源码 target 或生成 Swift import 就能取得合同。

Xcode 集成会从一次真实 Debug Build 中捕获 frontend、link、SDK、module、源码和 target 事实。源码监控器把编辑器写入与原子 rename 整理成稳定、单调递增编号的快照。开发编译器在原 module 上下文中重新检查整个 transaction，使用与 Release 编译器相同的受支持 canonical SIL 子集，生成一个不可变 HLBC generation。认证 daemon 传输字节，Debug App 再次验证后原子激活临时 Runtime generation。

Helix 不会维护一个可变动态库并不断追加 Swift 文件。Native Dynamic Replacement 只保留为必须显式选择的内部编译器实验和差分验证后端；自动与默认路由绝不会回退到它。

Debug App 先激活代码，再刷新 UI。`ReloadIndex` 把变化 root 映射为稳定 nominal type ID。UIKit 会从已展示 controller/view class（包括 superclass 链）还原这些 ID，无需业务注册表即可执行推导出的 invalidation；SwiftUI 使用显式 pulse boundary。没有安全刷新策略或存活目标时，Helix 会明确报告“代码已激活，但需要手动刷新”，不会猜测并重放任意生命周期方法。

从保存到页面变化的完整过程见[开发期热重载](Development-Live-Reload.zh-CN.md)。

## 构建与运行时隔离

App 只能链接一个聚合产品：

| App 配置 | 产品 | 是否包含开发加载器和传输能力 |
| --- | --- | --- |
| Release / Production | `HelixAppRuntime` | 否 |
| Debug / Dev Shell | `HelixDevAppRuntime` | 是 |

Release 审计会扫描最终 bundle，而不是信任 target 名称。生产 Runtime 拒绝开发 artifact，开发协议也不会把生产 campaign 当成旁路。构建侧 Compiler、Release、Daemon 与 CLI 模块不得进入 Release App。

## 当前资格边界

仓库目前包含可运行的受限 HLBC 生产客户端链，以及可运行的 Simulator HLBC Live Reload 链。后者已经在同一个 App 进程中验证修改后的实现和第二代 baseline 恢复。Hot Patch Demo 还能把签名补丁模拟为一次本地下载，并走正常验签、安装、激活与回滚路径。

仓库还包含四个接近业务代码的 corpus 文件，以及确定性的 128 代进程内 soak；后者覆盖失败保存、激活、回滚、调用、snapshot 压缩和 generation ID 单调性。这些证据仍不代表 App Store 下发已经合规，也不代表任意 Swift 语法、真实 iPhone 执行、外部 top-200 应用 corpus、真机长时间内存压力/前后台循环或外部 Registry/HSM/审批控制面已经完成。具体边界见[能力与限制](Capabilities-and-Limits.zh-CN.md)。
