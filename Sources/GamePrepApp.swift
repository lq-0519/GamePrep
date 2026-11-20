import AppKit
import SwiftUI

/// 管理菜单栏交互和设置窗口，整个进程仅保留一个设置窗口实例。
@MainActor
final class GamePrepDelegate: NSObject, NSApplicationDelegate {
    /// 持有设置和执行状态，供菜单栏与设置窗口共同使用。
    private let model = GamePrepModel()
    /// 保持系统状态栏按钮存活，直到用户退出工具。
    private var statusItem: NSStatusItem?
    /// 复用设置窗口及其滚动位置，关闭窗口时保留窗口实例。
    private var settingsWindow: NSWindow?

    /// 注册菜单栏按钮和应用变化通知，未配置时打开白名单预览。
    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("游戏模式")
        }
        updateStatus()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(runningApplicationsChanged(_:)),
                           name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(runningApplicationsChanged(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        if !model.hasConfigured { showSettings() }
    }

    /// 从「应用程序」再次打开游戏模式时，唤回同一个设置窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// 左键只打开设置。右键在首次确认后启动游戏模式，执行中忽略重复点击。
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard NSApp.currentEvent?.type == .rightMouseUp else {
            showSettings()
            return
        }
        guard model.hasConfigured else {
            showSettings()
            return
        }
        guard !model.isRunning else { return }
        sender.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "游戏模式执行中")
        sender.toolTip = "游戏模式执行中 · 左键查看进度"
        Task { @MainActor in
            await model.run()
            updateStatus()
        }
    }

    /// 设置页打开时更新预览，设置页关闭时保持菜单栏工具空闲。
    @objc private nonisolated func runningApplicationsChanged(_ notification: Notification) {
        Task { @MainActor in
            guard settingsWindow?.isVisible == true else { return }
            model.refreshRunningApps()
        }
    }

    /// 打开或唤回白名单及执行结果窗口。
    private func showSettings() {
        model.refreshRunningApps()
        let window: NSWindow
        if let existing = settingsWindow {
            window = existing
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 650),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "游戏模式"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 510, height: 420)
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            window.setFrameAutosaveName("GamePrepSettings")
            if !window.setFrameUsingName("GamePrepSettings") { window.center() }
            settingsWindow = window
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !NSApp.isActive { NSApp.activate() }
        window.makeKeyAndOrderFront(nil)
        // 激活请求可能延迟或被系统拒绝，在当前普通窗口层立即将设置窗口移到最前面。
        window.orderFrontRegardless()
    }

    /// 还原菜单栏图标，最近一次结果留在设置页查看。
    private func updateStatus() {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "游戏模式")
        button.toolTip = "游戏模式 · 左键设置 · 右键执行"
    }
}

/// 在主线程启动菜单栏应用，设置窗口关闭后继续回应菜单栏点击。
@main
@MainActor
enum GamePrepApp {
    /// 在整个 AppKit 事件循环中保持应用代理存活。
    static func main() {
        let app = NSApplication.shared
        let delegate = GamePrepDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
