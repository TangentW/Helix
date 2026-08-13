# Helix Xcode / Hub 端到端测试用例

这份清单覆盖 Helix Hub、Xcode 自动连接、测试包手动配对、同进程 Live Reload 和 Xcode Patch Action。它补充 `swift test`、Simulator fixture 与 `xcodebuild`，不把其中任何一项当作其他证据的替代品。

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

1. Helix 菜单栏应用能发现并配置工程，用户可见名称和进程名称都是 **Helix**。
2. 普通 Xcode Run 使用默认 Apple debugger 自动连接，不设置自定义 LLDB、launch environment、host、port、secret 或 `HELIX_EXECUTABLE`。
3. App 从桌面直接打开时默认不浏览 Bonjour、不连接；用户进入调试页输入四位码并确认后才开始发现和认证。
4. Xcode 自动连接和四位码手动连接都使用唯一 `_helix._tcp`、同一 Host Identity pin、Build Context、TLS 与 HLBC 会话协议。
5. 连续保存两次受支持实现，页面在同一 App PID 内变化，内存状态保留，较旧任务不能覆盖新 generation。
6. 语法错误或不支持的 SIL 会显示明确失败，上一成功 generation 继续生效。
7. 源码恢复 baseline 后产生恢复 generation，不依赖重启 App。
8. Xcode Stop 只结束 App 会话；长期运行的 Helix Service 与 Build Context registry 继续可用。
9. Patch Scheme 只生成、签名并可选 stage `.hlxp`，不重建或重装 App。
10. 证据中没有 Service secret、private key、完整 invitation、TLS key material 或认证帧。

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

四位码可以出现在临时截图里，但验收归档应遮掉或只保留末一位。不要直接读取或粘贴 `~/Library/Application Support/Helix/Service.json`；如需检查，只记录 owner、`0600` 权限、schema、mode 和已脱敏的 tool path 结论。

## 3. 自动化前置 Gate

从仓库根目录执行：

```bash
swift build --product helix
swift test
swift test -Xswiftc -warnings-as-errors
swift test -c release -Xswiftc -warnings-as-errors

.build/debug/helix xcode validate \
  --plan Demo/.helix/xcode/HostPlan.json
.build/debug/helix xcode doctor \
  --plan Demo/.helix/xcode/HostPlan.json \
  --profile live \
  --static

Hub/Scripts/build-app.sh release /tmp/Helix-Validation.app

xcodebuild -project Demo/HelixDemo.xcodeproj \
  -scheme "Helix Live Reload Demo" \
  -destination "generic/platform=iOS Simulator" \
  build
```

预期：

- 测试和两种编译 Gate 全部成功；
- installed `HostPlan.json` 能直接通过 validate/doctor，工程路径解析到 `Demo/`，不会错误落到 `.helix/xcode/`；
- `/tmp/Helix-Validation.app/Contents/Helpers/helix` 存在且可执行；
- App 与嵌套 helper 的签名结构可通过 `codesign --verify --strict`；
- Demo 工程没有生成 Swift reference、Bridge target、`HELIX_EXECUTABLE`、自定义 LLDB init、`live-start.sh` 或 `live-stop.sh`。

## 4. Helix Hub 与工程接入

### XR-01：打开 Helix

1. 打开打包后的 Helix。
2. 确认菜单栏出现 Helix，主窗口显示 Service 为 Running。
3. 选择 `Demo/HelixDemo.xcodeproj`。

预期：

- 工程列表显示 Hot Patch 与 Live Reload；
- Helix 显示一个大小写不敏感的四位码及过期时间；
- Service 只发布 `_helix._tcp`；
- 如果外部 `helix hub run` 已经运行，GUI 显示 external/adopted 状态，退出 GUI 不会停止外部进程。

### XR-02：配置事务与幂等

1. 打开 Configure。
2. 检查两个能力默认选中，且分别匹配正确 App、Feature、shared Scheme 与 configuration。
3. 应用配置。
4. 不改任何选择，再应用一次。

预期：

- 第二次运行不产生 diff；
- `.helix/xcode/HostPlan.json`、`Configurations/Helix`、PBX wrapper、Scheme action 与 plist 网络声明保持 canonical；
- 生成 Swift 不出现在 Project Navigator；
- 已安装能力不能被静默关闭，integration root 被锁定；
- GUI 只列出 Package linkage 与 Runtime 初始化等代码层动作，不注入隐藏业务代码。

## 5. Xcode 自动连接

### XR-03：检查 Scheme

在 Xcode 打开 Demo 并检查 `Helix Live Reload Demo`：

- Build pre-action 是 `Profiles/live/prepare.sh`，Build Settings 来自 Feature；
- Run pre-action 是 `Profiles/live/live-register.sh`，Build Settings 来自 App；
- Run action 使用默认 debugger；
- 没有 Run post-action、Custom LLDB Init File 或 Helix launch environment；
- App Sources 前存在隐藏 Bridge phase，output 是 `$(HELIX_BRIDGE_OBJECT)`。

### XR-04：真实 Xcode Run

1. 保持 Helix 运行。
2. 点击 Xcode Run。
3. 等待 App 首屏与 Overlay。

预期：

