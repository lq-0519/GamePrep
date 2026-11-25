import AppKit
import CoreGraphics

/// 标识本次右键执行选中的一台外接显示器，供音频匹配及显示模式切换使用。
struct GameDisplay: Sendable {
    /// Quartz 在当前连接期间分配的显示器标识，镜像组内的屏幕也各自保有标识。
    private let id: CGDirectDisplayID
    /// AppKit 为同一显示器提供的名称，用来匹配数字音频设备。
    let name: String?

    /// 表示已定位目标，或记录无法安全选中外接显示器的具体原因。
    enum Selection {
        /// 选中唯一外屏，或在多台外屏中选中了系统主显示器。
        case selected(GameDisplay)
        /// 没有外屏、无法明确选中目标，或系统枚举失败。
        case unavailable(StepResult)
    }

    /// 枚举实际在线的显示器，而不是从浮层使用的逻辑屏列表推断外接情况。
    @MainActor
    static func selectExternal() -> Selection {
        var count: UInt32 = 0
        let countStatus = CGGetOnlineDisplayList(0, nil, &count)
        guard countStatus == .success else {
            return .unavailable(StepResult(succeeded: false, message: "无法检测显示器（\(countStatus.rawValue)）。"))
        }
        guard count > 0 else {
            return .unavailable(StepResult.skipped("未检测到外接显示器，跳过声音输出和显示分辨率。"))
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let listStatus = CGGetOnlineDisplayList(count, &displayIDs, &count)
        guard listStatus == .success else {
            return .unavailable(StepResult(succeeded: false, message: "无法读取显示器列表（\(listStatus.rawValue)）。"))
        }
        let externalIDs = displayIDs.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
        guard let firstExternal = externalIDs.first else {
            return .unavailable(StepResult.skipped("未检测到外接显示器，跳过声音输出和显示分辨率。"))
        }

        let mainID = CGMainDisplayID()
        guard externalIDs.count == 1 || externalIDs.contains(mainID) else {
            return .unavailable(StepResult.skipped("检测到多台外接显示器，且没有一台是主显示器，跳过声音输出和显示分辨率。"))
        }
        let id = externalIDs.count == 1 ? firstExternal : mainID
        let screenNames = NSScreen.screens.compactMap { screen -> (id: CGDirectDisplayID, name: String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  externalIDs.contains(number.uint32Value) else { return nil }
            return (number.uint32Value, screen.localizedName)
        }
        // 两台同名外屏即使只有一个音频端点，也无法仅凭名称确定它属于哪一台。
        let name = screenNames.first { $0.id == id }?.name
        let uniqueName = name.flatMap { candidate in
            screenNames.filter { $0.name.localizedCaseInsensitiveCompare(candidate) == .orderedSame }.count == 1
                ? candidate : nil
        }
        return .selected(GameDisplay(id: id, name: uniqueName))
    }

    /// 在当前登录会话切换到 2560 × 1440 HiDPI，并回读结果；实际提交后需要重新核对 HDMI 音频。
    func setGameResolution() -> (step: StepResult, didReconfigure: Bool) {
        let label = name ?? "外接显示器"
        guard let current = CGDisplayCopyDisplayMode(id) else {
            return (StepResult(succeeded: false, message: "无法读取「\(label)」的当前显示模式。"), false)
        }
        if Self.isGameMode(current) {
            return (StepResult(succeeded: true, message: "「\(label)」已是 2560 × 1440 HiDPI。"), false)
        }

        // 同一桌面尺寸可同时有普通与 HiDPI 档，枚举重复档位后用渲染像素尺寸准确区分。
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        let available = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
        let candidates = available.filter { Self.isGameMode($0) && $0.isUsableForDesktopGUI() }
        // 优先保留现有刷新率，其次选择 60 Hz，再从该显示器实际提供的档位中选择最高刷新率。
        guard let target = candidates.first(where: { abs($0.refreshRate - current.refreshRate) < 0.01 })
                ?? candidates.first(where: { abs($0.refreshRate - 60) < 0.01 })
                ?? candidates.max(by: { $0.refreshRate < $1.refreshRate }) else {
            return (StepResult.skipped("「\(label)」没有可用的 2560 × 1440 HiDPI 档位。"), false)
        }

        var configuration: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&configuration)
        guard begin == .success, let configuration else {
            return (StepResult(succeeded: false, message: "无法创建显示配置（\(begin.rawValue)）。"), false)
        }
        let configured = CGConfigureDisplayWithDisplayMode(configuration, id, target, nil)
        guard configured == .success else {
            _ = CGCancelDisplayConfiguration(configuration)
            return (StepResult(succeeded: false, message: "无法配置「\(label)」的显示模式（\(configured.rawValue)）。"), false)
        }
        let applied = CGCompleteDisplayConfiguration(configuration, .forSession)
        guard applied == .success else {
            return (StepResult(succeeded: false, message: "无法切换「\(label)」的显示模式（\(applied.rawValue)）。"), false)
        }
        guard let actual = CGDisplayCopyDisplayMode(id), Self.isGameMode(actual) else {
            return (StepResult(succeeded: false, message: "「\(label)」切换后未读到 2560 × 1440 HiDPI。"), true)
        }
        return (StepResult(succeeded: true, message: "「\(label)」已切换到 2560 × 1440 HiDPI。"), true)
    }

    /// 同时校验桌面尺寸与 2 倍渲染尺寸，保证选中的是系统显示设置中的缩放档。
    private static func isGameMode(_ mode: CGDisplayMode) -> Bool {
        mode.width == 2560 && mode.height == 1440 && mode.pixelWidth == 5120 && mode.pixelHeight == 2880
    }
}
