import Carbon
import Foundation

/// 记录一项系统操作的最终结果，供设置页显示。
struct StepResult: Codable, Sendable {
    /// 系统回读的状态是否达到了本次操作的目标。
    let succeeded: Bool

    /// 面向用户的执行结果，失败时包含可以据此排查的信息。
    let message: String
}

/// 集中处理游戏模式对系统输入源和输出音量的修改。
enum SystemControls {
    /// 用稳定的系统标识定位 ABC，避免受系统显示语言影响。
    private static let abcID = "com.apple.keylayout.ABC"

    /// 在主线程选择已启用的 ABC 输入源，并回读系统当前的输入源。
    @MainActor
    static func selectABC() -> StepResult {
        let filter: [String: Any] = [
            kTISPropertyInputSourceID as String: abcID,
            kTISPropertyInputSourceIsSelectCapable as String: true
        ]

        guard
            let sources = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue(),
            let abc = (sources as NSArray as? [TISInputSource])?.first
        else {
            return StepResult(succeeded: false, message: "ABC 输入法不可用，请在系统键盘设置中启用 ABC。")
        }

        let status = TISSelectInputSource(abc)
        guard status == noErr else {
            return StepResult(succeeded: false, message: "切换 ABC 失败（系统错误 \(status)）。")
        }

        guard
            let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
            let identifier = TISGetInputSourceProperty(current, kTISPropertyInputSourceID),
            Unmanaged<CFString>.fromOpaque(identifier).takeUnretainedValue() as String == abcID
        else {
            return StepResult(succeeded: false, message: "系统当前输入源未切换到 ABC。")
        }

        return StepResult(succeeded: true, message: "输入法已切换到 ABC。")
    }

    /// 将当前设备的输出音量设为 50%，同时解除静音并确认系统实际值。
    @MainActor
    static func setVolumeToFiftyPercent() async -> StepResult {
        await Task.detached(priority: .userInitiated) {
            applyOutputVolume()
        }.value
    }

    /// 在后台调用系统音量指令并收集输出，让菜单栏和设置窗口保持响应。
    private static func applyOutputVolume() -> StepResult {
        let script = """
            set volume output volume 50 output muted false
            set audioSettings to get volume settings
            return (output volume of audioSettings as text) & ":" & (output muted of audioSettings as text)
            """
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            return StepResult(succeeded: false, message: "无法启动系统音量设置（\(error.localizedDescription)）。")
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let reply = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            let detail = reply.isEmpty ? "系统错误 \(process.terminationStatus)" : reply
            return StepResult(succeeded: false, message: "无法设置当前输出设备的音量（\(detail)）。")
        }

        let fields = reply.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2, let volume = Int(fields[0]) else {
            return StepResult(succeeded: false, message: "当前输出设备未报告系统音量，可能需要通过设备调节。")
        }

        guard volume == 50, fields[1] == "false" else {
            let muteDescription = fields[1] == "true" ? "，当前仍为静音" : ""
            return StepResult(succeeded: false, message: "目标音量为 50%，系统报告为 \(volume)%\(muteDescription)。")
        }

        return StepResult(succeeded: true, message: "输出音量已设为 50%。")
    }
}
