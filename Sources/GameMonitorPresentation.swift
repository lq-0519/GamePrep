import AppKit
import CoreGraphics
import SwiftUI

/// 在游戏显示器上复用一个轻量浮层，显示时保持游戏的键盘和鼠标焦点。
@MainActor
final class GameMonitorHUD {
    /// 下方角标使用仅高于程序坞一级的层级，程序坞弹出时角标仍可见。
    private static let lowerCornerLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)

    /// 由 AppKit 绘制背景和文字，避免指标更新时重建窗口或 SwiftUI 视图。
    private let content = GameMonitorHUDContent()

    /// 仅在有可显示的内容时创建面板，之后在显示器之间移动同一个窗口。
    private var panel: NSPanel?

    /// 创建能加入游戏全屏空间的非激活面板，并让所有鼠标事件透传给后面的窗口。
    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllApplications, .canJoinAllSpaces, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.contentView = content
        content.setAccessibilityElement(true)
        return panel
    }

    /// 以整块屏幕的边缘摆放角标，上方避开菜单栏和开孔，透明度同时应用于文字和底板。
    func show(lines: [String], corner: GameMonitorCorner, fontSize: Double, transparency: Double, screen: NSScreen) {
        let frame = screen.frame
        let atTop = corner == .topLeft || corner == .topRight
        let topInset = atTop ? max(screen.safeAreaInsets.top, frame.maxY - screen.visibleFrame.maxY) : 0
        let margin: CGFloat = 12
        let usableWidth = frame.width - 2 * margin
        guard !lines.isEmpty, usableWidth >= 64 else {
            hide()
            return
        }

        content.update(lines: lines, fontSize: fontSize)
        let size = content.preferredSize
        guard frame.height - topInset >= size.height + 2 * margin else {
            hide()
            return
        }

        let width = min(size.width, usableWidth)
        let onRight = corner == .topRight || corner == .bottomRight
        let position = NSRect(
            x: onRight ? frame.maxX - margin - width : frame.minX + margin,
            y: atTop ? frame.maxY - topInset - margin - size.height : frame.minY + margin,
            width: width,
            height: size.height
        )
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let level: NSWindow.Level = atTop ? .floating : Self.lowerCornerLevel
        if panel.level != level { panel.level = level }
        // 整体透明度为零时保留半透明底板原本的外观，避免在每次采样时重复设置窗口。
        let opacity = CGFloat(1 - transparency)
        if panel.alphaValue != opacity { panel.alphaValue = opacity }
        if panel.frame != position {
            if panel.frame.size != position.size { content.needsDisplay = true }
            panel.setFrame(position, display: false)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    /// 隐藏浮层但保留窗口，切换游戏窗口或恢复监测时可以继续复用。
    func hide() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        }
    }
}

/// 根据当前指标绘制一块半透明底板，只有显示文字或字号真的变化时才重新测量。
private final class GameMonitorHUDContent: NSView {
    /// 所有指标使用同一字体，固定宽度数字可以避免常见数值变化导致浮层抖动。
    private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)

    /// 保留上一批指标文字，用于去重和下一次重绘。
    private var lines: [String] = []

    /// 以当前字体求出的行高，留出字体回退和指标之间所需的间距。
    private var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) + 3 }

    /// 文字与浮层边沿之间的留白，测量和绘制使用同一尺寸。
    private let horizontalPadding: CGFloat = 10

    /// 为首尾文字留出余量，避免圆角处与文字相交。
    private let verticalPadding: CGFloat = 6

    /// 由当前文本决定的自然大小，面板可以根据屏幕可用宽度收窄。
    private(set) var preferredSize: NSSize = .zero

    /// 使第一条指标从浮层顶边开始，文字向下依次排列。
    override var isFlipped: Bool { true }

    /// 仅在字号或指标变化时更新内容，避免重复测量和标记重绘。
    func update(lines: [String], fontSize: Double) {
        let size = CGFloat(fontSize)
        guard self.lines != lines || font.pointSize != size else { return }
        self.lines = lines
        if font.pointSize != size {
            font = .monospacedSystemFont(ofSize: size, weight: .medium)
        }
        let longest = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        preferredSize = NSSize(
            width: ceil(longest) + 2 * horizontalPadding,
            height: CGFloat(lines.count) * lineHeight + 2 * verticalPadding
        )
        setAccessibilityLabel(lines.joined(separator: "，"))
        needsDisplay = true
    }

    /// 将每条指标限制在一行，空间不足时截断尾部，防止文字溢出浮层边沿。
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let width = max(0, bounds.width - 2 * horizontalPadding)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        for (index, line) in lines.enumerated() {
            let row = NSRect(
                x: horizontalPadding,
                y: verticalPadding + CGFloat(index) * lineHeight,
                width: width,
                height: lineHeight
            )
            (line as NSString).draw(
                with: row,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: attributes,
                context: nil
            )
        }
    }
}

/// 在游戏模式设置中编辑浮层的监测指标、位置和显示器。
@MainActor
struct GameMonitorSettingsView: View {
    /// 与监测流程共用同一份设置，改变设置后可以同步更新浮层。
    @ObservedObject var monitor: GameMonitor

    /// 单独开关监控浮层，关闭时也可以编辑指标和显示位置。
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("显示监控浮层", isOn: $monitor.isEnabled)
                    .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 5) {
                    Text("显示内容")
                    HStack(spacing: 16) {
                        ForEach(GameMonitorMetric.allCases) { metric in
                            Toggle(metric.title, isOn: metricSelection(metric))
                                .toggleStyle(.checkbox)
                                .disabled(metric == .fps && !monitor.supportsFPS && !monitor.metrics.contains(.fps))
                        }
                    }
                }

                Picker("屏幕位置", selection: $monitor.corner) {
                    ForEach(GameMonitorCorner.allCases) { corner in
                        Text(corner.title).tag(corner)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 8) {
                    Slider(value: $monitor.fontSize, in: 10...24, step: 1) {
                        Text("字号")
                    }
                    Text("\(monitor.fontSize, format: .number.precision(.fractionLength(0))) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Slider(value: $monitor.transparency, in: GameMonitor.transparencyRange, step: 0.05) {
                        Text("透明度")
                    }
                    Text(monitor.transparency, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }

                Picker("显示器", selection: $monitor.preferredDisplayID) {
                    Text("自动（优先跟随游戏）").tag(nil as String?)
                    ForEach(monitor.availableDisplays) { display in
                        Text(display.name).tag(Optional(display.id))
                    }
                    if let selected = monitor.preferredDisplayID,
                       !monitor.availableDisplays.contains(where: { $0.id == selected }) {
                        Text("所选显示器（当前不可单独定位）").tag(Optional(selected))
                    }
                }

                Text(monitor.supportsFPS ? "FPS 需要前台游戏提供 Metal 呈现数据，等待数据时显示「—」。" : "当前系统无法读取游戏 FPS。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Text("游戏监控")
        }
    }

    /// 从指标集合读取勾选状态，切换时只编辑对应的指标。
    private func metricSelection(_ metric: GameMonitorMetric) -> Binding<Bool> {
        Binding(
            get: { monitor.metrics.contains(metric) },
            set: { enabled in
                if enabled {
                    monitor.metrics.insert(metric)
                } else {
                    monitor.metrics.remove(metric)
                }
            }
        )
    }
}
