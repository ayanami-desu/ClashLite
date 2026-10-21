//
//  CoreManager.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import AppKit
import Observation

/// 管理内核进程：以覆写后的配置（base64）启动 mihomo，设置变化时通过 RESTful API 同步
@Observable
final class CoreManager {
    enum Status {
        case stopped
        case starting
        case running
        case failed

        var title: String {
            switch self {
            case .stopped: String(localized: "Stopped")
            case .starting: String(localized: "Starting")
            case .running: String(localized: "Running")
            case .failed: String(localized: "Failed to Start")
            }
        }
    }

    private(set) var status: Status = .stopped {
        didSet {
            guard status != oldValue else { return }
            status == .running ? startSync() : stopSync()
            if status != .running {
                proxies = [:]
                runtimeConfig = nil
            }
        }
    }

    var mode: ProxyMode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            updateProxyGroups()
            // 从内核同步来的修改无需再推回内核
            guard !isSyncing else { return }
            enqueue { await self.patch(["mode": self.mode.rawValue]) }
        }
    }

    /// 通过 setTunEnabled(_:) 修改，授权失败时会被关闭
    private(set) var isTunEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isTunEnabled, forKey: Self.tunKey)
        }
    }

    /// 是否把系统代理指向内核，通过 setSystemProxyEnabled(_:) 修改
    private(set) var isSystemProxyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isSystemProxyEnabled, forKey: Self.systemProxyKey)
        }
    }

    /// 是否在 TUN 开启时接管系统 DNS，通过 setSystemDNSEnabled(_:) 修改
    private(set) var isSystemDNSEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isSystemDNSEnabled, forKey: Self.systemDNSKey)
        }
    }

    /// 内核正在使用的配置，即最近一次成功传入内核的内容
    private(set) var runtimeConfig: String?

    /// 菜单中可快捷切换的策略组，随 proxies 和 mode 更新
    private(set) var proxyGroups: [ProxyGroup] = []

    let controller = CoreController.load()

    /// 正在更新面板
    private(set) var isUpdatingPanel = false

    /// 内核托管的面板，子目录取自当前生效的配置
    private var panelURL: URL { controller.panelURL(uiName: uiName) }

    private var uiName: String?

    @ObservationIgnored private var proxies: [String: CoreController.Proxy] = [:] {
        didSet { updateProxyGroups() }
    }

    @ObservationIgnored private var profileURL: URL?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var dnsMonitor: SystemDNSMonitor?
    /// 内核最近一次加载配置时的系统 DNS 服务器
    @ObservationIgnored private var loadedDNSServers: [String] = []
    @ObservationIgnored private var dnsChangeTask: Task<Void, Never>?
    /// 已接管的系统 DNS；服务不变时不再重复读写
    @ObservationIgnored private var appliedSystemDNS: SystemDNS.Applied?
    /// 自己写入 DNS 后 monitor 读到的值，用于避免触发内核重载
    @ObservationIgnored private var expectedDNSServers: [String]?
    /// 当前内核进程是否以 root 运行；setuid 只对新启动的进程生效
    @ObservationIgnored private var isCorePrivileged = false
    /// 内核报告的代理端口，混合端口同时服务 HTTP 和 SOCKS
    @ObservationIgnored private var proxyPorts: ProxyPorts?
    /// 已写入系统代理的端口，端口不变时不再重复设置
    @ObservationIgnored private var appliedProxyPorts: ProxyPorts?
    @ObservationIgnored private static let syncInterval = Duration.seconds(3)
    @ObservationIgnored private static let modeKey = "proxyMode"
    @ObservationIgnored private static let tunKey = "tunEnabled"
    @ObservationIgnored private static let systemProxyKey = "systemProxyEnabled"
    @ObservationIgnored private static let systemDNSKey = "systemDNSEnabled"

    private struct ProxyPorts: Equatable {
        var http: Int?
        var socks: Int?
    }

    private var config: CoreConfig {
        CoreConfig(mode: mode, isTunEnabled: isTunEnabled, controller: controller)
    }

    init(profileStore: ProfileStore) {
        mode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(ProxyMode.init) ?? .rule
        isTunEnabled = UserDefaults.standard.bool(forKey: Self.tunKey)
        isSystemProxyEnabled = UserDefaults.standard.bool(forKey: Self.systemProxyKey)
        // 默认开启，老用户升级后也直接生效
        isSystemDNSEnabled = UserDefaults.standard.object(forKey: Self.systemDNSKey) as? Bool ?? true

        Notifier.setUp()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.process?.terminate()
                // 异步恢复可能来不及执行，退出前同步完成
                SystemProxy.restoreIfNeeded()
                SystemDNS.restoreIfNeeded()
            }
        }

        dnsMonitor = SystemDNSMonitor { [weak self] in
            self?.systemDNSDidChange()
        }

        // 上次异常退出可能遗留了未恢复的系统代理
        if !isSystemProxyEnabled, SystemProxy.hasBackup {
            enqueue { await self.restoreSystemProxy() }
        }

        // 上次异常退出可能遗留了未恢复的系统 DNS
        if SystemDNS.hasBackup {
            enqueue { await self.restoreSystemDNS() }
        }

        observeSelection(of: profileStore)
    }

    /// 跟随选中的配置启动或切换内核；Observations 需要 macOS 26，这里用 withObservationTracking 逐次重新订阅
    private func observeSelection(of profileStore: ProfileStore) {
        let profile = withObservationTracking {
            profileStore.selected
        } onChange: { [weak self, weak profileStore] in
            // onChange 在属性修改前调用，到下一轮再读取新值
            Task { @MainActor [self, profileStore] in
                guard let self, let profileStore else { return }
                self.observeSelection(of: profileStore)
            }
        }
        select(profile)
    }

    /// TUN 会影响 DNS 覆写，需要以完整配置重新加载
    func setTunEnabled(_ enabled: Bool) {
        guard enabled != isTunEnabled else { return }
        isTunEnabled = enabled
        enqueue {
            guard await self.ensureTunPermission() else {
                await self.restoreSystemDNS()
                return
            }
            // setuid 只对新进程生效，授权前启动的内核仍是普通用户，必须重启
            let applied: Bool
            if enabled, self.status == .running, !self.isCorePrivileged {
                applied = await self.start()
            } else {
                applied = await self.apply()
            }
            if !applied {
                await self.restoreSystemDNS()
            }
        }
    }

    /// 打开时把系统代理指向内核端口，关闭时恢复原有设置；内核未运行时等启动后再应用
    func setSystemProxyEnabled(_ enabled: Bool) {
        guard enabled != isSystemProxyEnabled else { return }
        isSystemProxyEnabled = enabled
        enqueue {
            if enabled {
                await self.syncProxySettings()
            } else {
                await self.restoreSystemProxy()
            }
        }
    }

    /// TUN 开启时接管系统 DNS，关闭开关时立即恢复
    func setSystemDNSEnabled(_ enabled: Bool) {
        guard enabled != isSystemDNSEnabled else { return }
        isSystemDNSEnabled = enabled
        enqueue {
            if enabled {
                await self.syncSystemDNS()
            } else {
                await self.restoreSystemDNS()
            }
        }
    }

    /// 重新生成配置并应用，例如修改覆写之后
    func reload() {
        guard profileURL != nil else { return }
        enqueue { await self.apply() }
    }

    /// 手动重启，例如放入内核文件之后
    func restart() {
        enqueue { await self.start() }
    }

    /// 切换策略组选中的节点，先更新菜单再同步给内核
    func selectProxy(_ name: String, in group: String) {
        guard let index = proxyGroups.firstIndex(where: { $0.name == group }) else { return }
        proxyGroups[index].now = name
        enqueue {
            guard self.status == .running else { return }
            do {
                try await self.controller.selectProxy(name, in: group)
            } catch {
                Notifier.post(id: "proxy", title: "Failed to Switch Proxy", body: error.localizedDescription)
            }
            await self.refreshProxies()
        }
    }

    /// 解除策略组的锁定，恢复自动选择
    func unfixProxy(in group: String) {
        guard let index = proxyGroups.firstIndex(where: { $0.name == group }) else { return }
        proxyGroups[index].fixed = nil
        enqueue {
            guard self.status == .running else { return }
            do {
                try await self.controller.unfixProxy(in: group)
            } catch {
                Notifier.post(id: "proxy", title: "Failed to Unpin", body: error.localizedDescription)
            }
            await self.refreshProxies()
        }
    }

    /// 关闭当前所有连接，例如切换节点后让旧连接立即走新节点
    func closeAllConnections() {
        enqueue {
            guard self.status == .running else { return }
            do {
                try await self.controller.closeAllConnections()
            } catch {
                Notifier.post(id: "connections", title: "Failed to Close Connections", body: error.localizedDescription)
            }
        }
    }

    /// 打开面板，面板文件不存在时先下载
    func openPanel() {
        guard !isUpdatingPanel else { return }
        guard !FileManager.default.fileExists(atPath: panelIndexURL.path) else {
            NSWorkspace.shared.open(panelURL)
            return
        }
        downloadPanel(failureTitle: "Failed to Download Dashboard") {
            NSWorkspace.shared.open(self.panelURL)
        }
    }

    /// 从 external-ui-url 重新下载面板
    func updatePanel() {
        downloadPanel(failureTitle: "Failed to Update Dashboard") {
            Notifier.post(id: "panel", title: "Dashboard Updated", body: String(localized: "Reload the dashboard page in your browser to use the new version."))
        }
    }

    private func downloadPanel(failureTitle: LocalizedStringResource, then completion: @escaping () -> Void) {
        guard !isUpdatingPanel else { return }
        isUpdatingPanel = true
        Task {
            defer { isUpdatingPanel = false }
            do {
                try await controller.upgradeUI()
                completion()
            } catch {
                Notifier.post(id: "panel", title: failureTitle, body: error.localizedDescription)
            }
        }
    }

    /// 内核工作目录中面板的入口文件，与 panelURL 对应
    private var panelIndexURL: URL {
        var url = CoreDirectory.homeURL.appending(path: controller.uiPath, directoryHint: .isDirectory)
        if let uiName {
            url.append(path: uiName, directoryHint: .isDirectory)
        }
        return url.appending(path: "index.html", directoryHint: .notDirectory)
    }

    /// 选中的配置被删除时，内核继续运行原配置直到切换
    private func select(_ profile: Profile?) {
        guard let profile else {
            profileURL = nil
            enqueue { await self.stop() }
            return
        }
        guard !profile.isDeleted, profile.fileURL != profileURL else { return }
        profileURL = profile.fileURL
        enqueue { await self.apply() }
    }

    /// 操作依次执行，避免启动、重载交错
    @discardableResult
    private func enqueue(_ work: @escaping () async -> Void) -> Task<Void, Never> {
        let previous = operation
        let task = Task {
            await previous?.value
            await work()
        }
        operation = task
        return task
    }

    /// 内核不会推送设置变化，运行期间定时读取，以同步在面板中做的修改
    private func startSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.syncInterval)
                guard let self, !Task.isCancelled else { return }
                // 等本次同步完成再计时，队列被授权对话框等阻塞时不会堆积
                await self.enqueue { await self.sync() }.value
            }
        }
    }

    private func stopSync() {
        syncTask?.cancel()
        syncTask = nil
    }

    /// 以内核当前设置为准更新并保存，之后重载、重启都会沿用；同时刷新策略组
    private func sync() async {
        await syncConfigs()
        await refreshProxies()
        await applySystemProxy(notifyOnFailure: false)
        await syncSystemDNS(notifyOnFailure: false)
    }

    private func syncConfigs() async {
        guard status == .running else { return }
        let (mode, isTunEnabled) = (self.mode, self.isTunEnabled)
        guard let config = try? await controller.configs() else { return }
        // 请求期间本地又有修改时以本地为准，排在后面的操作会推给内核
        guard status == .running, self.mode == mode, self.isTunEnabled == isTunEnabled else { return }

        isSyncing = true
        defer { isSyncing = false }
        if let remote = ProxyMode(rawValue: config.mode.lowercased()) {
            self.mode = remote
        }
        if let tun = config.tun {
            self.isTunEnabled = tun.enable
        }
        updateProxyPorts(config)
    }

    /// 混合端口优先，同时服务 HTTP 和 SOCKS；未配置混合端口时分别取各自端口
    private func updateProxyPorts(_ config: CoreController.RuntimeConfig) {
        let mixed = config.mixedPort.flatMap { $0 > 0 ? $0 : nil }
        proxyPorts = ProxyPorts(
            http: mixed ?? config.port.flatMap { $0 > 0 ? $0 : nil },
            socks: mixed ?? config.socksPort.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    /// 读取策略组，内核未运行或请求失败时保持原样
    private func refreshProxies() async {
        guard status == .running, let proxies = try? await controller.proxies(), status == .running else { return }
        self.proxies = proxies
    }

    /// 内容未变时不赋值，避免菜单无谓刷新
    private func updateProxyGroups() {
        let groups = ProxyGroup.list(from: proxies, mode: mode)
        if groups != proxyGroups {
            proxyGroups = groups
        }
    }

    /// 内核的 system DNS 读到可用的服务器后缓存 5 分钟。开机时内核先于网络启动，可能缓存了过渡阶段
    /// 不可用的服务器（例如关闭 IPv6 时的 IPv6 服务器），导致断网；系统 DNS 变化后重载配置使其重新读取
    private func systemDNSDidChange() {
        dnsChangeTask?.cancel()
        dnsChangeTask = Task {
            // 网络就绪过程中会连续变化，resolv.conf 的更新也稍有延迟
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            enqueue { await self.reloadIfDNSChanged() }
        }
    }

    private func reloadIfDNSChanged() async {
        let servers = dnsMonitor?.servers ?? []
        guard status == .running, !servers.isEmpty, servers != loadedDNSServers else { return }
        // 自己接管或恢复 DNS 引起的变化不应重载内核
        if servers == expectedDNSServers {
            expectedDNSServers = nil
            loadedDNSServers = servers
            return
        }
        NSLog("系统 DNS 变为 \(servers)，重载内核配置")
        await apply()
    }

    /// 读取内核端口，开启系统代理时指向内核
    private func syncProxySettings() async {
        guard status == .running else { return }
        await syncConfigs()
        await applySystemProxy()
    }

    /// 端口变化时才重写系统代理，避免定时同步反复修改系统设置
    private func applySystemProxy(notifyOnFailure: Bool = true) async {
        guard isSystemProxyEnabled, status == .running, let ports = proxyPorts else { return }
        guard let service = SystemProxy.activeServiceName else { return }
        // 切换网络后需要把代理设到新的服务上
        guard ports != appliedProxyPorts || service != SystemProxy.backedUpService else { return }
        do {
            try await SystemProxy.enable(httpPort: ports.http, socksPort: ports.socks)
            appliedProxyPorts = ports
        } catch {
            NSLog("设置系统代理失败：\(error)")
            guard notifyOnFailure else { return }
            Notifier.post(id: "systemProxy", title: "Failed to Set System Proxy", body: error.localizedDescription)
        }
    }

    /// 内核停止后系统代理会指向已关闭的端口，需要恢复原有设置
    private func restoreSystemProxy() async {
        guard appliedProxyPorts != nil || SystemProxy.hasBackup else { return }
        appliedProxyPorts = nil
        do {
            try await SystemProxy.disable()
        } catch {
            NSLog("恢复系统代理失败：\(error)")
            Notifier.post(id: "systemProxy", title: "Failed to Restore System Proxy", body: error.localizedDescription)
        }
    }

    /// TUN 开启且开关打开时接管系统 DNS，否则恢复
    private func syncSystemDNS(notifyOnFailure: Bool = true) async {
        guard isSystemDNSEnabled, isTunEnabled, status == .running else {
            await restoreSystemDNS(notifyOnFailure: notifyOnFailure)
            return
        }
        guard let service = SystemProxy.activeServiceName else { return }
        // 服务不变时不再重复读写，避免定时同步反复修改系统设置
        guard appliedSystemDNS?.service != service else { return }

        do {
            let applied = try await SystemDNS.enable()
            appliedSystemDNS = applied
            // 自己写入会触发 SystemDNSMonitor，先记下期望值避免重载内核
            expectedDNSServers = applied.changed ? applied.servers : nil
            loadedDNSServers = applied.servers
        } catch {
            NSLog("设置系统 DNS 失败：\(error)")
            guard notifyOnFailure else { return }
            Notifier.post(id: "systemDNS", title: "Failed to Set System DNS", body: error.localizedDescription)
        }
    }

    /// 恢复接管前的 DNS；用户手动改过时不会覆盖
    private func restoreSystemDNS(notifyOnFailure: Bool = true) async {
        guard appliedSystemDNS != nil || SystemDNS.hasBackup else { return }
        appliedSystemDNS = nil
        do {
            let restored = try await SystemDNS.disable()
            expectedDNSServers = restored?.isEmpty == false ? restored : nil
            loadedDNSServers = dnsMonitor?.servers ?? []
        } catch {
            NSLog("恢复系统 DNS 失败：\(error)")
            guard notifyOnFailure else { return }
            Notifier.post(id: "systemDNS", title: "Failed to Restore System DNS", body: error.localizedDescription)
        }
    }

    /// 内核运行中则热重载，否则启动
    @discardableResult
    private func apply() async -> Bool {
        guard status == .running, let profileURL else {
            return await start()
        }

        loadedDNSServers = dnsMonitor?.servers ?? []
        do {
            let rendered = try await Self.render(config, profileURL: profileURL)
            try await controller.reloadConfigs(payload: rendered.payload)
            uiName = rendered.uiName
            runtimeConfig = rendered.payload
            await refreshProxies()
            // 配置可能更换了代理端口
            await syncProxySettings()
            await syncSystemDNS()
            return true
        } catch {
            Notifier.post(id: "core", title: "Failed to Load Config", body: error.localizedDescription)
            return false
        }
    }

    /// 开启 TUN 时确保内核已授权，未授权则请求一次；失败时关闭 TUN 并返回 false
    @discardableResult
    private func ensureTunPermission() async -> Bool {
        guard isTunEnabled, !TunPermission.isGranted else { return true }
        do {
            try await TunPermission.grant()
            return true
        } catch {
            isTunEnabled = false
            if case TunPermissionError.cancelled = error {} else {
                Notifier.post(id: "tun", title: "TUN Authorization Failed", body: error.localizedDescription)
            }
            return false
        }
    }

    private func patch(_ body: [String: Any]) async {
        guard status == .running else { return }
        do {
            try await controller.patchConfigs(body)
        } catch {
            Notifier.post(id: "core", title: "Failed to Apply Core Settings", body: error.localizedDescription)
        }
    }

    @discardableResult
    private func start() async -> Bool {
        await stop()
        guard let profileURL else { return false }

        status = .starting
        do {
            guard FileManager.default.isExecutableFile(atPath: CoreDirectory.binaryURL.path) else {
                throw CoreError.binaryNotFound
            }
            // 应用被强制结束时内核不会随之退出，残留的内核会占用端口，
            // 使新内核监听失败、请求被旧内核响应
            await Self.terminateLeftovers()
            // 内核文件被替换后权限会丢失，启动前重新确认
            await ensureTunPermission()
            let rendered = try await Self.render(config, profileURL: profileURL)
            loadedDNSServers = dnsMonitor?.servers ?? []
            let process = try launch(payload: rendered.payload)
            uiName = rendered.uiName
            self.process = process

            let version = try await waitUntilReady(process)
            status = .running
            runtimeConfig = rendered.payload
            await refreshProxies()
            await syncProxySettings()
            await syncSystemDNS()
            Notifier.post(id: "core", title: "Core Started", body: String(localized: "mihomo \(version), \(mode.title) mode"))
            return true
        } catch {
            await stop()
            status = .failed
            Notifier.post(id: "core", title: "Failed to Start Core", body: error.localizedDescription)
            return false
        }
    }

    private func stop() async {
        await restoreSystemDNS()
        await restoreSystemProxy()
        guard let process else { return }
        // 先移除引用，使退出回调忽略这次主动停止
        self.process = nil
        isCorePrivileged = false
        status = .stopped
        await Self.terminate(process)
    }

    /// 配置通过 CLASH_CONFIG_STRING 环境变量（等同 -config）以 base64 传入，
    /// 避免密钥和节点信息出现在进程参数中
    private func launch(payload: String) throws -> Process {
        guard CoreDirectory.createIfNeeded() else { throw CoreError.launchFailed }

        let logURL = CoreDirectory.logURL
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }

        var environment = ProcessInfo.processInfo.environment
        environment["CLASH_CONFIG_STRING"] = Data(payload.utf8).base64EncodedString()

        let process = Process()
        process.executableURL = CoreDirectory.binaryURL
        process.arguments = ["-d", CoreDirectory.homeURL.path]
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] process in
            let pid = process.processIdentifier
            let code = process.terminationStatus
            Task { @MainActor in
                self?.processDidExit(pid: pid, code: code)
            }
        }

        let isPrivileged = TunPermission.isGranted
        do {
            try process.run()
        } catch {
            NSLog("启动内核失败：\(error)")
            throw CoreError.launchFailed
        }
        // setuid 在 exec 时生效；记录本进程是否具有创建 TUN 的权限
        isCorePrivileged = isPrivileged
        return process
    }

    /// 轮询 RESTful API，可访问即视为启动成功
    private func waitUntilReady(_ process: Process) async throws -> String {
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(200))
            guard process.isRunning else { break }
            if let version = try? await controller.version() {
                return version
            }
        }
        if process.isRunning {
            throw CoreError.timeout
        }
        throw CoreError.exited(Self.lastLogError())
    }

    /// 运行中意外退出时提示；启动阶段的退出由 waitUntilReady 处理
    private func processDidExit(pid: Int32, code: Int32) {
        guard let process, process.processIdentifier == pid, status == .running else { return }
        self.process = nil
        isCorePrivileged = false
        status = .failed
        enqueue {
            await self.restoreSystemDNS()
            await self.restoreSystemProxy()
        }
        Notifier.post(id: "core", title: "Core Exited", body: Self.lastLogError() ?? String(localized: "Exit code \(code)"))
    }

    @concurrent
    private nonisolated static func render(_ config: CoreConfig, profileURL: URL) async throws -> CoreConfig.Rendered {
        try config.render(profileURL: profileURL)
    }

    /// 先发送 SIGTERM 让内核清理 TUN 路由等，超时后强制结束
    private static func terminate(_ process: Process) async {
        guard process.isRunning else { return }
        await terminate(pid: process.processIdentifier) { process.isRunning }
    }

    /// 结束所有从内核目录启动的进程；调用前须已停止当前内核
    private static func terminateLeftovers() async {
        let path = CoreDirectory.binaryURL.path
        for pid in runningPIDs() where executablePath(of: pid) == path {
            NSLog("结束残留的内核进程 \(pid)")
            await terminate(pid: pid) { kill(pid, 0) == 0 }
        }
    }

    private static func terminate(pid: pid_t, isRunning: () -> Bool) async {
        kill(pid, SIGTERM)
        for _ in 0..<30 where isRunning() {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if isRunning() {
            kill(pid, SIGKILL)
        }
    }

    private static func runningPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // 预留余量，两次调用之间可能有新进程
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(filled, 0))))
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// 从日志中取最后一条错误
    private static func lastLogError() -> String? {
        guard let text = try? String(contentsOf: CoreDirectory.logURL, encoding: .utf8) else { return nil }
        return CoreLog.lastError(in: text)
    }
}

enum CoreError: LocalizedError {
    case binaryNotFound
    case launchFailed
    case timeout
    case exited(String?)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound: String(localized: "Core not found. Place mihomo in the core folder.")
        case .launchFailed: String(localized: "Unable to run the core")
        case .timeout: String(localized: "Timed out waiting for the core to respond")
        case .exited(let message): message ?? String(localized: "The core exited unexpectedly")
        }
    }
}
