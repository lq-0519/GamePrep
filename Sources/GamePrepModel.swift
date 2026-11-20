import AppKit
import Combine
import UniformTypeIdentifiers

/// 设置页使用的应用信息。应用标识用于匹配白名单，路径用于重新加载图标。
struct AppEntry: Identifiable {
    /// macOS 应用包标识，也是白名单和运行列表的匹配键。
    let id: String
    /// 设置窗口中显示的应用名称。
    let name: String
    /// 设置窗口中显示的应用图标，找不到原应用时使用系统应用图标。
    let icon: NSImage
    /// 添加时记录的应用包路径，用于无法按应用标识找到安装位置的情况。
    fileprivate let path: String?
}

/// 保存一次点击的实际结果，应用退出状态以本次检查结束时为准。
struct RunResult: Codable {
    /// 三项动作完成并检查退出状态的时间。
    let finishedAt: Date
    /// 所有目标实例均已退出的应用名称。
    let closed: [String]
    /// 检查时至少还有一个实例未退出的应用名称。
    let remaining: [String]
    /// 系统输入法切换和回读的结果。
    let input: StepResult
    /// 系统输出音量设置和回读的结果。
    let volume: StepResult
}

/// 协调白名单、当前运行应用和游戏模式。所有工作区访问都在主线程进行。
@MainActor
final class GamePrepModel: ObservableObject {
    /// 保存在本机的白名单记录。图标按需从应用包加载。
    private struct SavedApp: Codable {
        /// 即使应用移到其他目录也可用于识别应用。
        let id: String
        /// 应用暂时不可访问时仍可展示的名称。
        let name: String
        /// 供系统无法按标识定位应用时尝试的原始路径。
        let path: String?
    }

    /// 设置页中可供选择的普通桌面应用，包含隐藏和最小化的应用。
    @Published private(set) var runningApps: [AppEntry] = []
    /// 已保存的白名单，包含本次尚未启动的应用。
    @Published private(set) var whitelist: [AppEntry] = []
    /// 最近一次完整执行的结果，重新打开工具后仍可查看。
    @Published private(set) var result: RunResult?
    /// 执行期间冻结白名单设置并忽略重复触发。
    @Published private(set) var isRunning = false
    /// 首次核对白名单后才允许执行，避免安装后第一次点击误退应用。
    @Published private(set) var hasConfigured: Bool

    /// 存储用户配置及上次结果的本机应用偏好设置。
    private let defaults = UserDefaults.standard
    /// 提供运行应用列表、应用定位及图标的 macOS 工作区。
    private let workspace = NSWorkspace.shared
    /// 白名单记录数组对应的偏好设置键。
    private let whitelistKey = "gamePrepWhitelist"
    /// 是否已查看首次设置对应的偏好设置键。
    private let setupKey = "gamePrepSetupComplete"
    /// 上次执行结果对应的偏好设置键。
    private let resultKey = "gamePrepLastResult"

    /// 读取本机白名单及上次结果，等设置页打开后再刷新运行列表。
    init() {
        hasConfigured = defaults.bool(forKey: setupKey)
        if let data = defaults.data(forKey: whitelistKey),
           let saved = try? JSONDecoder().decode([SavedApp].self, from: data) {
            whitelist = Self.sorted(saved.map(makeEntry))
        }
        if let data = defaults.data(forKey: resultKey) {
            result = try? JSONDecoder().decode(RunResult.self, from: data)
        }
    }

    /// 从系统获得最新应用列表。相同应用标识在设置中只显示一行。
    func refreshRunningApps() {
        var seen = Set<String>()
        runningApps = Self.sorted(eligibleApplications().compactMap { app in
            guard let id = app.bundleIdentifier, seen.insert(id).inserted else { return nil }
            return AppEntry(
                id: id,
                name: app.localizedName ?? id,
                icon: app.icon ?? workspace.icon(for: .applicationBundle),
                path: app.bundleURL?.path
            )
        })
    }

    /// 修改指定应用的白名单状态，并立即写入本机设置。
    func setAllowed(_ app: AppEntry, allowed: Bool) {
        guard !isRunning else { return }
        whitelist.removeAll { $0.id == app.id }
        if allowed { whitelist.append(app) }
        saveWhitelist()
    }

