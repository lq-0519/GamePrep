import Foundation

/// 读取指定游戏进程的 Metal 呈现帧率，采集进程的启停由游戏监测会话管理。
@MainActor
final class GameFPSMonitor {
    /// 使用系统自带的工具，避免通过 PATH 找到其他同名程序。
    private static let toolPath = "/usr/bin/metalperftrace"

    /// 系统未提供采集工具时，调用方仍可显示其它性能数据。
    static let isSupported = FileManager.default.isExecutableFile(atPath: toolPath)

    /// 记录本次尝试的进程，采集退出后也保留到停止或切换目标，避免反复启动工具。
    private var targetPID: pid_t?
    /// 每次启动使用独立标识，丢弃旧管道或旧采集进程迟到的回调。
    private var readerID: UUID?
    /// 保存正在读取的系统工具进程，关闭监测时向该进程发送退出请求。
    private var process: Process?
    /// 用于接收标准输出，关闭监测时同时注销事件处理并关闭读取端。
    private var output: FileHandle?
    /// 通知界面有效的 FPS；当前采集失败或退出时通知空值。
    private var onReading: (@MainActor (Double?) -> Void)?
    /// 暂存被管道分割的 JSON 对象，仅由主线程按到达顺序更新。
    private var parser = MetalFPSParser()

    /// 为指定 PID 启动只读采集。同一监测目标只尝试启动一次，避免重复占用系统资源。
    func start(pid: pid_t, onReading: @escaping @MainActor (Double?) -> Void) {
        guard targetPID != pid else { return }
        stop()
        targetPID = pid
        guard pid > 0, Self.isSupported else {
            onReading(nil)
            return
        }

        let readerID = UUID()
        let process = Process()
        let pipe = Pipe()
        let output = pipe.fileHandleForReading
        process.executableURL = URL(fileURLWithPath: Self.toolPath)
        process.arguments = ["listen", "--json", "--interval", "1", "--pid", String(pid)]
        var environment = ProcessInfo.processInfo.environment
        // 禁用标准输出缓冲，避免工具把几份低频样本攒在一起才交给浮层。
        environment["NSUnbufferedIO"] = "YES"
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        self.readerID = readerID
        self.process = process
        self.output = output
        self.onReading = onReading
        output.readabilityHandler = { [weak self] handle in
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                handle.readabilityHandler = nil
                DispatchQueue.main.async { self?.finish(readerID: readerID) }
                return
            }
            DispatchQueue.main.async {
                self?.receive(chunk, pid: pid, readerID: readerID)
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.finish(readerID: readerID) }
        }
        do {
            try process.run()
        } catch {
            finish(readerID: readerID)
        }
    }

    /// 关闭当前采集并清除目标，调用方负责同步清空界面上的旧数据。
    func stop() {
        targetPID = nil
        closeReader()
    }

    /// 检查数据属于当前采集后，发布最后一份有效的游戏呈现帧率。
    private func receive(_ chunk: Data, pid: pid_t, readerID: UUID) {
        guard self.readerID == readerID else { return }
        guard let fps = parser.consume(chunk, targetPID: pid) else { return }
        onReading?(fps)
    }

    /// 只处理当前采集的异常和退出，保留目标 PID 以免同一次会话自动重试。
    private func finish(readerID: UUID) {
        guard self.readerID == readerID else { return }
        let callback = onReading
        closeReader()
        callback?(nil)
    }

    /// 先让异步回调失效，再解除监听、停止子进程并关闭读取端。
    private func closeReader() {
        readerID = nil
        onReading = nil
        parser = MetalFPSParser()
        output?.readabilityHandler = nil
        process?.terminationHandler = nil
        if let process, process.isRunning { process.terminate() }
        try? output?.close()
        output = nil
        process = nil
    }
}

/// 从 Metal 采集工具的标准输出逐个读取 JSON 对象，兼容单行和带缩进的多行格式。
private struct MetalFPSParser {
    /// 限制未闭合对象的长度，防止异常的数据持续占用内存。
    private static let maximumObjectBytes = 1024 * 1024

    /// 存放当前对象从左花括号开始、尚未解码的原始字节。
    private var object = Data()
    /// 记录字符串之外的花括号嵌套深度，回到零时得到完整的对象。
    private var objectDepth = 0
    /// JSON 字符串里的花括号不参与嵌套匹配。
    private var isInsideString = false
    /// 在分段读取时保留反斜杠状态，避免把转义引号误认成字符串结尾。
    private var isEscaped = false
    /// 系统工具每个顶层对象从单独一行的行首开始，可据此跳过损坏的上一条记录。
    private var isAtLineStart = true

    /// 处理新字节并给出最后一份有效帧率，保留跨多个管道回调的未完成对象。
    mutating func consume(_ chunk: Data, targetPID: pid_t) -> Double? {
        var latestFPS: Double?
        for byte in chunk {
            let startsLine = isAtLineStart
            isAtLineStart = byte == 0x0A || byte == 0x0D
            if byte == 0x7B, objectDepth == 0 || startsLine {
                resetObject()
                objectDepth = 1
                object.append(byte)
                continue
            }
            guard objectDepth > 0 else { continue }
            guard object.count < Self.maximumObjectBytes else {
                resetObject()
                continue
            }
            object.append(byte)

            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5C {
                    isEscaped = true
                } else if byte == 0x22 {
                    isInsideString = false
                }
                continue
            }

            switch byte {
            case 0x22:
                isInsideString = true
            case 0x7B:
                objectDepth += 1
            case 0x7D:
                objectDepth -= 1
                guard objectDepth == 0 else { continue }
                if let fps = Self.presentedFPS(in: object, targetPID: targetPID) {
                    latestFPS = fps
                }
                resetObject()
            default:
                break
            }
        }
        return latestFPS
    }

    /// 丢弃当前对象的内容及匹配状态，保留独立的换行位置供下一条记录使用。
    private mutating func resetObject() {
        object.removeAll(keepingCapacity: true)
        objectDepth = 0
        isInsideString = false
        isEscaped = false
    }

    /// 验证进程标识，只读取有呈现帧的图层。优先采用面积最大的图层，同面积取呈现帧较多的图层。
    private static func presentedFPS(in object: Data, targetPID: pid_t) -> Double? {
        guard let record = (try? JSONSerialization.jsonObject(with: object)) as? [String: Any],
              record["PID"] as? Int == Int(targetPID),
              let layers = record["Layers"] as? [[String: Any]] else { return nil }

        var selected: (area: Double, frames: Int, fps: Double)?
        for layer in layers {
            guard let performance = layer["Performance Stats"] as? [String: Any],
                  let presented = performance["Presented Frame Stats"] as? [String: Any],
                  let frames = presented["Frame Count"] as? Int, frames > 0,
                  let fps = presented["FPS"] as? Double, fps.isFinite, fps > 0 else { continue }

            let configuration = layer["Configuration"] as? [String: Any]
            let width = max(configuration?["Width (pixels)"] as? Double ?? 0, 0)
            let height = max(configuration?["Height (pixels)"] as? Double ?? 0, 0)
            let area = width * height
            if let selected, selected.area > area || (selected.area == area && selected.frames >= frames) {
                continue
            }
            selected = (area, frames, fps)
        }
        return selected?.fps
    }
}
