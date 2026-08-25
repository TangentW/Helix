# Helix Xcode / Hub 端到端测试用例

这份清单验证 Helix 的默认接入路径：选择现有 Xcode 工程，点击 **Enable Helix**，随后继续使用普通 Build、Run 和保存操作。它补充 `swift test`、Simulator fixture 与 Release 审计，不把其中任何一项当作其他证据的替代品。

测试使用仓库中的原工程：

```text
/Users/tangent/Desktop/Helix/Demo/HelixDemo.xcodeproj
```

不要用复制到 `/tmp` 的工程作为最终结论。每轮结束都要逐字恢复：

```text
Demo/LiveReloadFeature/Sources/LiveReloadFeature.Screen.swift
Demo/HotPatchFeature/Sources/HotPatchFeature.Pricing.swift
```

## 1. 通过标准

一轮完整验收至少满足：

1. Helix 能自动识别 App target、源码 target、Scheme 与 configuration；普通单 target App 无需拆 target 或预建共享 Scheme。
2. 启用、重复应用、修改映射、关闭单项能力和完全移除都是幂等且可回滚的，不改业务 Swift 或原始 plist。
3. App 不需要 import Helix、编写启动代码、维护源码/API 列表、配置 host/port/secret、自定义 LLDB 或执行任何首次“冻结”。
4. 普通 Xcode Run 使用默认 Apple debugger 自动连接；连续保存受支持实现时，页面在同一 App PID 内变化且内存状态保留。
5. 源码、Build Settings、target membership 或依赖变化后，只需普通 Build/Run 重新捕获当前编译事实，不需要修改 Helix 配置。
6. 语法错误或无法证明安全的形状显示明确诊断，上一成功 generation 继续生效；恢复 baseline 后产生恢复 generation。
7. Release App 只包含 `HelixAppIntegration`，不包含 `HelixDevSupport`、开发协议、Bonjour 或调试凭据。
8. Patch Scheme 只生成、签名并可选 stage `.hlxp`，不重建或重装 App。
9. 日志和归档证据不包含 Service secret、private key、完整 invitation、TLS key material 或认证帧。

这些要求不等于允许任意 Swift 在设备上执行。目标二进制身份、Swift ABI、代码签名、平台沙箱、Verifier 语义和资源预算仍是不可省略的正确性与安全边界，但都不应变成首次接入时由开发者维护的白名单或配置。

Simulator 通过不代表真机资格完成。两者走相同 HLBC artifact、协议、Verifier 与 HLVM，但真机仍要单独记录设备、iOS、Xcode、网络、前后台和长时间运行结果。

## 2. 环境记录

| 项目 | 值 |
| --- | --- |
| 日期 | |
| Helix revision / 工作区快照 | |
| macOS | |
| Xcode 版本与 build | |
| Swift 版本 | |
| Simulator / iPhone 型号与 OS | |
| Scheme | `Helix Live Reload Demo` / `Helix Hot Patch Demo` |
| Run Destination | |
| DerivedData | |
| Helix App 构建 | |
| 测试人 | |

四位码只用于从桌面直接打开开发测试包后的显式手动配对，不属于 Xcode Run 或工程接入步骤。它可以出现在临时截图里，但验收归档应遮掉或只保留末一位。不要读取或粘贴 `~/Library/Application Support/Helix/Service.json` 的敏感内容；如需检查，只记录 owner、`0600` 权限、schema、mode 和已脱敏的 tool path 结论。

## 3. 自动化验证基线

从仓库根目录执行：

```bash
swift build -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
swift test

Hub/Scripts/build-app.sh release
Tests/Fixtures/LiveReloadE2E/run-release-audit.sh
Tests/Fixtures/LiveReloadE2E/run-simulator-e2e.sh <SIMULATOR_UDID>

.build/debug/helix xcode validate \
  --plan Demo/.helix/xcode/HostPlan.json
.build/debug/helix xcode doctor \
  --plan Demo/.helix/xcode/HostPlan.json \
  --profile live \
  --static
```

预期：

- Debug、Release、全量测试、Hub 打包、Release 泄漏审计和真实 Simulator 场景全部成功；
- installed `HostPlan.json` 能直接通过 validate/doctor，工程路径解析到 `Demo/`，不会错误落到 `.helix/xcode/`；
- `Hub/.build/Helix.app/Contents/Helpers/helix` 存在且可执行，App 与嵌套 helper 的签名结构通过严格验证；
- Simulator fixture 在同一 PID 中完成八个 generation 和五类 UI 场景；
- Demo 工程没有生成 Swift reference、Bridge target、`HELIX_EXECUTABLE`、自定义 LLDB init、`live-start.sh` 或 `live-stop.sh`。

## 4. 零配置接入与可逆性

### XR-01：首次启用

