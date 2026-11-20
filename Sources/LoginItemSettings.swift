import Combine
import Foundation
import ServiceManagement

/// 管理游戏模式在 macOS 登录项中的登记状态和首次默认设置。
@MainActor
final class LoginItemSettings: ObservableObject {
    /// 最近一次从系统读取的状态，界面根据实际登记结果显示开关。
    @Published private var status: SMAppService.Status = .notRegistered
    /// 最近一次更新登录项失败时显示给用户的系统错误。
    @Published private(set) var errorMessage: String?

    /// 对应游戏模式主应用的登录项，关闭时只取消以后登录的启动登记。
    private let service = SMAppService.mainApp
    /// 保存默认设置的初始化标记，后续启动尊重用户在应用或系统中的修改。
    private let defaultAppliedKey = "gamePrepLoginItemDefaultApplied"

    /// 系统已登记并允许在登录时启动。
    var isEnabled: Bool { status == .enabled }

    /// 登录项仍需用户在系统设置中批准，或用户已在那里撤销允许。
    var requiresApproval: Bool { status == .requiresApproval }

    /// 首次打开新版本时登记默认登录项。已有系统记录时沿用其状态。
    func applyDefaultIfNeeded() {
        refreshStatus()
        guard !UserDefaults.standard.bool(forKey: defaultAppliedKey) else { return }

        switch status {
        case .enabled, .requiresApproval:
            UserDefaults.standard.set(true, forKey: defaultAppliedKey)
        case .notRegistered, .notFound:
            setEnabled(true)
        @unknown default:
            break
        }
    }

    /// 重新读取系统状态，反映用户在系统设置中的修改。
    func refreshStatus() {
        status = service.status
    }

    /// 登记或移除当前应用的登录项，并用实际系统状态更新界面。
    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        refreshStatus()
        if enabled && requiresApproval {
            openSystemSettings()
            return
        }

        do {
            if enabled && !isEnabled {
                try service.register()
            } else if !enabled && (isEnabled || requiresApproval) {
                try service.unregister()
            }
            UserDefaults.standard.set(true, forKey: defaultAppliedKey)
            refreshStatus()
        } catch {
            refreshStatus()
            // 系统状态可能在操作期间变化，只在目标未达成时显示错误。
            if isEnabled != enabled && !(enabled && requiresApproval) {
                errorMessage = "更新登录项失败：\(error.localizedDescription)"
            }
        }
    }

    /// 打开 macOS 登录项页面，由用户查看或批准该应用。
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
