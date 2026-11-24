import AppKit
import SwiftUI

/// 展示游戏模式的退出预览、白名单和最近一次执行结果。
struct SettingsView: View {
    /// 由菜单栏控制器持有，窗口重新打开后继续显示已保存的设置和执行状态。
    @ObservedObject var model: GamePrepModel

    /// 读取系统的登录项状态，由开关请求注册或取消注册。
    @ObservedObject var loginItem: LoginItemSettings
    /// 持久化监控样式，并在会话中应用指标选择。
    @ObservedObject var monitor: GameMonitor

    /// 以应用标识判断保留状态，使预览和退出流程使用同一种匹配方式。
    private var allowedIDs: Set<String> {
        Set(model.whitelist.map(\.id))
    }

    /// 根据当前运行列表计算退出预览，勾选白名单后立即更新。
    private var quitCount: Int {
        model.runningApps.filter { !allowedIDs.contains($0.id) }.count
    }

    /// 让设置和执行结果共用一个可滚动的窗口，并固定首次启用按钮的位置。
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    launchAtLogin
                    GameMonitorSettingsView(monitor: monitor)
                    if model.isRunning || model.result != nil {
                        executionResult
                    }
                    runningApps
                    whitelist
                }
                .padding(24)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 说明菜单栏的执行入口，使用系统符号呼应菜单栏图标。
    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 24))
                .foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("游戏模式")
                    .font(.title2.bold())
                Text("右键点击菜单栏的手柄图标运行。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .accessibilityElement(children: .combine)
    }

    /// 在设置顶部显示登录时启动的开关，并在系统需要用户处理时提供入口。
    private var launchAtLogin: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("登录时启动", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                .toggleStyle(.switch)

                if loginItem.requiresApproval {
                    HStack {
                        Text("请在系统设置中允许登录时启动。")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("打开系统设置…") { loginItem.openSystemSettings() }
                            .controlSize(.small)
                    }
                }

                if let errorMessage = loginItem.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    /// 展示符合退出条件的运行中应用，勾选即可将对应应用加入白名单。
    private var runningApps: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("勾选要保留的应用。当前有 \(quitCount) 个应用会收到退出请求。游戏模式也会关闭访达窗口。")
                    .foregroundStyle(.secondary)

                if model.runningApps.isEmpty {
                    Text("当前没有可清理的应用。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.runningApps) { app in
                        Toggle(isOn: Binding(
                            get: { allowedIDs.contains(app.id) },
                            set: { model.setAllowed(app, allowed: $0) }
                        )) {
                            appLabel(app)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
            .disabled(model.isRunning)
        } label: {
            HStack {
                Text("正在运行的应用")
                Spacer()
                Button("刷新") { model.refreshRunningApps() }
                    .controlSize(.small)
                    .disabled(model.isRunning)
            }
        }
    }

    /// 显示所有已保存的应用，包括当前未运行的游戏和启动器。
    private var whitelist: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if model.whitelist.isEmpty {
                    Text("还没有添加应用。可以在上方勾选，或从本机选择应用。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.whitelist) { app in
                        HStack {
                            appLabel(app)
                            Spacer()
                            Button("移除") { model.setAllowed(app, allowed: false) }
                                .controlSize(.small)
                                .accessibilityLabel("从白名单移除\(app.name)")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
            .disabled(model.isRunning)
        } label: {
            HStack {
                Text("白名单")
                Spacer()
                Button("添加应用…") { model.chooseWhitelistApps() }
                    .controlSize(.small)
                    .disabled(model.isRunning)
            }
        }
    }

    /// 在同一位置显示进度与结果，并分别呈现访达、输入法和音量的反馈。
    private var executionResult: some View {
        GroupBox("上次执行结果") {
            VStack(alignment: .leading, spacing: 9) {
                if model.isRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在执行游戏模式…")
                    }
                } else if let result = model.result {
                    Text(result.finishedAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    stepRow(result.input)
                    stepRow(result.volume)
                    if let finder = result.finder { stepRow(finder) }

                    if result.closed.isEmpty && result.remaining.isEmpty {
                        Text("本次没有需要退出的应用。")
                            .foregroundStyle(.secondary)
                    } else {
                        if !result.closed.isEmpty {
                            appResult(title: "已退出", names: result.closed)
                        }
                        if !result.remaining.isEmpty {
                            appResult(title: "仍在运行", names: result.remaining)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
            .textSelection(.enabled)
        }
    }

    /// 为菜单栏工具提供退出入口，并在首次查看清理范围后启用右键动作。
    private var footer: some View {
        HStack(spacing: 16) {
            Button("退出工具") { NSApp.terminate(nil) }
                .disabled(model.isRunning)
            Spacer()
            if !model.hasConfigured {
                Text("请先检查哪些应用需要保留。")
                    .foregroundStyle(.secondary)
                Button("启用右键执行") { model.finishSetup() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    /// 用系统应用图标和名称标识应用，长名称截断后仍可悬停查看。
    private func appLabel(_ app: AppEntry) -> some View {
        Label {
            Text(app.name)
                .lineLimit(1)
        } icon: {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 20, height: 20)
        }
        .help(app.name)
    }

    /// 同时用文字和图标呈现系统操作结果，图标颜色只作为补充。
    private func stepRow(_ step: StepResult) -> some View {
        Label(step.message, systemImage: step.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
            .foregroundStyle(step.succeeded ? Color.primary : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 以可以换行的应用名列表展示实际退出或仍在运行的应用。
    private func appResult(title: String, names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.callout.weight(.semibold))
            Text(names.joined(separator: "、"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