1. 打开打包后的 Helix，确认 Service 为 Running。
2. 选择 `Demo/HelixDemo.xcodeproj`。
3. 保留默认识别的 Hot Patch 与 Live Reload，点击 **Enable Helix**。

预期：

- App、源码、Scheme 和 configuration 自动匹配；高级映射不是必填步骤；
- Helix 自动添加或复用 Swift package，并只给 App 链接统一的 `HelixAppIntegration`；
- Live Reload configuration 额外链接并嵌入动态 `HelixDevSupport`，Release configuration 不包含它；
- 没有共享 Scheme 时自动创建；已有 Scheme 的非 Helix action、Run/Archive configuration 与 build graph 保持不变；
- 本地网络声明在 Xcode 正常生成并处理 App plist 后、签名前幂等补齐；相关 Helix 收尾 phase 必须位于已有 Embed Frameworks/extension/copy phase 之后，不形成 target 内依赖环；不持久化副本、不覆盖 plist 构建设置，也不修改业务 plist；
- 用户无需执行任何代码层动作。

### XR-02：重复应用、重配置与移除

1. 不改选择再次点击 **Apply Changes**，记录 `git diff`。
2. 修改一个可逆映射后应用，再改回原映射。
3. 关闭一个工作流并应用，随后重新启用。
4. 关闭全部工作流，点击 **Remove Helix**；再重新启用。

预期：

- 无变化的重复应用不产生 diff；
- Hub 只移除带明确所有权标记和已记录 PBX identity 的 phase、product、trigger 与 Scheme action，不会因名称相同删除开发者自己的 phase；
- 原 Base Configuration、业务 phase、Scheme action、源码、plist、Patch recipe 与签名材料得到保留或精确恢复；
- 失败注入时整个文件事务回滚，不留下半套工程状态；
- integration root、target 映射和能力选择都不被永久锁定。

## 5. 普通 Xcode Build / Run

### XR-03：检查生成接入

检查 Xcode project、共享 Scheme 和 `.helix/xcode` 生成记录。

预期：

- compiler proxy 在所选 configuration 的真实 Swift 编译成功后捕获编译器、SDK、参数和源码 membership；
- 同 App/source target 使用一个 Hub-owned 空调度源触发增量编译，并把它排除在业务源码集合之外；编译完成后自动生成 Shell、Bridge object 和 bootstrap object；
- 已有独立 source target 时，Hub 在 source target 编译后准备 Shell，并在 App Sources 前生成 Bridge object；这只是对现有模块化结构的适配，不是接入要求；
- 生成 Swift 只存在于 DerivedData，不进入 Project Navigator；
- Live Reload Scheme 只有用于注册最终 App 身份的 Run pre-action，Run action 继续使用默认 debugger；
- Hot Patch Build/Archive 后执行产物审计；所有 Hub-owned shell phase 都带明确生成标记。

### XR-04：真实 Xcode Run

1. 保持 Helix 运行。
2. 选择 `Helix Live Reload Demo`，正常点击 Run。
3. 等待 App 首屏和 Hub 中的 Build Context。

预期：

- 隐藏 bootstrap 自动启动开发 Runtime；业务代码不 import 或初始化 Runtime；
- Xcode launch 自动发现唯一 `_helix._tcp` 服务，校验 Host Identity pin 和精确 App 构建身份，并使用一次性 invitation；
- Hub 显示连接、编译、传输、激活和刷新事件；
- 无 LLDB 注入、probe、launch environment handoff、手工 endpoint 或凭据日志。

## 6. 同进程保存与刷新

### XR-05：建立状态

记录 App PID，点击两次计数按钮，确认 `State retained: 2`。

### XR-06：连续两个 generation

只修改 `viewDidLayoutSubviews()` 中的展示文本并保存，不点 Build/Run：

```swift
titleLabel.text = "XCODE RELOAD ONE" // HELIX_LIVE_BASELINE
```

生效后再改为：

```swift
titleLabel.text = "XCODE RELOAD TWO" // HELIX_LIVE_BASELINE
```

预期：两次 UI 都更新；PID 不变；计数仍为 2；revision/generation 单调递增；Xcode 不安装或重启 App。

### XR-07：失败保留上一代

在同一函数体制造明确语法错误并保存。

预期：Hub 与 App 诊断显示具体源码位置和修复方向；页面仍是 `XCODE RELOAD TWO`；active generation、PID 和内存状态不变。修复语法后后续保存继续工作。

### XR-08：源码集合和构建上下文变化

1. 恢复 baseline，确认产生恢复 generation。
2. 新增或移动一个 target 内 Swift 文件，或改变相关 Build Setting。
3. 普通 Build/Run 一次，然后继续保存已有实现。

预期：Helix 从新的成功 Xcode 编译自动更新源码 membership 和构建事实；不要求编辑 Host Plan、源码列表、API 列表或重新启用工程。若 App 二进制身份已变化，旧 session/artifact 会明确拒绝，不能按 bundle ID 猜测兼容。

