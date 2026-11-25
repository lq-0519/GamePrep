import AppKit
import ColorSync
import Combine
import CoreGraphics

/// 浮层可独立启停的指标。原始值用于保存设置，枚举顺序用于排列读数。
enum GameMonitorMetric: String, CaseIterable, Codable, Sendable, Identifiable {
    /// 目标游戏进程的 Metal 呈现帧率。
    case fps
    /// 整机 CPU 非空闲时间占比。
    case cpu
    /// 整机已用内存和物理内存总量。
    case memory
    /// 图形驱动提供的设备活动率。
    case gpu

    /// 设置界面用这个标识匹配保存的指标选项。
    var id: String { rawValue }

    /// 设置页显示的数据来源和含义。
    var title: String {
        switch self {
        case .fps: "游戏 FPS"
        case .cpu: "CPU 占用"
        case .memory: "内存占用"
        case .gpu: "GPU 活动"
        }
    }
}

/// 角标相对于目标显示器边缘的摆放位置。
enum GameMonitorCorner: String, CaseIterable, Codable, Sendable, Identifiable {
    /// 对齐可显示区域的左上角。
    case topLeft
    /// 对齐可显示区域的右上角。
    case topRight
    /// 对齐可显示区域的左下角。
    case bottomLeft
    /// 对齐可显示区域的右下角。
    case bottomRight

    /// 设置页用原始值匹配位置选项。
    var id: String { rawValue }

    /// 位置选择器中的中文标签。
    var title: String {
        switch self {
        case .topLeft: "左上角"
        case .topRight: "右上角"
        case .bottomLeft: "左下角"
        case .bottomRight: "右下角"
        }
    }
}

/// 设置页中的一个逻辑屏幕。同组镜像屏共用一个显示选项。
struct GameMonitorDisplay: Identifiable, Equatable {
    /// 优先用显示器 UUID，便于拔插后恢复原选择。
    let id: String
    /// macOS 提供的显示器名称，镜像组带有说明。
    let name: String
}

/// 根据前台游戏的帧率决定浮层是否显示，并在显示时采集勾选的系统指标。
@MainActor
final class GameMonitor: ObservableObject {
    /// 透明度最高为九成，保留角标的可见性。完全隐藏由总开关控制。
    static let transparencyRange: ClosedRange<Double> = 0...0.9

