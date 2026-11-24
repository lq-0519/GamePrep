import Darwin
import Foundation
import IOKit

/// 在独立执行上下文中读取整机指标，并把首次采样与后续采样配对计算 CPU 使用率。
actor GameMonitorSystemMetrics {
    /// 上一次成功读取的 CPU 各状态累计时钟计数。每个采样上下文独立建立基线。
    private var previousCPUTicks: host_cpu_load_info_data_t?
    /// 当前监控期间复用的 GPU 服务句柄，零表示本轮检测不到唯一设备。
    private var gpuService: io_service_t?
    /// 物理内存总量通常在系统运行期间不变，在首次勾选内存采样时读取。
    private lazy var physicalMemory = ProcessInfo.processInfo.physicalMemory

    /// 采样上下文释放时一并释放已取得的 IOKit 服务句柄。
    deinit {
        if let gpuService, gpuService != 0 { IOObjectRelease(gpuService) }
    }

    /// 按启用项读取当前值。未建立基线、接口失败或没有有效数据时省略该行，FPS 由游戏提供。
    func sample(_ enabled: Set<GameMonitorMetric>) -> [GameMonitorMetric: String] {
        var lines: [GameMonitorMetric: String] = [:]

        if enabled.contains(.cpu) || enabled.contains(.memory) {
            let host = mach_host_self()
            defer { mach_port_deallocate(mach_task_self_, host) }
            if enabled.contains(.cpu) { lines[.cpu] = sampleCPU(on: host) }
            if enabled.contains(.memory) { lines[.memory] = sampleMemory(on: host) }
        }

        if enabled.contains(.gpu) { lines[.gpu] = sampleGPU() }
        return lines
    }

    /// 计算两次采样间所有核心非空闲 tick 的比例。各项先分别相减，以兼容单个计数器回绕。
    private func sampleCPU(on host: host_t) -> String? {
        var ticks = host_cpu_load_info_data_t()
        let expectedCount = MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        var count = mach_msg_type_number_t(expectedCount)
        let result = withUnsafeMutablePointer(to: &ticks) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: expectedCount) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, count == mach_msg_type_number_t(expectedCount) else {
            previousCPUTicks = nil
            return nil
        }

        let previous = previousCPUTicks
        previousCPUTicks = ticks
        guard let previous else { return nil }

        // Mach 将四个状态按用户、内核、空闲和低优先级用户的顺序存放。
        let user = UInt64(ticks.cpu_ticks.0 &- previous.cpu_ticks.0)
        let system = UInt64(ticks.cpu_ticks.1 &- previous.cpu_ticks.1)
        let idle = UInt64(ticks.cpu_ticks.2 &- previous.cpu_ticks.2)
        let nice = UInt64(ticks.cpu_ticks.3 &- previous.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return nil }
        return String(format: "CPU %.0f%%", 100 * Double(busy) / Double(total))
    }

    /// 用匿名页、常驻内核页和压缩器实际占用页估算已用内存，扣除可清除页。
    /// 页数来自内核，换算时使用内核页大小，使读数不受进程自身页大小影响。
    private func sampleMemory(on host: host_t) -> String? {
        var statistics = vm_statistics64_data_t()
        let capacity = MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let totalBytes = physicalMemory
        guard result == KERN_SUCCESS, totalBytes > 0 else { return nil }

        let allocatedPages = UInt64(statistics.internal_page_count) + UInt64(statistics.wire_count)
            + UInt64(statistics.compressor_page_count)
        let usedPages = allocatedPages - min(allocatedPages, UInt64(statistics.purgeable_count))
        let usedBytes = min(usedPages * UInt64(vm_kernel_page_size), totalBytes)
        let bytesPerGB = 1_073_741_824.0
        return String(format: "内存 %.1f / %.0f GB", Double(usedBytes) / bytesPerGB, Double(totalBytes) / bytesPerGB)
    }

    /// 从 GPU 驱动发布的设备活动率读取近似百分比。键名和统计窗口可能随驱动变化。
    private func sampleGPU() -> String? {
        if gpuService == nil { gpuService = findSingleGPUService() }
        guard let gpuService, gpuService != 0,
              let stats = IORegistryEntryCreateCFProperty(gpuService, "PerformanceStatistics" as CFString, nil, 0)?
                  .takeRetainedValue() as? [String: Any],
              let utilization = stats["Device Utilization %"] as? NSNumber,
              (0...100).contains(utilization.doubleValue) else { return nil }

        return String(format: "GPU ≈ %.0f%%", utilization.doubleValue)
    }

    /// 仅在可唯一识别 GPU 时保留服务句柄，避免把任意一块 GPU 的活动率当成整机读数。
    private func findSingleGPUService() -> io_service_t {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
        guard result == KERN_SUCCESS, iterator != 0 else { return 0 }
        defer { IOObjectRelease(iterator) }

        let firstService = IOIteratorNext(iterator)
        guard firstService != 0 else { return 0 }
        let secondService = IOIteratorNext(iterator)
        guard secondService == 0 else {
            IOObjectRelease(secondService)
            IOObjectRelease(firstService)
            return 0
        }
        return firstService
    }
}