    /// 从磁盘选取尚未运行的应用，允许一次添加多个应用包。
    func chooseWhitelistApps() {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.title = "添加到游戏模式白名单"
        panel.prompt = "添加"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, !isRunning else { return }

        var entries = whitelist
        var added = Set(entries.map(\.id))
        var unreadable = [String]()
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty else {
                unreadable.append(url.deletingPathExtension().lastPathComponent)
                continue
            }
            guard added.insert(id).inserted else { continue }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            entries.append(AppEntry(id: id, name: name, icon: workspace.icon(forFile: url.path), path: url.path))
        }
        whitelist = entries
        saveWhitelist()

        if !unreadable.isEmpty {
            let alert = NSAlert()
            alert.messageText = "部分应用无法添加"
            alert.informativeText = "无法读取应用标识：\(unreadable.joined(separator: "、"))"
            alert.runModal()
        }
    }

    /// 确认首次设置，空白名单也是有效选择。
    func finishSetup() {
        hasConfigured = true
        defaults.set(true, forKey: setupKey)
    }

    /// 向点击时的目标发出正常退出请求，并独立执行输入法和音量操作。
    func run() async {
        guard hasConfigured, !isRunning else { return }
        isRunning = true
        defer {
            isRunning = false
            refreshRunningApps()
        }

        let allowed = Set(whitelist.map(\.id))
        let targets = eligibleApplications().compactMap { app -> (id: String, name: String, app: NSRunningApplication)? in
            guard let id = app.bundleIdentifier, !allowed.contains(id) else { return nil }
            return (id, app.localizedName ?? id, app)
        }
        for target in targets where !target.app.isTerminated {
            // 退出请求发出后，应用可以继续提示保存或取消退出。
            _ = target.app.terminate()
        }

        let input = SystemControls.selectABC()
        async let volume = SystemControls.setVolumeToFiftyPercent()

        // 等待有限时间，让正常退出的应用有机会从工作区消失，同时保持界面可用。
        let deadline = ContinuousClock.now + .seconds(4)
        while ContinuousClock.now < deadline && targets.contains(where: { !$0.app.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let volumeResult = await volume
        let remainingIDs = Set(targets.filter { !$0.app.isTerminated }.map(\.id))
        var recordedIDs = Set<String>()
        var closed = [String]()
        var remaining = [String]()
        for target in targets where recordedIDs.insert(target.id).inserted {
            if remainingIDs.contains(target.id) {
                remaining.append(target.name)
            } else {
                closed.append(target.name)
            }
        }
        let completed = RunResult(
            finishedAt: Date(),
            closed: closed.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            remaining: remaining.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            input: input,
            volume: volumeResult
        )
        result = completed
        if let data = try? JSONEncoder().encode(completed) { defaults.set(data, forKey: resultKey) }
    }

    /// 仅选普通桌面应用，并保护工具本身、Finder 及系统桌面组件。
    private func eligibleApplications() -> [NSRunningApplication] {
        workspace.runningApplications.filter { app in
            guard app.activationPolicy == .regular,
                  !app.isTerminated,
                  app.processIdentifier != NSRunningApplication.current.processIdentifier,
                  let id = app.bundleIdentifier, !id.isEmpty,
                  id != "com.apple.finder",
                  let url = app.bundleURL else { return false }
            return !url.path.hasPrefix("/System/Library/")
        }
    }

    /// 优先读取当前安装位置，再用原路径找可移动磁盘等位置上的应用图标。
    private func makeEntry(_ saved: SavedApp) -> AppEntry {
        let installed = workspace.urlForApplication(withBundleIdentifier: saved.id)?.path
        let path = installed ?? saved.path
        let icon = path.map { workspace.icon(forFile: $0) } ?? workspace.icon(for: .applicationBundle)
        return AppEntry(id: saved.id, name: saved.name, icon: icon, path: path)
    }

    /// 按本地显示名称排序，名称相同时使用应用标识排序。
    private static func sorted(_ apps: [AppEntry]) -> [AppEntry] {
        apps.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// 写入白名单的应用标识和显示信息，图标由系统提供。
    private func saveWhitelist() {
        whitelist = Self.sorted(whitelist)
        let saved = whitelist.map { SavedApp(id: $0.id, name: $0.name, path: $0.path) }
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: whitelistKey) }
    }
}