    /// 持久化的总开关。开启后等待游戏帧率，收到数据才显示浮层。
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            saveSettings()
            reconcileMonitoring()
        }
    }

    /// 用户选中的指标。暂时取消所有指标时保留总开关，暂停采集和浮层。
    @Published var metrics: Set<GameMonitorMetric> {
        didSet {
            guard metrics != oldValue else { return }
            saveSettings()
            updateSelection(previous: oldValue)
        }
    }

    /// 所有读数使用同一个角标位置，正在显示时立即重新定位。
    @Published var corner: GameMonitorCorner {
        didSet {
            saveSettings()
            render()
        }
    }

    /// 整个浮层的统一文字大小，以 AppKit 点为单位。
    @Published var fontSize: Double {
        didSet {
            saveSettings()
            render()
        }
    }

    /// 整个面板的透明比例，零表示保留原有外观。拖动时立即应用并保存。
    @Published var transparency: Double {
        didSet {
            guard transparency != oldValue else { return }
            saveSettings()
            render()
        }
    }

    /// 指定逻辑屏幕的标识。为空或该屏暂时离线时跟随游戏。
    @Published var preferredDisplayID: String? {
        didSet {
            saveSettings()
            if fpsReading != nil {
                updateDisplayPlacement()
                render()
            }
        }
    }

    /// 当前可定位的逻辑屏幕列表，供设置页面选择。
    @Published private(set) var availableDisplays: [GameMonitorDisplay] = []

    /// 运行环境是否提供系统自带的 Metal 帧率采集工具。
    var supportsFPS: Bool { GameFPSMonitor.isSupported }

    /// 将一组监控设置一起持久化，空指标集合也保留用户的选择。
    private struct Options: Codable {
        /// 旧版本的设置没有总开关，解码为空时默认关闭并保留其他选项。
        var isEnabled: Bool?
        /// 默认只启用游戏帧率，系统指标由用户按需开启。
        var metrics: Set<GameMonitorMetric> = [.fps]
        /// 新安装时把角标放在右上方。
        var corner: GameMonitorCorner = .topRight
        /// 新安装时以紧凑的字号显示读数。
        var fontSize: Double = 12
        /// 旧版偏好缺少此字段时保留原有面板外观。
        var transparency: Double?
        /// 保留被指定的逻辑屏幕，空值表示自动定位。
        var preferredDisplayID: String?
    }

    /// 同时保存屏幕的 AppKit 对象和 Quartz 坐标，用于判断前台窗口位于哪块屏幕。
    private struct ScreenTarget {
        /// 设置页选择的逻辑屏幕信息。
        let display: GameMonitorDisplay
        /// 逻辑屏幕的 Core Graphics 标识，用于识别主屏与镜像组。
        let displayID: CGDirectDisplayID
        /// AppKit 用于创建和定位浮层的屏幕对象。
        let screen: NSScreen
        /// 此屏幕在 Quartz 全局坐标中的范围，原点在左上方。
        let quartzBounds: CGRect
    }

    /// 前台应用的主要可见窗口，保留所在位置与实际的窗口服务器层级。
    private struct ForegroundWindow {
        /// Quartz 屏幕坐标，用于判断窗口是否覆盖浮层所在显示器。
        let bounds: CGRect
        /// 窗口服务器的层级，某些游戏进入全屏后会高于普通浮窗。
        let layer: Int
    }

    /// 浮层所在的显示器，以及同屏全屏窗口可能需要避开的层级。
    private struct DisplayPlacement {
        /// AppKit 用于将浮层放在屏幕角落的显示器对象。
        let screen: NSScreen
        /// 满屏窗口的层级。普通窗口、桌面或副屏上的浮层不设置此值。
        let coveringWindowLayer: Int?
    }

    /// 用于保存样式和指标选择的本机偏好键。
    private let settingsKey = "gamePrepMonitorOptions"
    /// 实际轻量浮层，切换前台应用时重复使用同一个窗口。
    private let hud = GameMonitorHUD()
    /// 针对当前游戏 PID 读取 Metal 呈现帧率的采集器。
    private let fpsMonitor = GameFPSMonitor()
    /// 当前启用指标的系统采样上下文，重新启用或改变指标时建立新的 CPU 基线。
    private var systemMetrics = GameMonitorSystemMetrics()
    /// 采样与窗口跟随共用的唯一周期任务，仅在可显示浮层时运行。
    private var updateTask: Task<Void, Never>?
    /// 主应用启动完成后才允许恢复用户保存的开关和启动资源。
    private var isStarted = false
    /// 当前可用于定位窗口和读取帧率的前台应用，允许为空。
    private var target: NSRunningApplication?
    /// 当前显示拓扑下按逻辑屏幕去重后的定位信息。
    private var screens: [ScreenTarget] = []
    /// 已确定的显示器和层级，供 FPS 回调及样式更新直接复用。
    private var displayPlacement: DisplayPlacement?
    /// 暂时取不到窗口边界时留在上一次定位的屏幕，避免跟着鼠标来回跳动。
    private var fallbackDisplayID: String?
    /// 最近一次系统采样返回的有效读数，按指标单独保存。
    private var systemReadings: [GameMonitorMetric: String] = [:]
    /// 最近一笔有效的 FPS 和收到它的时间，超时后隐藏整个浮层。
    private var fpsReading: (value: Double, receivedAt: ContinuousClock.Instant)?

    /// 总开关开启且仍有指标可展示时，允许读取用来判断浮层可见性的游戏帧率。
    private var canCollectFPS: Bool { isStarted && isEnabled && supportsFPS && !metrics.isEmpty && !screens.isEmpty }

    /// 浮层显示期间才采集勾选的系统指标，FPS 由单独的采集器提供。
    private var systemSelection: Set<GameMonitorMetric> { metrics.subtracting([.fps]) }

    /// 读取保存的样式和勾选项，启动时只获取显示拓扑，不采样。
    init() {
        let data = UserDefaults.standard.data(forKey: settingsKey)
        let options = data.flatMap { try? JSONDecoder().decode(Options.self, from: $0) } ?? Options()
        isEnabled = options.isEnabled ?? false
        metrics = data == nil && !GameFPSMonitor.isSupported ? [] : options.metrics
        corner = options.corner
        fontSize = min(24, max(10, options.fontSize))
        let range = Self.transparencyRange
        transparency = min(range.upperBound, max(range.lowerBound, options.transparency ?? range.lowerBound))
        preferredDisplayID = options.preferredDisplayID
        refreshDisplays()
    }

    /// 主应用启动后恢复用户上次保存的浮层开关。
    func start() {
        isStarted = true
        reconcileMonitoring()
    }

    /// 退出应用时回收采样资源，保留用户的开关状态供下次启动使用。
    func shutdown() {
        isStarted = false
        suspendMonitoring()
    }

    /// 按前台应用切换帧率来源。切回桌面时隐藏浮层，保留用户的勾选设置。
    func foregroundChanged() {
        guard canCollectFPS else { return }
        reconcileMonitoring()
    }

    /// 当前游戏退出时丢弃该进程的帧率，浮层继续由设置开关控制。
    func applicationTerminated(pid: pid_t) {
        guard target?.processIdentifier == pid else { return }
        target = nil
        reconcileMonitoring(refreshFPS: true)
    }

    /// 拔插、镜像、改分辨率或排列后刷新设置项，并用新坐标重新放置浮层。
    func refreshDisplays() {
        var groups: [CGDirectDisplayID: ScreenTarget] = [:]
        var displayOrder: [CGDirectDisplayID] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = number.uint32Value
            let source = CGDisplayMirrorsDisplay(displayID)
            let groupID = source == kCGNullDirectDisplay ? CGDisplayPrimaryDisplay(displayID) : source
            if groups[groupID] == nil { displayOrder.append(groupID) }
            guard groups[groupID] == nil || displayID == groupID else { continue }
            let uuid = CGDisplayCreateUUIDFromDisplayID(groupID)?.takeRetainedValue()
            let id = uuid.map { CFUUIDCreateString(nil, $0) as String } ?? String(groupID)
            let name = screen.localizedName + (CGDisplayIsInMirrorSet(displayID) != 0 ? "（镜像）" : "")
            groups[groupID] = ScreenTarget(
                display: GameMonitorDisplay(id: id, name: name),
                displayID: groupID,
                screen: screen,
                quartzBounds: CGDisplayBounds(displayID)
            )
        }
        screens = displayOrder.compactMap { groups[$0] }
        availableDisplays = screens.map(\.display)
        if isStarted { reconcileMonitoring() }
    }

    /// 将开关、勾选、字号、透明度、位置和屏幕选择一起保存在本机。
    private func saveSettings() {
        let options = Options(
            isEnabled: isEnabled, metrics: metrics, corner: corner, fontSize: fontSize,
            transparency: transparency, preferredDisplayID: preferredDisplayID
        )
        if let data = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    /// 丢弃已关指标的读数和采样上下文。只改变样式或系统指标时不会重启 FPS 采集。
    private func updateSelection(previous: Set<GameMonitorMetric>) {
        guard isEnabled else { return }
        if systemSelection != previous.subtracting([.fps]) {
            systemMetrics = GameMonitorSystemMetrics()
            systemReadings = systemReadings.filter { metrics.contains($0.key) }
        }
        reconcileMonitoring()
    }

    /// 排除桌面、本工具和常见启动界面，等待用户实际打开想观察的前台应用。
    private func canMonitor(_ app: NSRunningApplication) -> Bool {
        let name = app.localizedName?.lowercased() ?? ""
        let windowsApp = app.bundleIdentifier?.hasPrefix("com.codeweavers.CrossOverHelper.") == true
            || name.hasSuffix(".exe")
        guard app.activationPolicy == .regular || windowsApp,
              !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        switch app.bundleIdentifier {
        case "com.apple.finder", "com.apple.loginwindow", "com.codeweavers.CrossOver", "com.valvesoftware.steam":
            return false
        default:
            return !name.contains("launcher") && name != "steam" && name != "steam.exe"
        }
    }

    /// 根据开关、勾选项和前台应用统一安排显示、采样与窗口定位。
    private func reconcileMonitoring(refreshFPS: Bool = false) {
        guard canCollectFPS else {
            suspendMonitoring()
            return
        }

        let foreground = NSWorkspace.shared.frontmostApplication
        let next = foreground.flatMap { canMonitor($0) ? $0 : nil }
        let didChangeTarget = target?.processIdentifier != next?.processIdentifier
        target = next
        if didChangeTarget || refreshFPS { updateFPSMonitor() }
        if fpsReading != nil {
            updateDisplayPlacement()
            render()
        }
    }

    /// 隐藏浮层并回收所有后台资源，丢弃此前的读数和定位。
    private func suspendMonitoring() {
        target = nil
        fpsMonitor.stop()
        fallbackDisplayID = nil
        hideReadings()
    }

    /// 帧率不可用时清除旧读数并暂停系统指标和窗口定位，仅保留必要的帧率监听。
    private func hideReadings() {
        updateTask?.cancel()
        updateTask = nil
        fpsReading = nil
        displayPlacement = nil
        systemMetrics = GameMonitorSystemMetrics()
        systemReadings = [:]
        hud.hide()
    }

    /// 浮层可显示时，用一个低频任务采集系统指标并跟随前台窗口移动。
    private func startSampling() {
        updateTask = Task(priority: .utility) { @MainActor [weak self] in
            while !Task.isCancelled, self != nil {
                await self?.updateReadings()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    /// 为当前前台进程启动单一帧率监听。隐藏 FPS 行时仍用帧率判断浮层是否可见。
    private func updateFPSMonitor() {
        hideReadings()
        fpsMonitor.stop()
        guard canCollectFPS, let pid = target?.processIdentifier else { return }
        fpsMonitor.start(pid: pid) { [weak self] reading in
            guard let self, canCollectFPS, target?.processIdentifier == pid else { return }
            guard let reading else {
                hideReadings()
                return
            }
            fpsReading = (reading, .now)
            if updateTask == nil {
                updateDisplayPlacement()
                startSampling()
            }
            render()
        }
    }

    /// 仅把当前勾选的系统指标交给采样器，同时以低频刷新位置和过期的帧率读数。
    private func updateReadings() async {
        guard canCollectFPS, !Task.isCancelled else { return }
        if target?.isTerminated == true {
            reconcileMonitoring()
            return
        }
        guard let fpsReading, fpsReading.receivedAt.duration(to: .now) <= .seconds(8) else {
            hideReadings()
            return
        }
        updateDisplayPlacement()
        let selection = systemSelection
        if !selection.isEmpty, displayPlacement != nil {
            let sampler = systemMetrics
            let values = await sampler.sample(selection)
            guard !Task.isCancelled, sampler === systemMetrics else { return }
            systemReadings = values
        }
        render()
    }

    /// 选择固定屏幕或前台窗口所在的屏幕，并只在浮层与全屏窗口同屏时传递其层级。
    private func updateDisplayPlacement() {
        let window = target.flatMap { foregroundWindow(pid: $0.processIdentifier) }
        let fixed = preferredDisplayID.flatMap { id in screens.first { $0.display.id == id } }
        let selected = fixed ?? preferredScreen(for: window)
        if fixed == nil { fallbackDisplayID = selected?.display.id }
        displayPlacement = selected.map { selected in
            let coveringLayer = window.flatMap { window in
                let screenArea = area(selected.quartzBounds)
                let covered = area(window.bounds.intersection(selected.quartzBounds))
                // 给游戏全屏窗口的边缘保留少量坐标误差，普通窗口则保持原有层级。
                return screenArea > 0 && covered >= screenArea * 0.98 ? window.layer : nil
            }
            return DisplayPlacement(screen: selected.screen, coveringWindowLayer: coveringLayer)
        }
    }

    /// 自动定位时选窗口与屏幕交叠最多的一块。没有窗口时复用上次选择，首次参考指针或主屏。
    private func preferredScreen(for window: ForegroundWindow?) -> ScreenTarget? {
        if let window, let selected = screens.max(by: {
            area(window.bounds.intersection($0.quartzBounds)) < area(window.bounds.intersection($1.quartzBounds))
        }), area(window.bounds.intersection(selected.quartzBounds)) > 0 {
            return selected
        }
        let mouseLocation = NSEvent.mouseLocation
        return screens.first { $0.display.id == fallbackDisplayID }
            ?? screens.first { $0.screen.frame.contains(mouseLocation) }
            ?? screens.first { $0.displayID == CGMainDisplayID() }
            ?? screens.first
    }

    /// 读取指定进程面积最大的可见窗口，避免图层较低的辅助窗口掩盖真正的全屏窗口。
    private func foregroundWindow(pid: pid_t) -> ForegroundWindow? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        var biggest: ForegroundWindow?
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue, layer >= 0,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width >= 120, rect.height >= 80
            else { continue }
            if area(rect) > area(biggest?.bounds ?? .null) {
                biggest = ForegroundWindow(bounds: rect, layer: layer)
            }
        }
        return biggest
    }

    /// 给窗口和屏幕交集排序，空交集按零面积处理。
    private func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }

    /// 按设置顺序显示所选指标。浮层自身会复用内容相同的文本和位置。
    private func render() {
        guard canCollectFPS, let fpsReading, let displayPlacement else {
            hud.hide()
            return
        }
        let lines = GameMonitorMetric.allCases.filter(metrics.contains).map { metric in
            switch metric {
            case .fps: String(format: "%.1f FPS", fpsReading.value)
            case .cpu: systemReadings[metric] ?? "CPU —"
            case .memory: systemReadings[metric] ?? "内存 —"
            case .gpu: systemReadings[metric] ?? "GPU —"
            }
        }
        hud.show(
            lines: lines, corner: corner, fontSize: fontSize, transparency: transparency,
            screen: displayPlacement.screen, coveringWindowLayer: displayPlacement.coveringWindowLayer
        )
    }
}
