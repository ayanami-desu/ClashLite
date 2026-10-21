//
//  SystemDNS.swift
//  ClashLite
//

import Darwin
import Foundation

nonisolated enum SystemDNSError: LocalizedError {
    case noActiveService
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .noActiveService: String(localized: "No active network service")
        case .commandFailed(let message):
            message.isEmpty
                ? String(localized: "Unable to change the DNS settings")
                : message
        }
    }
}

/// 用 networksetup 接管系统 DNS：只把局域网/本地 DNS 换成公网服务器，
/// 让 TUN 能劫持原本直接发往本地地址的查询；关闭 TUN 或退出时恢复。
nonisolated enum SystemDNS {
    private static let backupKey = "systemDNSBackups"
    /// 剔除本地 DNS 后没有可用服务器时使用
    private static let fallbackServers = ["223.5.5.5", "119.29.29.29"]

    /// 串行化所有读写，避免退出恢复和正在进行的接管交错
    private static let lock = NSLock()
    private static var isShuttingDown = false

    struct Applied: Equatable {
        var service: String
        var servers: [String]
        /// 是否真的修改了系统设置
        var changed: Bool
    }

    private struct Backup: Codable {
        var service: String
        /// 原始 DNS，空数组表示原来使用 DHCP
        var original: [String]
        /// 写入的 DNS，用于判断当前值是否仍由我们设置
        var applied: [String]
    }

    static var hasBackup: Bool {
        !storedBackups().isEmpty
    }

    /// 读取主网络服务的 DNS 并接管；无需修改时 changed 为 false
    @concurrent
    static func enable(service requestedService: String? = nil) async throws -> Applied {
        guard let service = requestedService ?? SystemProxy.activeServiceName else {
            throw SystemDNSError.noActiveService
        }
        return try withLock { try enableLocked(service: service) }
    }

    private static func enableLocked(service: String) throws -> Applied {
        guard !isShuttingDown else {
            return Applied(service: service, servers: [], changed: false)
        }

        // 网络服务变了：先尽力恢复之前改过的服务；失败时保留备份，下次再试
        for backup in storedBackups().values where backup.service != service {
            do {
                _ = try restoreIfPossible(backup)
            } catch {
                NSLog("恢复 \(backup.service) 的 DNS 失败：\(error)")
            }
        }

        let current = try dnsServers(service: service)

        if let backup = storedBackups()[service] {
            if sameServers(current, backup.applied) {
                return Applied(service: service, servers: current, changed: true)
            }
            // 接管期间被手动改过，放弃旧备份，按当前值重新判断
            removeBackup(for: service)
        }

        guard let desired = plan(for: current) else {
            return Applied(service: service, servers: current, changed: false)
        }

        save(Backup(service: service, original: current, applied: desired))
        do {
            try setDNSServers(desired, service: service)
        } catch {
            // 写入失败时系统设置没有变化，不需要恢复
            removeBackup(for: service)
            throw error
        }
        return Applied(service: service, servers: desired, changed: true)
    }

    /// 恢复所有接管过的服务；返回目标服务恢复后的 DNS
    @concurrent
    static func disable(service requestedService: String? = nil) async throws -> [String]? {
        try withLock { try disableLocked(target: requestedService ?? SystemProxy.activeServiceName) }
    }

    private static func disableLocked(target: String?) throws -> [String]? {
        guard !isShuttingDown else { return nil }

        var restored: [String]?
        var lastError: Error?

        for backup in storedBackups().values {
            do {
                let didRestore = try restoreIfPossible(backup)
                if didRestore, backup.service == target {
                    restored = backup.original
                }
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }
        return restored
    }

    /// 应用退出时同步恢复，异步任务可能来不及完成
    static func restoreIfNeeded() {
        withLock {
            // 退出后不再接受新的接管
            isShuttingDown = true

            for backup in storedBackups().values {
                do {
                    _ = try restoreIfPossible(backup)
                } catch {
                    // 保留备份，下次启动再试
                    NSLog("恢复 \(backup.service) 的 DNS 失败：\(error)")
                }
            }
        }
    }

    private static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// 尝试恢复单个服务；返回是否真的写回了原设置
    private static func restoreIfPossible(_ backup: Backup) throws -> Bool {
        guard let current = try? dnsServers(service: backup.service) else {
            // 服务已被删除时备份没有意义；读取失败时保留，等下次重试
            if !serviceExists(backup.service) {
                removeBackup(for: backup.service)
            }
            return false
        }
        guard sameServers(current, backup.applied) else {
            // 用户手动改过，不覆盖
            removeBackup(for: backup.service)
            return false
        }
        try restore(backup)
        removeBackup(for: backup.service)
        return true
    }

    private static func serviceExists(_ service: String) -> Bool {
        guard let output = try? run(["-listallnetworkservices"]) else { return true }
        return output.split(whereSeparator: \.isNewline).contains { line in
            line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "*")) == service
        }
    }

    private static func restore(_ backup: Backup) throws {
        try setDNSServers(backup.original, service: backup.service)
    }

    private static func setDNSServers(_ servers: [String], service: String) throws {
        if servers.isEmpty {
            try run(["-setdnsservers", service, "Empty"])
        } else {
            try run(["-setdnsservers", service] + servers)
        }
    }

    private static func dnsServers(service: String) throws -> [String] {
        let output = try run(["-getdnsservers", service])
        return normalized(
            output
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("There aren't any") }
        )
    }

    /// 计算需要写入的 DNS；nil 表示当前值已经可用
    static func plan(for current: [String]) -> [String]? {
        let publicServers = normalized(current.filter { !isLocal($0) })
        let desired = publicServers.isEmpty ? fallbackServers : publicServers
        return sameServers(current, desired) ? nil : desired
    }

    /// 去重并保持顺序
    private static func normalized(_ servers: [String]) -> [String] {
        var seen = Set<String>()
        return servers.filter { seen.insert($0).inserted }
    }

    private static func sameServers(_ lhs: [String], _ rhs: [String]) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    /// 局域网、回环、链路本地、ULA 以及保留地址都无法被 TUN 劫持
    private static func isLocal(_ server: String) -> Bool {
        let address = server.split(separator: "%", maxSplits: 1).first.map(String.init) ?? server
        var bytes = [UInt8](repeating: 0, count: 16)

        if address.withCString({ inet_pton(AF_INET, $0, &bytes) }) == 1 {
            return isLocalIPv4(bytes[0], bytes[1], bytes[2])
        }

        if address.withCString({ inet_pton(AF_INET6, $0, &bytes) }) == 1 {
            // IPv4-mapped 地址按内嵌的 IPv4 判断
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return isLocalIPv4(bytes[12], bytes[13], bytes[14])
            }
            return bytes[0..<16].allSatisfy { $0 == 0 }
                || (bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] == 1)
                || (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80) // fe80::/10
                || (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0xC0) // fec0::/10
                || (bytes[0] & 0xFE) == 0xFC // fc00::/7
                || bytes[0] == 0xFF // ff00::/8
                || (bytes[0] == 0x01 && bytes[1] == 0x00 && bytes[2..<8].allSatisfy { $0 == 0 }) // 100::/64
                || (bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0D && bytes[3] == 0xB8) // 2001:db8::/32
                || (bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x00 && bytes[3] == 0x02 && bytes[4] == 0x00 && bytes[5] == 0x00) // 2001:2::/48
                || (bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x00 && (bytes[3] & 0xF0) == 0x10) // 2001:10::/28
                || (bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x00 && (bytes[3] & 0xF0) == 0x20) // 2001:20::/28
                || (bytes[0] == 0x3F && (bytes[1] & 0xF0) == 0xF0) // 3fff::/20
        }

        // 无法解析的地址按本地处理，避免留下不可用的服务器
        return true
    }

    private static func isLocalIPv4(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> Bool {
        a == 0
            || a == 10
            || a == 127
            || (a == 169 && b == 254)
            || (a == 172 && (16...31).contains(b))
            || (a == 192 && b == 168)
            || (a == 100 && (64...127).contains(b))
            || (a == 198 && (b == 18 || b == 19))
            || (a == 192 && b == 0 && (c == 0 || c == 2))
            || (a == 198 && b == 51 && c == 100)
            || (a == 203 && b == 0 && c == 113)
            || a >= 224
    }

    @discardableResult
    private static func run(_ arguments: [String]) throws -> String {
        do {
            return try Networksetup.run(arguments)
        } catch NetworksetupError.commandFailed(let message) {
            throw SystemDNSError.commandFailed(message)
        } catch {
            throw SystemDNSError.commandFailed(error.localizedDescription)
        }
    }

    private static func storedBackups() -> [String: Backup] {
        guard let data = UserDefaults.standard.data(forKey: backupKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Backup].self, from: data)) ?? [:]
    }

    private static func save(_ backup: Backup) {
        var backups = storedBackups()
        backups[backup.service] = backup
        write(backups)
    }

    private static func removeBackup(for service: String) {
        var backups = storedBackups()
        guard backups.removeValue(forKey: service) != nil else { return }
        write(backups)
    }

    private static func write(_ backups: [String: Backup]) {
        if backups.isEmpty {
            UserDefaults.standard.removeObject(forKey: backupKey)
        } else if let data = try? JSONEncoder().encode(backups) {
            UserDefaults.standard.set(data, forKey: backupKey)
        }
    }
}
