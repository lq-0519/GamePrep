import Carbon
import Foundation

/// 记录一项系统操作的最终结果，供设置页显示。
struct StepResult: Codable, Sendable {
    /// 系统回读的状态是否达到了本次操作的目标。
    let succeeded: Bool

    /// 面向用户的执行结果，失败时包含可以据此排查的信息。
    let message: String
}

/// 集中处理游戏模式中的 Finder 窗口、系统输入源和输出音量操作。
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

    /// 在后台请求 Finder 关闭可关闭窗口，并回读结果。自动化等待不会占用界面线程。
    @MainActor
    static func closeFinderWindows() async -> StepResult {
        await Task.detached(priority: .userInitiated) {
            applyFinderWindowCleanup()
        }.value
    }

    /// 枚举 Finder 窗口并按稳定标识逐个关闭。无关闭按钮的窗口（包括桌面）会被跳过。
    /// 每次 Apple 事件和整个脚本都设有等待上限，遇到权限问题时保留独立的步骤结果。
    private static func applyFinderWindowCleanup() -> StepResult {
        let script = """
            on closeableWindowIDs()
                tell application id "com.apple.finder"
                    set windowIDs to {}
                    repeat with candidateRef in (get every window)
                        set candidate to contents of candidateRef
                        try
                            if (closeable of candidate) is true then set end of windowIDs to id of candidate
                        on error errorMessage number errorNumber
                            if errorNumber is not -1728 then error errorMessage number errorNumber
                        end try
                    end repeat
                    return windowIDs
                end tell
            end closeableWindowIDs

            with timeout of 4 seconds
                tell application id "com.apple.finder"
                    if it is not running then return "not-running"
                    set windowIDs to my closeableWindowIDs()
                    set countBefore to length of windowIDs
                    if countBefore is 0 then return "0:0:"
                    set closeError to ""
                    repeat with windowIDRef in windowIDs
                        set targetID to contents of windowIDRef
                        try
                            close window id targetID
                        on error errorMessage number errorNumber
                            if errorNumber is -1743 then error errorMessage number errorNumber
                            if errorNumber is not -1728 and closeError is "" then
                                set closeError to "系统错误 " & errorNumber & ": " & errorMessage
                            end if
                        end try
                    end repeat
                    if it is not running then return "not-running"
                    set countAfter to length of (my closeableWindowIDs())
                    return (countBefore as text) & ":" & (countAfter as text) & ":" & closeError
                end tell
            end timeout
            """
        let result: (status: Int32, reason: Process.TerminationReason, reply: String)
        do {
            result = try executeAppleScript(script, timeout: .seconds(30))
        } catch {
            return StepResult(succeeded: false, message: "无法启动 Finder 窗口清理（\(error.localizedDescription)）。")
        }

        guard result.status == 0 else {
            if result.reply.hasSuffix("(-1743)") {
                return StepResult(succeeded: false, message: "未获准控制 Finder。可在「系统设置 → 隐私与安全性 → 自动化」中允许 GamePrep 控制 Finder。")
            }
            if (result.reason == .uncaughtSignal && result.status == SIGTERM) || result.reply.hasSuffix("(-1712)") {
                return StepResult(succeeded: false, message: "等待 Finder 响应或自动化授权超时，无法确认窗口关闭结果。")
            }
            let detail = result.reply.isEmpty ? "系统错误 \(result.status)" : result.reply
            return StepResult(succeeded: false, message: "无法关闭或核对 Finder 窗口（\(detail)）。")
        }
        if result.reply == "not-running" {
            return StepResult(succeeded: true, message: "Finder 当前未运行。")
        }

        let fields = result.reply.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, let countBefore = Int(fields[0]), let remaining = Int(fields[1]) else {
            return StepResult(succeeded: false, message: "无法确认 Finder 窗口关闭结果。")
        }
        let detail = fields[2].isEmpty ? "" : "（\(fields[2])）"
        if remaining > 0 {
            return StepResult(succeeded: false, message: "Finder 仍有 \(remaining) 个可关闭窗口\(detail)。")
        }
        let message = countBefore == 0 ? "Finder 没有需要关闭的窗口。" : "Finder 可关闭的窗口已关闭\(detail)。"
        return StepResult(succeeded: true, message: message)
    }

    /// 在后台调用系统音量指令并收集输出，让菜单栏和设置窗口保持响应。
    private static func applyOutputVolume() -> StepResult {
        let script = """
            set volume output volume 50 output muted false
            set audioSettings to get volume settings
            return (output volume of audioSettings as text) & ":" & (output muted of audioSettings as text)
            """
        let result: (status: Int32, reason: Process.TerminationReason, reply: String)
        do {
            result = try executeAppleScript(script)
        } catch {
            return StepResult(succeeded: false, message: "无法启动系统音量设置（\(error.localizedDescription)）。")
        }

        guard result.status == 0 else {
            let detail = result.reply.isEmpty ? "系统错误 \(result.status)" : result.reply
            return StepResult(succeeded: false, message: "无法设置当前输出设备的音量（\(detail)）。")
        }

        let fields = result.reply.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2, let volume = Int(fields[0]) else {
            return StepResult(succeeded: false, message: "当前输出设备未报告系统音量，可能需要通过设备调节。")
        }

        guard volume == 50, fields[1] == "false" else {
            let muteDescription = fields[1] == "true" ? "，当前仍为静音" : ""
            return StepResult(succeeded: false, message: "目标音量为 50%，系统报告为 \(volume)%\(muteDescription)。")
        }

        return StepResult(succeeded: true, message: "输出音量已设为 50%。")
    }

    /// 合并并持续读取脚本的输出与错误，避免进程因输出管道写满而阻塞。
    /// 指定总时限时只终止本次 osascript 子进程，避免等待权限提示影响游戏模式完成。
    private static func executeAppleScript(
        _ script: String, timeout: DispatchTimeInterval? = nil
    ) throws -> (status: Int32, reason: Process.TerminationReason, reply: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = output
        process.standardError = output
        try process.run()

        let watchdog = timeout.map { interval in
            let work = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interval, execute: work)
            return work
        }
        defer { watchdog?.cancel() }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let reply = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, process.terminationReason, reply)
    }
}