## 7. 可选的直接启动测试

这不是普通接入或 Xcode Run 的前置步骤，只验证直接从桌面打开开发测试包时不会在用户未确认前访问本地网络。

### XR-09：直接打开与手动配对

1. Xcode Stop，确认只结束 App 会话，Helix Service 继续运行。
2. 从 Simulator 或设备桌面直接打开同一个 Debug 包。
3. 使用自动安装的开发 overlay，或测试 App 自己的高级调试 UI，输入 Hub 当前四位码并确认。

预期：

- 新进程固定为 manual 模式；确认前不浏览 Bonjour、不请求本地网络，也不复用上次 Xcode invitation；
- 错误、过期或已使用的码可以安全重试且不能进入任何错误的 App 构建；
- 正确码仍需通过 pinned TLS、精确 Build Context 和 App Mach-O 身份验证；
- later attach debugger 不把当前进程切换为 automatic 模式。

## 8. Hot Patch Action

### XR-10：正常 Release 构建并创建 Patch

1. 用 `Helix Hot Patch Demo` 的 Release destination 正常 Build/Archive。
2. 记录 App 产物 UUID、版本、平台和审计结果。
3. 修改 eligible 实现和 recipe revision。
4. Build Hub 自动创建的 Patch Scheme。

预期：

- Release Build 自动捕获与该 App 二进制匹配的 Shell/interface/Bridge 身份，不需要单独“冻结”；
- Scheme 中的空 `HelixPatchAction` 只作锚点，Patch action 不触发 App compile、link、install 或 launch；
- 输出签名 `.hlxp` 与目标 App 的平台、架构、bundle/version、recipe、接口和 trust identity 精确匹配；
- 错误目标、签名、版本、ABI、recipe 或已经激活的 package 被确定性拒绝；
- Demo mock install 能激活补丁并回滚 baseline。

## 9. 证据模板

每轮至少保存：

- Helix 工程页、Service 状态和已脱敏 Build Context；
- Xcode 工程 URL、Scheme、destination 和 Running 状态；
- baseline、两次成功修改、失败、恢复及 UI 场景页面；
- 各阶段 PID、state、revision/generation；
- Release 泄漏审计与 Patch 产物摘要；
- 重配置/移除前后只有预期 diff 的确认；
- 所有被临时修改的业务源码已逐字恢复。

| 用例 | 结果 | 证据 | 问题 / 修复 |
| --- | --- | --- | --- |
| XR-01 | | | |
| XR-02 | | | |
| XR-03 | | | |
| XR-04 | | | |
| XR-05 | | | |
| XR-06 | | | |
| XR-07 | | | |
| XR-08 | | | |
| XR-09 | | | |
| XR-10 | | | |

## 10. 失败定位顺序

1. **Hub 无法启用工程**：先看自动识别到的 project、target、Scheme 和 configuration；只有多工程 workspace 或多个同等候选时才进入高级映射。不要先手改 PBX 或生成目录。
2. **Xcode phase 找不到工具**：确认 Helix 正在运行，Service rendezvous 文件 owner/mode 正确，打包 App 内有 `Contents/Helpers/helix`。不要给工程加 `HELIX_EXECUTABLE` 或依赖用户 shell `PATH`。
3. **首次 Build 没有当前构建记录**：检查 compiler proxy 是否捕获到成功 Swift frontend job，以及 target-level trigger/post-compile 或 source-target prepare/Bridge phase 的顺序。不要维护手写源码列表。
4. **自动模式一直 Connecting**：确认 App 是由 Xcode debugger 启动；检查 Run pre-action 注册的最终 executable、Host pin 与精确 Build Context。直接启动的进程应走可选手动配对，而不是猜测自动模式。
5. **保存无反应或编译失败**：确认编辑的是当前成功编译记录中的业务源文件，查看 Hub 的 source monitor 和具体编译诊断。target membership 或 Build Settings 刚变化时，普通 Build/Run 一次即可更新记录。
6. **代码 active 但 UI 不变**：区分代码激活和 UI refresh；检查当前是否有匹配的存活 UIKit 实例和安全 invalidation，或该生命周期是否确实需要显式幂等 hook/factory。
7. **PID 改变或状态丢失**：说明发生了 Build/relaunch，不能算 Live Reload。
8. **Release 出现开发模块**：立即检查 configuration-scoped product/embed 处理与 Release 审计；不能通过关闭审计掩盖泄漏。
9. **Patch Scheme 重建 App**：检查 Patch target 是否仍为空、action 是否只读取已完成的 App 构建身份，以及 App 是否只作 EnvironmentBuildable。
10. **重配置或移除影响业务配置**：检查 Hub ownership marker、PBX identity 和事务回滚；名称相同不构成删除第三方 phase 的依据。
