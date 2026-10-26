//
//  CoreConfig.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import Foundation
import Yams

enum CoreConfigError: LocalizedError {
    case readFailed
    case invalidContent

    var errorDescription: String? {
        switch self {
        case .readFailed: String(localized: "Unable to read the profile file")
        case .invalidContent: String(localized: "The profile is not a valid YAML mapping")
        }
    }
}

/// 在配置文件之上依次合并配置覆写、全局覆写和应用内的设置，生成交给内核的最终配置
nonisolated struct CoreConfig {
    var mode: ProxyMode
    var isTunEnabled: Bool
    var controller: CoreController

    /// 配置未指定面板下载地址时使用的面板
    static let defaultUIURL = "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"

    struct Rendered {
        var payload: String
        /// 面板所在的子目录（external-ui-name）
        var uiName: String?
        /// 内核自行配置系统 DNS（tun.dns-mode 非 disabled）
        var kernelResolvesDNS: Bool
    }

    func render(profileURL: URL) throws -> Rendered {
        let text: String
        do {
            text = try String(contentsOf: profileURL, encoding: .utf8)
        } catch {
            NSLog("读取配置失败：\(error)")
            throw CoreConfigError.readFailed
        }

        var root = try Self.mapping(from: text)
        // 文件名即配置名称
        let name = profileURL.deletingPathExtension().lastPathComponent
        try ConfigOverride.profile(name).apply(to: &root)
        try ConfigOverride.global.apply(to: &root)

        root["mode"] = Node(mode.rawValue)
        root["external-controller"] = Node(controller.address)
        root["secret"] = Node(controller.secret, .implicit, .doubleQuoted)
        applyUI(to: &root)
        applyTun(to: &root)

        let uiName = root["external-ui-name"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        return Rendered(
            payload: try Self.serialize(root),
            uiName: uiName,
            kernelResolvesDNS: Self.kernelResolvesDNS(in: root)
        )
    }

    /// 与内核一致：dns-mode 为空时 macOS 默认 disabled，其余非 disabled 值由内核把 TUN 地址设为系统 DNS
    private static func kernelResolvesDNS(in root: Node.Mapping) -> Bool {
        guard let mode = root["tun"]?.mapping?["dns-mode"]?.string else { return false }
        return !mode.isEmpty && mode != "disabled"
    }

    /// 配置须为 YAML 映射
    static func mapping(from text: String) throws -> Node.Mapping {
        guard case .mapping(let root) = try Yams.compose(yaml: text) else {
            throw CoreConfigError.invalidContent
        }
        return root
    }

    static func serialize(_ root: Node.Mapping) throws -> String {
        try Yams.serialize(node: .mapping(root), width: -1, allowUnicode: true)
    }

    /// 面板由内核托管在工作目录中的随机目录下，未指定下载地址时使用 metacubexd
    private func applyUI(to root: inout Node.Mapping) {
        root["external-ui"] = Node(controller.uiPath)
        if root["external-ui-url"]?.string?.isEmpty ?? true {
            root["external-ui-url"] = Node(Self.defaultUIURL)
        }
    }

    /// 参考 clash-verge-rev 的 use_tun：开启 TUN 时确保 DNS 以 fake-ip 模式工作
    private func applyTun(to root: inout Node.Mapping) {
        var tun = root["tun"]?.mapping ?? [:]
        tun["enable"] = Node(String(isTunEnabled))
        root["tun"] = .mapping(tun)

        guard isTunEnabled else { return }

        var dns = root["dns"]?.mapping ?? [:]
        let enhancedMode = dns["enhanced-mode"]?.string
        guard enhancedMode == nil || enhancedMode == "fake-ip" else { return }

        let ipv6 = root["ipv6"]?.bool ?? false
        dns["enable"] = Node("true")
        dns["ipv6"] = Node(String(ipv6))
        if enhancedMode == nil {
            dns["enhanced-mode"] = Node("fake-ip")
        }
        if dns["fake-ip-range"] == nil {
            dns["fake-ip-range"] = Node("198.18.0.1/16")
        }
        if ipv6, dns["fake-ip-range6"] == nil {
            dns["fake-ip-range6"] = Node("2001:2::0/64")
        }
        root["dns"] = .mapping(dns)
    }
}
