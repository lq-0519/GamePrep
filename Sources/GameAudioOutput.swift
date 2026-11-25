import CoreAudio
import Foundation

/// 根据外接显示器名称匹配音频设备，只切换应用使用的默认媒体输出。
enum GameAudioOutput {
    /// Core Audio 用系统对象保存设备清单和默认输出路由。
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    /// 将显示器对应的数字音频设备设为默认媒体输出，并等待系统回读确认。
    /// 只有名称相同且提供输出的设备才会参与匹配，避免选到另一个显示器或录音设备。
    static func selectExternalDisplay(named name: String) async -> StepResult {
        let wantedName = normalizedName(name)
        guard !wantedName.isEmpty else {
            return .skipped("无法识别外接显示器名称，跳过声音输出切换。")
        }
        guard let devices = deviceIDs() else {
            return StepResult(succeeded: false, message: "无法读取系统音频设备，未切换声音输出。")
        }
        let matches = devices.filter { device in
            guard let transport = readUInt32(kAudioDevicePropertyTransportType, on: device),
                  transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort,
                  let audioName = deviceName(device), normalizedName(audioName) == wantedName else { return false }
            var streams = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &size) == noErr && size > 0
        }
        guard matches.count <= 1 else {
            return .skipped("有多个与 \(name) 同名的显示器音频设备，跳过声音输出切换。")
        }
        guard var device = matches.first else {
            return .skipped("未找到与 \(name) 对应的显示器音频设备，跳过声音输出切换。")
        }
        let selector = kAudioHardwarePropertyDefaultOutputDevice
        let success = StepResult(succeeded: true, message: "声音已输出到 \(name)。")
        if readUInt32(selector, on: system) == device { return success }

        var property = address(selector)
        let status = AudioObjectSetPropertyData(system, &property, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &device)
        guard status == noErr else {
            return StepResult(succeeded: false, message: "切换声音输出到 \(name) 失败（系统错误 \(status)）。")
        }
        // 路由更新可能延后，短暂等待回读结果，让界面线程保持响应。
        for _ in 0..<10 {
            if readUInt32(selector, on: system) == device { return success }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }
        if readUInt32(selector, on: system) == device { return success }
        return StepResult(succeeded: false, message: "系统未确认声音已切换到 \(name)。")
    }

    /// 检查当前媒体输出的主音量和各声道是否可调。设备变更或读取失败时返回 nil，由原音量步骤处理。
    static func currentDeviceHasAdjustableVolume() -> Bool? {
        let selector = kAudioHardwarePropertyDefaultOutputDevice
        guard let device = readUInt32(selector, on: system), device != kAudioObjectUnknown else { return nil }
        let main = volumeIsWritable(on: device, element: kAudioObjectPropertyElementMain)
        if main == true { return true }
        guard let channels = outputChannelCount(of: device), channels > 0 else { return nil }

        var allResultsKnown = main != nil
        for element in 1...channels {
            let writable = volumeIsWritable(on: device, element: element)
            if writable == true { return true }
            allResultsKnown = allResultsKnown && writable != nil
        }
        return allResultsKnown && readUInt32(selector, on: system) == device ? false : nil
    }

    /// 去掉名称首尾空白并合并连续空白，忽略大小写和全半角差异，保留其余字符用于精确匹配。
    private static func normalizedName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// 构造指定范围和元素的 Core Audio 属性地址，默认用于系统及设备的全局属性。
    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// 读取 Core Audio 的 32 位全局属性，例如当前输出设备 ID 或设备连接方式。
    private static func readUInt32(_ selector: AudioObjectPropertySelector, on object: AudioObjectID) -> UInt32? {
        var property = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// 读取系统当前设备数组，使用系统实际写入长度处理枚举过程中设备被拔出的情况。
    private static func deviceIDs() -> [AudioObjectID]? {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else { return nil }
        let stride = MemoryLayout<AudioObjectID>.stride
        guard size > 0 else { return [] }
        guard Int(size).isMultiple(of: stride) else { return nil }
        var devices = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / stride)
        let status = devices.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return kAudioHardwareBadPropertySizeError }
            return AudioObjectGetPropertyData(system, &property, 0, nil, &size, base)
        }
        return status == noErr ? Array(devices.prefix(Int(size) / stride)) : nil
    }

    /// 读取系统显示给用户的设备名称。Core Audio 将返回字符串的引用所有权交给调用方。
    private static func deviceName(_ device: AudioObjectID) -> String? {
        var property = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    /// 查询实际输出声道数，覆盖只提供独立声道音量控制的设备。
    private static func outputChannelCount(of device: AudioObjectID) -> UInt32? {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr,
              Int(size) >= MemoryLayout<AudioBufferList>.size else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, buffer) == noErr,
              Int(size) >= MemoryLayout<AudioBufferList>.size else { return nil }
        return UnsafeMutableAudioBufferListPointer(buffer.bindMemory(to: AudioBufferList.self, capacity: 1))
            .reduce(0) { $0 + $1.mNumberChannels }
    }

    /// 区分没有音量控制、控制可写和查询出错三种情况，避免将暂时的音频服务错误当作设备限制。
    private static func volumeIsWritable(on device: AudioObjectID, element: AudioObjectPropertyElement) -> Bool? {
        var property = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
        guard AudioObjectHasProperty(device, &property) else { return false }
        var writable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &property, &writable) == noErr ? writable.boolValue : nil
    }
}
