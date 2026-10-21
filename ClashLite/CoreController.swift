//
//  CoreController.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import Foundation

enum CoreControllerError: LocalizedError {
    case badStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let message):
            message.isEmpty ? String(localized: "Core API request failed (HTTP \(code))") : message
        }
    }
}

/// 内核的 RESTful API（external-controller）
nonisolated struct CoreController {
    static let host = "127.0.0.1"
    static let port = 9097

    var secret: String
    /// 面板目录（external-ui），相对内核工作目录
    var uiPath: String

    var address: String { "\(Self.host):\(Self.port)" }

    private var baseURL: URL { URL(string: "http://\(address)")! }

    /// 首次使用时生成随机密钥和面板目录并保存，使面板中保存的后端在重启后依然有效
    static func load() -> CoreController {
        CoreController(
            secret: stored("controllerSecret") { UUID().uuidString },
            uiPath: stored("externalUIPath") { randomPath() }
        )
    }

    private static func stored(_ key: String, default make: () -> String) -> String {
        if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty {
            return value
        }
        let value = make()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    /// 数字和小写字母组成的随机目录名
    private static func randomPath() -> String {
        let characters = "0123456789abcdefghijklmnopqrstuvwxyz"
        return String((0..<16).map { _ in characters.randomElement()! })
    }

    /// 打开内核托管的面板，通过 metacubexd 的 hash 路由传入连接参数
    func panelURL(uiName: String?) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = uiName.map { "/ui/\($0)/" } ?? "/ui/"
        var route = URLComponents()
        route.queryItems = [
            URLQueryItem(name: "hostname", value: Self.host),
            URLQueryItem(name: "port", value: String(Self.port)),
            URLQueryItem(name: "secret", value: secret),
        ]
        // 路由查询参数中的加号须编码，避免被前端解析为空格。
        let query = route.percentEncodedQuery!.replacingOccurrences(of: "+", with: "%2B")
        components.percentEncodedFragment = "/setup?\(query)"
        return components.url!
    }

    /// POST /upgrade/ui，从 external-ui-url 重新下载面板
    func upgradeUI() async throws {
        try await send("POST", "/upgrade/ui", timeout: 120)
    }

    /// GET /version，返回内核版本
    func version() async throws -> String {
        struct Response: Decodable { var version: String }
        let data = try await send("GET", "/version", timeout: 1)
        return try JSONDecoder().decode(Response.self, from: data).version
    }

    /// 内核当前生效的设置，仅解析需要同步的字段
    struct RuntimeConfig: Decodable {
        struct Tun: Decodable { var enable: Bool }
        var mode: String
        var tun: Tun?
        var mixedPort: Int?
        var port: Int?
        var socksPort: Int?

        private enum CodingKeys: String, CodingKey {
            case mode, tun, port
            case mixedPort = "mixed-port"
            case socksPort = "socks-port"
        }
    }

    /// GET /configs，读取内核当前设置（可能已被面板修改）
    func configs() async throws -> RuntimeConfig {
        let data = try await send("GET", "/configs")
        return try JSONDecoder().decode(RuntimeConfig.self, from: data)
    }

    /// PATCH /configs，仅修改运行中的部分字段
    func patchConfigs(_ body: [String: Any]) async throws {
        try await send("PATCH", "/configs", body: body)
    }

    /// 节点或策略组，策略组才有 all 和 now
    struct Proxy: Decodable {
        struct History: Decodable { var delay: Int }
        struct Extra: Decodable { var history: [History]? }
        var type: String
        var all: [String]?
        var now: String?
        /// URLTest、Fallback 手动锁定的节点，空字符串表示自动选择
        var fixed: String?
        var hidden: Bool?
        var history: [History]?
        /// 按测速 URL 分别记录的结果，策略组自定义了 url 时测速结果只在这里
        var extra: [String: Extra]?
        /// 策略组的测速 URL
        var testUrl: String?
    }

    /// GET /proxies，读取全部节点和策略组
    func proxies() async throws -> [String: Proxy] {
        struct Response: Decodable { var proxies: [String: Proxy] }
        let data = try await send("GET", "/proxies")
        return try JSONDecoder().decode(Response.self, from: data).proxies
    }

    /// PUT /proxies/{group}，切换策略组选中的节点
    func selectProxy(_ name: String, in group: String) async throws {
        try await send("PUT", Self.proxyPath(group), body: ["name": name])
    }

    /// DELETE /proxies/{group}，解除 URLTest、Fallback 的锁定，同时清除内核缓存中的选择
    func unfixProxy(in group: String) async throws {
        try await send("DELETE", Self.proxyPath(group))
    }

    private static func proxyPath(_ group: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return "/proxies/" + (group.addingPercentEncoding(withAllowedCharacters: allowed) ?? group)
    }

    /// DELETE /connections，关闭当前所有连接
    func closeAllConnections() async throws {
        try await send("DELETE", "/connections")
    }

    /// PUT /configs，以完整配置内容重新加载内核
    func reloadConfigs(payload: String) async throws {
        try await send("PUT", "/configs?force=true", body: ["path": "", "payload": payload], timeout: 30)
    }

    @discardableResult
    private func send(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 5) async throws -> Data {
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            struct Message: Decodable { var message: String }
            let message = (try? JSONDecoder().decode(Message.self, from: data))?.message ?? ""
            throw CoreControllerError.badStatus(http.statusCode, message)
        }
        return data
    }
}
