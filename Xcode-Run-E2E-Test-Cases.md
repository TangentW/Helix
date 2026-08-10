# Helix Xcode Run 端到端测试用例

这份文档记录必须通过真实 Xcode GUI 执行的 Helix Live Reload 验收。它补充自动化测试，不替代 `swift test`、Simulator fixture 或 `xcodebuild build`：只有 Xcode Run 才会覆盖共享 Scheme 的 Run pre/post-action、自定义 LLDB init、调试器附加时序、App 进程 handoff，以及保存源码后的同进程 UI 刷新。

测试只操作仓库中的原工程：

```text
/Users/tangent/Desktop/Helix/Demo/HelixDemo.xcodeproj
```

不要用复制到 `/tmp` 的工程作为验收结论。每次测试结束都必须把 `Demo/LiveReloadFeature/Sources/LiveReloadFeature.Screen.swift` 恢复为仓库 baseline。

## 1. 通过标准

一轮完整验收同时满足以下条件才算通过：

1. Xcode 直接 Run `Helix Live Reload Demo`，无需手动执行 Helix 命令来启动会话。
2. App 与 daemon 完成认证连接，Overlay 不长期停留在 `Idle`。
3. 连续两次修改并保存 `viewDidLayoutSubviews()` 后，页面均在同一 App PID 中更新，不发生重新 Build、安装或启动。
4. 页面内存状态保持不变；后来的 generation 不会被较早的慢任务覆盖。
5. 一次语法错误只报告编译失败，上一代代码仍然生效。
6. 把源码恢复为 baseline 后，会生成新的恢复 generation，页面和磁盘源码都回到 baseline。
7. Xcode Stop 会停止 daemon 并清理本次临时 handoff 文件。
8. 控制台没有 Helix 引入的未满足 Auto Layout 约束、无效 LLDB 命令或凭据明文。

Simulator Native 通过不等于真机 Native 已通过资格测试。真机必须单独记录 Xcode、iOS、设备、Team ID、签名与 Library Validation 结果。

## 2. 测试环境记录

执行前填写：

| 项目 | 值 |
| --- | --- |
| 日期 | |
| Helix revision / 工作区快照 | |
| macOS | |
| Xcode 版本与 build | |
| Swift 版本 | |
| Simulator 型号、iOS、UDID | |
| Scheme | `Helix Live Reload Demo` |
| Run Destination | |
| DerivedData 路径 | |
| macOS 登录会话 | 已解锁，Xcode 与 Simulator UI 可操作 |
| 测试人 | |

证据中可以记录 session ID 的末四位、端口是否存在以及变量是否存在，但不得复制 `HLX_DEV_SESSION_SECRET`、SPKI 内容、完整 LLDB init 或其他凭据。

## 3. 前置检查

### XR-00：自动化基线

在仓库根目录执行：

```bash
swift build --product helix
swift test
swift test -Xswiftc -warnings-as-errors
swift test -c release -Xswiftc -warnings-as-errors
.build/debug/helix xcode validate --plan Demo/HelixXcode.json
xcodebuild -project Demo/HelixDemo.xcodeproj \
  -scheme "Helix Live Reload Demo" \
  -destination "platform=iOS Simulator,id=<UDID>" \
  build
```

预期：

- 六条命令全部成功，SwiftPM 三轮测试的测试数与 suite 数一致；
- Xcode package 解析到当前 `/Users/tangent/Desktop/Helix`；
- 工程中不存在小写 `demo/` 路径引用；
- Debug App 的 `HelixDevAppRuntime` package framework 导出
  `_helix_dev_runtime_handoff_probe`，Hot Patch Release App 的
  `HelixAppRuntime` 与主 executable 均不包含该符号；
- `LiveReloadFeature.Screen.swift` 的 baseline 标记为：

  ```swift
  titleLabel.text = "SAVE TO RELOAD" // HELIX_LIVE_BASELINE
  ```

### XR-01：原工程与 Scheme 接线

1. 退出其他同名临时 Demo 工程，避免 Xcode 复用错误的本地 package identity。
2. 从 Xcode 打开 `Demo/HelixDemo.xcodeproj`。
3. 选择 `Helix Live Reload Demo`。
4. 选择目标 Simulator。
5. 检查 Run action 的 Custom LLDB Init File 为 `$(HELIX_LLDB_INIT_FILE)`。
6. 检查 Run pre-action 为 `live-start.sh`，Run post-action 为 `live-stop.sh`。

预期：Xcode 显示的工程 URL 使用 `/Helix/Demo/`，Package Graph 无缺失产品，Scheme 和 destination 均正确。

## 4. 会话启动与 handoff

### XR-02：真实 Xcode Run

1. 清空或记下 Xcode 控制台当前内容。
2. 点击 Xcode Run。
3. 等待 App 首屏和 Overlay 出现。
4. 观察 DerivedData 下 `Build/Products/HelixGenerated/live/Daemon.log`。

预期：

