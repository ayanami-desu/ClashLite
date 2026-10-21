//
//  SystemProxy.swift
//  ClashLite
//

import Foundation
import SystemConfiguration

nonisolated enum SystemProxyError: LocalizedError {
    case noActiveService
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .noActiveService: String(localized: "No active network service")
        case .commandFailed(let message):
            message.isEmpty
                ? String(localized: "Unable to change the system proxy settings")
                : message
        }
    }
}

/// 用 networksetup 把当前网络服务的系统代理指向内核端口。
/// 修改前保存原有设置，关闭或退出时恢复，以免覆盖用户自己的代理配置。
nonisolated enum SystemProxy {
    private static let host = "127.0.0.1"
    private static let backupKey = "systemProxyBackup"
    /// 本地地址和局域网主机不经过内核
    private static let bypassDomains = ["127.0.0.1", "localhost", "*.local", "169.254/16"]

    private struct Setting: Codable {
        var enabled: Bool
        var server: String
        var port: Int
    }

    private struct Backup: Codable {
        var service: String
        var web: Setting
        var secureWeb: Setting
        var socks: Setting
        var bypassDomains: [String]
    }

    /// 存在备份说明上一次修改尚未恢复
    static var hasBackup: Bool {
        UserDefaults.standard.data(forKey: backupKey) != nil
    }

    /// 已保存设置的服务，与当前主服务不同时说明切换了网络
    static var backedUpService: String? {
        storedBackup()?.service
    }

    /// 当前主网络服务的名称，即系统设置中显示的名称（如 Wi-Fi）。
    /// 优先 IPv4；IPv6-only 网络下回退到 IPv6 的主服务。
    static var activeServiceName: String? {
        guard let store = SCDynamicStoreCreate(nil, "ClashLite" as CFString, nil, nil) else { return nil }
        return serviceName(in: store, key: "State:/Network/Global/IPv4")
            ?? serviceName(in: store, key: "State:/Network/Global/IPv6")
    }

    private static func serviceName(in store: SCDynamicStore, key: String) -> String? {
        guard let primary = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
              let id = primary["PrimaryService"] as? String,
              let service = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(id)" as CFString) as? [String: Any],
              let name = service["UserDefinedName"] as? String,
              !name.isEmpty
        else { return nil }
        return name
    }

    /// 混合端口同时服务 HTTP 和 SOCKS，两者没有可用端口时返回
    @concurrent
    static func enable(httpPort: Int?, socksPort: Int?) async throws {
        guard httpPort != nil || socksPort != nil else { return }
        guard let service = activeServiceName else { throw SystemProxyError.noActiveService }

        // 网络服务变了，先恢复旧服务，再按新服务重新保存
        if let previous = storedBackup(), previous.service != service {
            try? restore(previous)
            clearBackup()
        }

        if storedBackup() == nil {
            let backup = Backup(
                service: service,
                web: try setting("webproxy", service: service),
                secureWeb: try setting("securewebproxy", service: service),
                socks: try setting("socksfirewallproxy", service: service),
                bypassDomains: try readBypassDomains(service: service)
            )
            save(backup)
        }

        do {
            if let httpPort {
                try run(["-setwebproxy", service, host, String(httpPort)])
                try run(["-setsecurewebproxy", service, host, String(httpPort)])
            } else {
                try run(["-setwebproxystate", service, "off"])
                try run(["-setsecurewebproxystate", service, "off"])
            }
            if let socksPort {
                try run(["-setsocksfirewallproxy", service, host, String(socksPort)])
            } else {
                try run(["-setsocksfirewallproxystate", service, "off"])
            }
            try run(["-setproxybypassdomains", service] + bypassDomains)
        } catch {
            // 失败时回滚，避免只改了一半
            if let backup = storedBackup() {
                try? restore(backup)
            }
            throw error
        }
    }

    /// 恢复开启前的代理设置
    @concurrent
    static func disable() async throws {
        guard let backup = storedBackup() else { return }
        try restore(backup)
        clearBackup()
    }

    /// 应用退出时同步恢复，异步任务可能来不及完成
    static func restoreIfNeeded() {
        guard let backup = storedBackup() else { return }
        try? restore(backup)
        clearBackup()
    }

    private static func restore(_ backup: Backup) throws {
        try apply(backup.web, kind: "webproxy", service: backup.service)
        try apply(backup.secureWeb, kind: "securewebproxy", service: backup.service)
        try apply(backup.socks, kind: "socksfirewallproxy", service: backup.service)
        // 空列表须传空参数，否则 networksetup 报参数错误
        try run(["-setproxybypassdomains", backup.service] + (backup.bypassDomains.isEmpty ? [""] : backup.bypassDomains))
    }

    /// 先写回地址再设置开关，使关闭后不会残留指向内核的地址
    private static func apply(_ setting: Setting, kind: String, service: String) throws {
        let usable = setting.enabled && !setting.server.isEmpty && setting.port > 0
        try run(["-set\(kind)", service, setting.server, String(setting.port)])
        try run(["-set\(kind)state", service, usable ? "on" : "off"])
    }

    /// 解析 -getwebproxy 等命令的输出
    private static func setting(_ kind: String, service: String) throws -> Setting {
        let output = try run(["-get\(kind)", service])
        var enabled = false
        var server = ""
        var port = 0
        for line in output.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "Enabled": enabled = value == "Yes"
            case "Server": server = value
            case "Port": port = Int(value) ?? 0
            default: break
            }
        }
        return Setting(enabled: enabled, server: server, port: port)
    }

    private static func readBypassDomains(service: String) throws -> [String] {
        try run(["-getproxybypassdomains", service])
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("There aren't any") }
    }

    @discardableResult
    private static func run(_ arguments: [String]) throws -> String {
        do {
            return try Networksetup.run(arguments)
        } catch NetworksetupError.commandFailed(let message) {
            throw SystemProxyError.commandFailed(message)
        } catch {
            throw SystemProxyError.commandFailed(error.localizedDescription)
        }
    }

    private static func storedBackup() -> Backup? {
        guard let data = UserDefaults.standard.data(forKey: backupKey) else { return nil }
        return try? JSONDecoder().decode(Backup.self, from: data)
    }

    private static func save(_ backup: Backup) {
        guard let data = try? JSONEncoder().encode(backup) else { return }
        UserDefaults.standard.set(data, forKey: backupKey)
    }

    private static func clearBackup() {
        UserDefaults.standard.removeObject(forKey: backupKey)
    }
}
