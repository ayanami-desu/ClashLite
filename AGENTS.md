# ClashLite 代码库指令

作用域：整个仓库。源码全部在 `ClashLite/`（扁平结构）；其余是工程文件、`dmg/` 构建脚本与 `README.md`。

## 产品边界

- 这是 macOS 菜单栏 mihomo 客户端，不是面板：连接、规则、测速交给内核托管的 metacubexd 面板，**不要在应用内重建这些界面**。应用内的 `CoreLogView` 只 tail `Home/mihomo.log`，不要扩建成面板。
- 无主窗口（`INFOPLIST_KEY_LSUIElement`）：界面只有 `ClashLiteApp.body` 的 `MenuBarExtra` 与独立 `Window`/`WindowGroup`。
- 仅支持 macOS 15+ / arm64；`ENABLE_APP_SANDBOX = NO`、`ENABLE_HARDENED_RUNTIME = YES`，改动权限相关代码时以该组合为前提。

## 构建与验证

- 没有测试目标，也没有测试套件：改动通过构建 + 实际运行菜单栏应用验证（启动内核、切换模式/节点、开关 TUN、开关系统代理、Wi-Fi 切换等真实路径），不要新增测试脚手架来「证明」改动。
- 构建需要 Xcode 27（工程 `objectVersion = 110`），CI 使用 `xcode-27` 镜像：

  ```sh
  xcodebuild -project ClashLite.xcodeproj -scheme ClashLite -configuration Release \
    -destination "generic/platform=macOS" ARCHS=arm64 build
  ```

- 唯一依赖是 Yams（SPM，`Package.resolved` 已提交）；YAML 一律走 `CoreConfig`/`ConfigOverride` 中的 Yams `Node` API，不要引入第二个 YAML 库或改用字符串拼接。
- `ClashLite/` 是 `PBXFileSystemSynchronizedRootGroup`：新增/删除源文件放进该目录即参与编译，**不要手改 `project.pbxproj` 添加文件引用**，只在改构建设置时才动工程文件。
- 资源与颜色用 Xcode 生成的符号（`Image(.menuBarIconTun)`），不要用字符串名。

## 配置生成管线（核心不变量）

- 最终配置 = 配置文件 → 配置覆写 → 全局覆写 → 应用设置（mode、external-controller、secret、external-ui、TUN），实现在 `ClashLite/CoreConfig.swift` 的 `render(profileURL:)`；覆写路径与深度合并语义（映射递归、`+key` 前置 / `key+` 后置）在 `ClashLite/ConfigOverride.swift`。改动任一层都要同步 `ClashLite/ConfigValidator.swift` 的对应检查层。
- 导入、编辑、更新配置或保存配置覆写时，必须经 `ConfigValidator` 用内核 `mihomo -t` 校验对应层；全局覆写保存目前只校验 YAML 格式（见 `ConfigOverrideView.save`）。
- 应用设置阶段，`CoreConfig.applyTun` 只在 `dns.enhanced-mode` 缺失或为 `fake-ip` 时补 DNS 设置；配置显式使用其他模式时不要覆盖。
- 配置以 `CLASH_CONFIG_STRING`（base64 环境变量）传给内核，**不得**把配置内容、secret 或节点信息放进 `process.arguments`（避免出现在进程参数中）。
- 控制接口固定 `127.0.0.1:9097`（`CoreController`）；secret 与 `external-ui` 目录名首次启动随机生成并存 UserDefaults，不要改成固定值或硬编码。

## 运行时状态与并发

- 所有内核操作经 `CoreManager.enqueue` 串行执行，避免启动/重载/同步交错；新增内核操作走 `enqueue`，不要另起并发任务直接调用 `CoreController`。
- 工程 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`：默认主线程隔离，离开主线程需显式 `nonisolated` + `@concurrent`（参考 `CoreConfig.render`、`ConfigValidator.check`）。
- TUN 首次开启需要管理员授权：`TunPermission` 把内核设为 root 所有并加 setuid 位；替换内核文件后权限丢失，需要重新授权。
- 内核不会推送设置变化，`CoreManager.startSync()` 定时读取并同步在面板中修改的模式、节点等状态；不要假设存在推送通道。
- Wi-Fi 切换等同一轮修改配置与 TUN 时，依赖 `CoreManager.scheduleApply()` 合并为一次热重载；新增设置变更走 `scheduleApply()`/`enqueue`，不要绕过队列直接操作内核。
- 修改 `mode` 通过 `patch` 即时下发给运行中的内核；修改 TUN、配置或覆写走 `scheduleApply()` 重新渲染整包配置。不要用 `patch` 修改需要重渲染的设置。
- `WiFiAutoSwitch` 只在功能被用户开启时请求定位权限（macOS 读取 SSID 所需），网络变化后等待 2 秒再读取；不要在启动时请求权限或去掉 debounce。
- 系统代理必须保持「改前备份 → 关闭/退出时恢复」的对称性（`SystemProxy` 的 UserDefaults backup 与 `restoreIfNeeded`），`CoreManager.init` 会恢复上次异常退出遗留的设置；改动时不得破坏恢复路径。
- 状态类用 `@Observable`（`CoreManager`、`ProfileStore`、`CoreVersionMonitor`、`LaunchAtLogin`、`WiFiAutoSwitch`），视图通过 `.environment(...)` 注入，不要改成 `ObservableObject`/单例。

## 代码约定

- 窗口在 `ClashLiteApp.body` 中声明并带 `id`，由 `openWindow(id:)` 打开；新增窗口沿用 `.defaultLaunchBehavior(.suppressed)` 与 `.restorationBehavior(.disabled)`，打开后调用 `NSApplication.shared.activate()`，否则菜单栏应用不在前台、窗口拿不到焦点。
- 需要用户感知的失败用 `Notifier.post(id:title:body:)` 发系统通知，同时 `NSLog` 记录细节；不要只弹窗或静默失败。
- 配置列表以数据目录中的 `Profiles/`（`ProfileDirectory.url`）为准；同目录的 `profiles.json` 只存订阅等附加信息，新增配置读取入口时遵循这一点。

## 本地化与注释

- 界面文案走字符串目录 `ClashLite/Localizable.xcstrings` 与 `ClashLite/InfoPlist.xcstrings`：键为英文原文（`sourceLanguage = en`），只维护 `zh-Hans` 翻译，应用固定显示简体中文，不要新增其他语言。
- 源码注释与提交信息用简体中文。

## Git 与发布

- 提交信息用 Conventional Commits 加作用域，例如 `feat(app):`、`build:`。
- 发布在 Actions 手动运行 `.github/workflows/release.yml`（`workflow_dispatch`），只有 `main` 分支可发布；输入版本号后由 workflow 构建 arm64 DMG（ad-hoc 签名、不公证），成功后提交版本号、打 `v*` tag 并推送 `main` 与 tag。
- 新增 `upload-artifact` 时设置 `retention-days: 1`，避免占用 GitHub Actions 配额。
- DMG 窗口外观由 `dmg/settings.py` 与 `dmg/background.swift` 共同决定，两处窗口尺寸与图标坐标必须一致。

## 文档路由

- 涉及数据目录与内核文件布局、覆写合并规则、TUN 行为、安装与内核替换时，先读 `README.md` 对应章节，不要在代码注释里复述文档。
- 发布行为以 `.github/workflows/release.yml` 为准；`README.md` 的发布说明可能滞后。