- Xcode 最终显示 `Running LiveReloadDemo`；
- daemon 日志先记录 listening，随后记录 App 认证与连接；
- Overlay 进入 Connecting/Connected/Ready 状态，而不是一直 Idle；
- App 进程中七个 `HLX_DEV_*` 会话变量和 `HLX_DEV_HANDOFF_READY` 均存在，ready 标记与 session ID 匹配；检查工具只能输出布尔值；
- LLDB installer 在真实 App target 和导出 probe 都可用后完成注入，App 不会停在 probe，也不会留下任何 handoff breakpoint；
- 控制台没有 handoff timeout、resume error、`Invalid breakpoint name`、expression 失败、Helix Overlay 约束冲突或启动 fatal error。

机制预期：生成的 init 先配置 LLDB-owned launch environment，再启动15秒有界 installer。installer 等真实进程正在运行且 C probe已经解析，短暂停住 App，通过 LLDB command interpreter执行一条短路表达式注入完整环境，在 `finally` 路径恢复进程。若初始环境为空，`DevRuntime.DebuggerHandoff` 会在有限时间内显式调用 C探针。ready 标记最后写入；Runtime 只在 ready 与 session ID 一致后启动。实现不应创建 handoff breakpoint。

## 5. 同进程保存与刷新

### XR-03：建立状态基线

1. 记录 `LiveReloadDemo` PID。
2. 点击两次 “Change in-memory state”。
3. 确认页面显示 `State retained: 2`。

预期：App 稳定运行，Overlay 不遮挡按钮触摸，计数为 2。

### XR-04：第一代修改

只修改 `viewDidLayoutSubviews()` 中的 presentation 值：

```swift
titleLabel.text = "XCODE RUN RELOAD ONE" // HELIX_LIVE_BASELINE
```

保存文件，不点击 Build 或 Run。

预期：

- 页面变为 `XCODE RUN RELOAD ONE`；
- PID 与 XR-03 相同；
- 计数仍为 2；
- daemon 日志包含稳定快照、编译、传输、激活与 UI refresh 成功；
- Xcode 没有执行 App 安装或重新启动。

### XR-05：第二代修改

把同一行改为：

```swift
titleLabel.text = "XCODE RUN RELOAD TWO" // HELIX_LIVE_BASELINE
```

保存后立即再次点击计数按钮。

预期：页面变为第二代文本，PID 不变，计数从 2 递增到 3；活动 generation 单调增加，第一代不会在第二代之后重新覆盖页面。

### XR-06：编译失败保留上一代

在同一 callback 中临时制造一个明确的 Swift 语法错误并保存，例如删除一个右括号。不要修改声明签名或 stored layout。

预期：

- Overlay/daemon 报告 compile failed，并说明 old code remains active；
- 页面仍显示 `XCODE RUN RELOAD TWO`；
- PID 和计数保持；
- 不产生新的 active generation；
- 修复语法后下一次保存仍能继续生成 patch。

### XR-07：恢复 baseline

恢复为：

```swift
titleLabel.text = "SAVE TO RELOAD" // HELIX_LIVE_BASELINE
```

保存。

预期：页面恢复 `SAVE TO RELOAD`，但这是新的恢复 generation，不是卸载旧 dylib；PID 与计数仍保持。确认磁盘文件也已经恢复，不能只恢复 Xcode editor buffer。

## 6. 生命周期与负向用例

### XR-08：停止与清理

1. 在 Xcode 点击 Stop。
2. 等待 Run post-action 完成；若 Xcode 跳过它，最多等待五秒断线宽限
   加少量进程调度时间。
3. 检查 daemon 进程与 session 输出目录。

预期：

- daemon 退出；
- `Session.json`、`Helix.lldbinit` 和 bootstrap private document 被清理；
- source monitor 不再响应保存；
- App 结束后没有后台 Helix 会话残留。

这里同时验证主动 `live-stop` 与受监管daemon自清理。Xcode 26实测可能在
界面显示Run已结束后跳过Launch post-action，因此不能只检查Scheme配置。
若 Xcode 或宿主机异常退出，旧的 owner-only
`Session.json` 或 LLDB init 可能来不及删除；下一次 Run pre-action 必须根据
lifecycle lock 安全回收旧 owner 并换成新会话，不能要求开发者手工删除文件来
恢复工作流。

### XR-09：再次 Run 是新会话

再次点击 Run。

预期：产生新的 session identity 与一次性凭据，App 从已编译 baseline 启动，旧 live generation 不会跨进程持久化。

### XR-10：需要完整 Build 的修改

扩展验收时可修改函数签名、stored property、source membership 或 Build Setting。

预期：Helix 明确返回 `rebuildRequired`，不会错误生成 Native replacement，也不会破坏上一代活动代码。测试后完整恢复工程。

## 7. 证据与结果模板

每轮至少保存：

