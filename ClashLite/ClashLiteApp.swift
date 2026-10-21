//
//  ClashLiteApp.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import SwiftUI

nonisolated enum ProxyMode: String, CaseIterable, Identifiable {
    case rule
    case global
    case direct

    var id: Self { self }

    var title: String {
        switch self {
        case .rule: String(localized: "Rule")
        case .global: String(localized: "Global")
        case .direct: String(localized: "Direct")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 注销、关机等由系统发出的退出请求不弹窗，避免阻塞
        if NSAppleEventManager.shared().currentAppleEvent?.eventID == kAEQuitApplication {
            return .terminateNow
        }

        NSApplication.shared.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Are you sure you want to quit ClashLite?")
        alert.informativeText = String(localized: "The core will stop running after quitting.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

@main
struct ClashLiteApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var coreVersion = CoreVersionMonitor()
    @State private var launchAtLogin = LaunchAtLogin()
    @State private var profileStore: ProfileStore
    @State private var core: CoreManager

    init() {
        CoreDirectory.installBundledIfNeeded()
        let profileStore = ProfileStore()
        let core = CoreManager(profileStore: profileStore)
        // 手动或自动更新正在使用的订阅后，重新加载内核
        profileStore.onUpdate = { [weak profileStore, weak core] name in
            if profileStore?.selectedName == name {
                core?.reload()
            }
        }
        _profileStore = State(initialValue: profileStore)
        _core = State(initialValue: core)
    }

    var body: some Scene {
        MenuBarExtra {
            Text("Core: \(core.status.title)")

            Button("Open Dashboard") {
                core.openPanel()
            }
            .disabled(core.status != .running || core.isUpdatingPanel)

            Button(core.isUpdatingPanel ? "Downloading Dashboard…" : "Update Dashboard") {
                core.updatePanel()
            }
            .disabled(core.status != .running || core.isUpdatingPanel)

            Toggle("TUN Mode", isOn: Binding(get: { core.isTunEnabled }, set: { core.setTunEnabled($0) }))

            Toggle("System Proxy", isOn: Binding(
                get: { core.isSystemProxyEnabled },
                set: { core.setSystemProxyEnabled($0) }
            ))

            Divider()

            ProfileMenu(profileStore: profileStore, core: core)

            Picker("Mode: \(core.mode.title)", selection: $core.mode) {
                ForEach(ProxyMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Menu("Proxy Groups") {
                ForEach(core.proxyGroups) { group in
                    Menu(group.name) {
                        if group.fixed != nil {
                            Button("Unpin") {
                                core.unfixProxy(in: group.name)
                            }

                            Divider()
                        }

                        // 用 Toggle 而非 Picker，菜单项才能带 badge
                        ForEach(group.members) { member in
                            Toggle(member.name, isOn: Binding(
                                get: { group.now == member.name },
                                set: { isOn in
                                    if isOn { core.selectProxy(member.name, in: group.name) }
                                }
                            ))
                            .badge(member.delayText)
                        }
                        .disabled(!group.isSelectable)
                    }
                    // 菜单中的 badge 对应 NSMenuItem.badge，显示在右侧且颜色较淡
                    .badge(group.now)
                }
            }
            .disabled(core.proxyGroups.isEmpty)

            Divider()

            Menu("More") {
                Text("App Version")
                    .badge(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)

                Text("Core Version")
                    .badge(coreVersion.version)

                Divider()

                Button("Restart Core") {
                    core.restart()
                }
                .disabled(profileStore.selected == nil)

                Button("Close All Connections") {
                    core.closeAllConnections()
                }
                .disabled(core.status != .running)

                Divider()

                Button("Open Core Folder") {
                    CoreDirectory.open()
                }

                Button("Open Profiles Folder") {
                    ProfileDirectory.open(selecting: profileStore.selected?.fileURL)
                }
            }

            Toggle("Launch at Login", isOn: Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.setEnabled($0) }))

            Button("Quit ClashLite") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(core.isTunEnabled ? .menuBarIconTun : .menuBarIcon)
                .accessibilityLabel(Text(verbatim: "ClashLite"))
        }

        Window("Add Profile", id: AddProfileView.windowID) {
            AddProfileView()
                .environment(profileStore)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        WindowGroup("Edit Profile", id: ProfileEditorView.windowID, for: String.self) { $name in
            if let name {
                ProfileEditorView(name: name)
                    .environment(core)
                    .environment(profileStore)
            }
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Runtime Config", id: RuntimeConfigView.windowID) {
            RuntimeConfigView()
                .environment(core)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        WindowGroup("Override", id: ConfigOverrideView.windowID, for: ConfigOverride.self) { $target in
            if let target {
                ConfigOverrideView(target: target)
                    .environment(core)
                    .environment(profileStore)
            }
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}