- App 启动时锁定 `automaticXcode`；
- Helix 出现对应的精确 Build Context 和连接事件；
- Overlay 进入 Connected/Ready，不长期停留在 Connecting；
- App 内调试页显示 Xcode 自动模式，不出现四位码输入框；
- 无 LLDB 注入、probe、environment handoff 或凭据日志。

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

预期：Mac 诊断与 App Overlay 都显示失败和修复提示；页面仍是 `XCODE RELOAD TWO`；active generation、PID 和内存状态不变。修复语法后后续保存仍可工作。

### XR-08：恢复 baseline

恢复：

```swift
titleLabel.text = "SAVE TO RELOAD" // HELIX_LIVE_BASELINE
```

预期：同一进程恢复 baseline；这是新的 tombstone/restore generation，磁盘文件也与 Git baseline 一致。

## 7. 直接启动与手动配对

### XR-09：Xcode Stop 后直接打开

1. Xcode Stop。
2. 确认 App 连接数回落，但 Helix Service 仍 Running。
3. 从 Simulator 或设备桌面直接打开同一个包。
4. 进入导航栏的 **Helix** 调试页。

预期：

- 新进程锁定 `manual`；
- 确认前状态说明网络关闭，页面显示四位码输入框；
- 不会复用上一次 Xcode invitation 或 lease；
- later attach debugger 不改变 manual 模式。

### XR-10：四位码成功与失败

1. 先输入格式合法但错误的码。
2. 确认错误直接显示在调试页，输入框仍可重试。
3. 输入 Mac Helix 当前码并确认。

预期：错误码不会进入任何 Shell host；正确码在两分钟有效期内只兑换一次，并且只匹配已注册的精确 Build Context。成功后页面显示 Connected，保存 Swift 文件继续走与 Xcode 模式相同的 HLBC 链。

另测过期码、已使用码、连续失败限流，以及“App 已重新构建但 Hub 只有旧 Build Context”。最后一种必须明确拒绝，不能按 bundle ID 猜测。

## 8. Hot Patch Action

### XR-11：冻结 Shell 并构建 Patch

1. 通过 `Helix Hot Patch Demo` 的 Release destination Build/Archive，完成 finalize 与 bundle audit。
2. 记录 App 产物 UUID、版本与平台。
3. 修改 eligible fee 实现和 recipe revision。
4. 使用同一平台 destination Build `Helix Build Patch`。

预期：

- Scheme 的空 `HelixPatchAction` 只作锚点；
- `patch.sh` 是 App-scoped Build pre-action，从 App `EnvironmentBuildable` 取得版本和平台；
- 不发生 App compile、link、install 或 launch；
- 输出签名 `.hlxp` 与冻结 Shell、平台、架构、bundle/version、recipe 和 trust identity 一致；
- 重复应用同一 active package 不创建新 generation；
- Demo mock install 能激活补丁并回滚 baseline。

## 9. 证据模板

每轮至少保存：

- Helix 工程页、Service 状态、已脱敏四位码与 Build Context；
- Xcode 工程 URL、Scheme、destination 和 Running 状态；
- 自动连接、手动未激活、手动成功、错误码的 App 页面；
- baseline、两次成功修改、失败、恢复的页面；
- 各阶段 PID、counter、revision/generation；
- Patch 产物摘要与“App 未重建”的 Xcode build log；
- 所有源码和工程文件已恢复或只有预期提交内 diff 的确认。

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
| XR-11 | | | |

## 10. 失败定位顺序

1. **Xcode phase 找不到工具**：先确认 Helix 正在运行，Service rendezvous 文件 owner/mode 正确，打包 App 内有 `Contents/Helpers/helix`。不要先给工程加 `HELIX_EXECUTABLE`。
2. **自动模式一直 Connecting**：确认是 Xcode debugger 从进程启动时就附着，而不是直接启动后 late attach；检查 Build pre-action reservation、Run pre-action final executable registration、Host pin 与 exact Build Context。
3. **手动页没有输入框**：确认当前进程不是 Xcode launch；模式只在启动时决定。需要 Stop 后从桌面新开进程。
4. **正确码仍被拒绝**：检查码是否过期/使用过、当前 App Mach-O 是否与 registry 中 Build Context 完全相同、工程范围是否一致。不要降级为 bundle-ID 匹配。
5. **连接后保存无反应**：确认编辑的是 Manifest 冻结的原始文件、source monitor 已启动、配置 `entrypoints` 包含目标，并查看 Mac 与 Overlay 的编译诊断。
6. **代码 active 但 UI 不变**：区分代码激活和 UI refresh；检查 Reload Index、当前是否有匹配的 UIKit 实例、invalidation hint，或是否确实需要显式 `Reloadable`/SwiftUI boundary。
7. **PID 改变或状态丢失**：说明发生了 Build/relaunch，不能算 Live Reload。
8. **Xcode Stop 后 Service 退出**：如果 GUI 内嵌 Service 随 GUI 一起退出是正常的；只 Stop App 时 Service 应继续运行。外部 `helix hub run` 永远不应被 GUI 停止。
9. **Patch Scheme 重建 App**：检查 Patch target 是否为空、脚本是否在 Scheme Build pre-action、App 是否只作为 `EnvironmentBuildable`，以及 Patch Scheme 的 BuildAction graph。