- Xcode 工程 URL、Scheme、destination 和 Running 状态截图；
- 首屏、第一代、第二代、编译失败、恢复 baseline 的页面截图；
- 各阶段 PID 与计数；
- 已脱敏 daemon 关键事件；
- Xcode 控制台中 LLDB handoff 与约束检查结果；
- 自动化命令摘要；
- 所有临时源码修改均已恢复的确认。

结果表：

| 用例 | 结果 | 证据 | 问题/修复 |
| --- | --- | --- | --- |
| XR-00 | | | |
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

## 8. 失败定位顺序

1. **Build 失败**：先看 Xcode Report Navigator，确认本地 Package 指向当前 Helix，且 `HelixDevAppRuntime` 产品存在。
2. **daemon 只有 listening**：检查生成 init 的权限和命令结构，不输出其中的值；确认导出符号 `_helix_dev_runtime_handoff_probe` 存在于 Dev package framework。
3. **installer 超时或 App停在 probe**：确认 Runtime owner 被强引用、`debuggerHandoffEnabled` 未关闭、App链接的是 `HelixDevAppRuntime`，并检查 installer是否找到了真实 target、`process.Stop()` 后的唯一command-interpreter注入是否成功且 `process.Continue()` 总能执行；不应存在 handoff breakpoint。
4. **已连接但保存无反应**：确认编辑的是 Manifest 冻结的原始文件，source monitor 已启动，且可见值位于可重入的 reload callback，而不是只运行一次的 `viewDidLoad`/安装层级代码。
5. **代码激活但 UI 不变**：检查 Reload Index、UIKit type registration、invalidation hint 或 `LiveReload.Reloadable` hook；代码激活与 UI refresh 是两个独立结果。
6. **状态丢失或 PID 改变**：说明发生了 rebuild/relaunch，不能算 Live Reload 通过。
7. **Stop 后残留**：先检查App连接是否真的断开、daemon是否进入五秒宽限和私有artifact目录校验，再检查Run post-action与`live-stop.sh`主动路径；不要手工删除正在被daemon使用的文件来掩盖生命周期错误。

## 9. 2026-08-10 原工程实测记录

本轮严格使用 `/Users/tangent/Desktop/Helix/Demo/HelixDemo.xcodeproj`，没有使用
`/tmp` 副本。环境为 Xcode 26.6（Build 17F113）、iPhone 17 Pro Simulator
（iOS 26.4），Scheme 为 `Helix Live Reload Demo`。

| 用例 | 结果 | 核心证据 | 本轮发现与修复 |
| --- | --- | --- | --- |
| XR-00 | 通过 | Kit validate、自动化测试与 Demo 构建通过 | 最终门禁结果以本轮 Review 记录为准 |
| XR-01 | 通过 | 原工程、共享 Scheme、本地 package 与生成 phase 均生效 | 无需手工启动 Helix 命令 |
| XR-02 | 通过 | App 完成认证连接，页面显示 `SAVE TO RELOAD` | 后台 LLDB Python 创建的 breakpoint 属性会静默丢失；改为短暂停进程并由 command interpreter 直接注入，`finally` 恢复运行 |
| XR-03 | 通过 | 同一 PID 内变为 `RELOADED WITHOUT BUILD`，revision/generation 为 1/1 | 未触发 Build、安装或 relaunch |
| XR-04 | 通过 | 点击按钮后计数为 1，再保存为 `SECOND GENERATION`，revision/generation 为 2/2 | PID 与计数均保持 |
| XR-05 | 通过 | 保存不完整表达式后 revision/generation 3/3 编译失败，页面仍为上一成功代 | 修复语法后可继续 reload |
| XR-06 | 通过 | 恢复 `SAVE TO RELOAD` 后 revision/generation 4/4 激活并刷新 | PID 与计数仍保持，磁盘源码逐字恢复 baseline |
| XR-07 | 通过 | baseline 页面、源码与标记一致 | 恢复是新 generation，不是卸载 dylib |
| XR-08 | 通过 | Xcode Stop 后 App、debugserver 与 daemon 均退出；三份 private handoff 文件消失 | Xcode 26.6 实际跳过 Launch post-action；增加已认证 App 断线五秒后的受监管 daemon 自停与安全清理 |
| XR-09 | 通过 | 再次 Run 获得新 App PID 和新会话，随后再次 Stop 完整清理 | 旧 generation 与一次性凭据未跨进程复用 |
| XR-10 | 自动化覆盖 | interface、source membership 与配置漂移由既有 rebuild-required/doctor 测试覆盖 | 本轮未在 GUI 中破坏 Demo 工程图 |

本轮没有记录或复制 session secret、SPKI、私钥内容或完整 LLDB init。第一次
Run 的 App PID 在两次成功修改、一次编译失败和 baseline 恢复期间保持不变；第二次
Run 使用不同 PID，证明测试确实跨越了新会话。Stop 验收特意没有手工执行
`live-stop`：它验证的是即使 Xcode 跳过 post-action，受监管 daemon 仍能自行收敛，
而不是用测试命令掩盖宿主生命周期缺陷。
