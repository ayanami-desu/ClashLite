//
//  Networksetup.swift
//  ClashLite
//

import Foundation

nonisolated enum NetworksetupError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            message.isEmpty
                ? String(localized: "Unable to change the network settings")
                : message
        }
    }
}

/// 调用 /usr/sbin/networksetup；修改网络设置需要管理员账户
nonisolated enum Networksetup {
    @discardableResult
    static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/networksetup")
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw NetworksetupError.commandFailed(error.localizedDescription)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NetworksetupError.commandFailed(message)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
