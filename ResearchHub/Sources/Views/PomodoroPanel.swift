import SwiftUI
import HubStore
#if os(macOS)
import AppKit
#endif

#if os(macOS)
// MARK: - 浮動面板（置頂於所有 app 之上的玻璃小窗）

@MainActor
final class PomodoroPanelController {
    private var panel: NSPanel?

    func toggle(pomodoro: PomodoroModel) {
        if let panel, panel.isVisible {
            panel.close()
            return
        }
        let hosting = NSHostingController(
            rootView: PomodoroPanelView().environment(pomodoro))
        let panel = NSPanel(contentViewController: hosting)
        // 無邊框：關閉鈕做在面板內，避免透明標題列的點擊穿透問題。
        // 不用 .utilityWindow —— 它會在 app 失焦時自動把面板藏起來,正是「切桌面後消失」的元兇。
        panel.styleMask = [.nonactivatingPanel, .borderless]
        panel.level = .floating
        // 出現在所有桌面、跟著 Space 不動、全螢幕也在;切換桌面/切到別的 app 都不消失。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false   // 關鍵:app 不在前景時也保持顯示,直到使用者自己關
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.close()
    }
}

/// 按住就能拖動所在視窗的區域（無邊框面板用）
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

struct PomodoroPanelView: View {
    @Environment(PomodoroModel.self) private var pomodoro
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            PomodoroClockText(size: 36)
            PomodoroStatusLine()
            if pomodoro.canPickMode {
                PomodoroModePicker()
                    .frame(width: 170)
            }
            PomodoroPlanRow()
                .frame(maxWidth: 200)
            PomodoroControls(spacing: 18, iconFont: .title3, showsPanelButton: false)
            if !pomodoro.isFlowMode {
                HStack(spacing: 4) {
                    ForEach(0..<pomodoro.cycleLength, id: \.self) { i in
                        Capsule()
                            .fill(i < pomodoro.cyclePosition
                                  ? Color.accentColor : Color.primary.opacity(0.15))
                            .frame(height: 4)
                    }
                }
                .frame(width: 120)
            }
        }
        .padding(22)
        // 面板內容全是 SwiftUI，NSHostingView 會吃掉滑鼠，isMovableByWindowBackground 不會生效 →
        // 背景鋪一層：按下就請視窗跟著拖。按鈕、計畫欄蓋在上面，照樣能點。
        .background(WindowDragArea())
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .overlay(alignment: .topTrailing) {
            // 滑過面板時顯示關閉鈕
            Button {
                AppContainer.shared.pomodoroPanel.close()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .padding(8)
    }
}

// MARK: - 共用小元件（側欄、浮動面板）

extension PomodoroModel {
    /// 還沒開始、在 work 階段：可以切蕃茄鐘／無限模式
    var canPickMode: Bool { !isActive && phase == .work }
}

/// 大數字：蕃茄鐘是倒數，無限模式是開始到現在的總時間
struct PomodoroClockText: View {
    @Environment(PomodoroModel.self) private var pomodoro
    let size: CGFloat

    var body: some View {
        Group {
            if let flow = pomodoro.flow {
                // 只有這個小元件每秒重畫，不會牽動整個側欄
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(verbatim: PomodoroFormat.clock(flow.totalSeconds(at: ctx.date)))
                }
            } else if pomodoro.isFlowMode {
                Text(verbatim: "00:00")
            } else {
                PomodoroCountdownText(clock: pomodoro.clock)
            }
        }
        .font(.system(size: size, weight: .medium, design: .monospaced))
        .monospacedDigit()
    }
}

/// 數字底下那行：蕃茄鐘顯示階段；無限模式顯示工作／離開各多久
struct PomodoroStatusLine: View {
    @Environment(PomodoroModel.self) private var pomodoro

    var body: some View {
        if let flow = pomodoro.flow {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(spacing: 8) {
                    Label(PomodoroFormat.clock(flow.workSeconds(at: ctx.date)), systemImage: "brain.head.profile")
                        .foregroundStyle(.red)
                        .help("工作時間")
                    Label(PomodoroFormat.clock(flow.awaySeconds(at: ctx.date)), systemImage: "cup.and.saucer")
                        .foregroundStyle(.secondary)
                        .help("非工作時間（暫停、螢幕鎖定或睡眠）")
                    if flow.paused {
                        Text("暫停中")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                .labelStyle(.titleAndIcon)
                .font(.caption.monospacedDigit())
            }
        } else if pomodoro.isFlowMode {
            Text("正向計時")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(LocalizedStringKey(pomodoro.phase.label))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 蕃茄鐘／無限模式切換（還沒開始時才出現）
struct PomodoroModePicker: View {
    @Environment(PomodoroModel.self) private var pomodoro

    var body: some View {
        Picker("模式", selection: Bindable(pomodoro).mode) {
            ForEach(PomodoroModel.Mode.allCases) { m in
                Text(LocalizedStringKey(m.label)).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .help("無限模式：一直計時到按「結束」，暫停與螢幕鎖定、睡眠的時間記成非工作時間")
    }
}

/// 開始／暫停＋其他按鈕。無限模式開著時是「放棄、暫停、結束」。
struct PomodoroControls: View {
    @Environment(PomodoroModel.self) private var pomodoro
    let spacing: CGFloat
    var iconFont: Font = .body
    /// 側欄才有「開浮動面板」
    var showsPanelButton = true
    @State private var confirmDiscard = false

    private var ticking: Bool {
        pomodoro.isRunning || (pomodoro.flow.map { !$0.paused } ?? false)
    }

    var body: some View {
        HStack(spacing: spacing) {
            iconButton(ticking ? "pause.fill" : "play.fill", help: ticking ? "暫停" : "開始") {
                pomodoro.toggle()
            }
            if pomodoro.flow != nil {
                iconButton("stop.fill", help: "結束這一段，記下工作時間") {
                    pomodoro.stopFlow()
                }
                .foregroundStyle(.red)
                iconButton("xmark", help: "放棄這一段（不記錄）") {
                    confirmDiscard = true
                }
            } else {
                iconButton("arrow.counterclockwise", help: "重設目前這顆；右鍵可將整個循環歸零") {
                    pomodoro.reset()
                }
                .contextMenu {
                    Button("整個循環歸零") { pomodoro.resetCycle() }
                }
            }
            if showsPanelButton {
                iconButton("arrow.up.right.square", help: "浮動面板（置頂於其他視窗）") {
                    AppContainer.shared.pomodoroPanel.toggle(pomodoro: pomodoro)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .confirmationDialog("放棄這一段？", isPresented: $confirmDiscard) {
            Button("放棄，不記錄", role: .destructive) { pomodoro.reset() }
        } message: {
            Text("已經記的時間會全部丟掉。要留下紀錄請按「結束」。")
        }
    }

    private func iconButton(_ symbol: String, help: LocalizedStringKey,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(iconFont)
                .padding(5)
                .contentShape(Rectangle())
        }
        .help(help)
    }
}

// MARK: - 「這顆要做什麼」計畫列（計時器上顯示 / 點擊編輯）

/// work 階段（或無限模式）顯示目前的計畫；點一下用 popover 編輯。休息階段不顯示。
struct PomodoroPlanRow: View {
    @Environment(PomodoroModel.self) private var pomodoro
    @State private var editing = false
    @State private var draft = ""

    private var plan: String { pomodoro.flow?.plan ?? pomodoro.currentPlan }
    private var flowMode: Bool { pomodoro.isFlowMode }

    var body: some View {
        if pomodoro.phase == .work || pomodoro.flow != nil {
            Button {
                draft = plan
                editing = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "target").font(.caption2)
                    Group {
                        if plan.isEmpty {
                            Text(flowMode ? "這段要做什麼？" : "這顆要做什麼？")
                        } else {
                            Text(plan)
                        }
                    }
                        .font(.caption2)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(plan.isEmpty ? .tertiary : .secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $editing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(flowMode ? "這段要做什麼" : "這顆蕃茄鐘要做什麼").font(.headline)
                    TextField("例如：推導 crossing equation", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .frame(width: 260)
                        .onSubmit(commit)
                    HStack {
                        Spacer()
                        Button("完成", action: commit).keyboardShortcut(.defaultAction)
                    }
                }
                .padding(14)
            }
        }
    }

    private func commit() {
        pomodoro.updatePlan(draft)
        editing = false
    }
}

// MARK: - Sidebar mini view

struct PomodoroMiniView: View {
    @Environment(PomodoroModel.self) private var pomodoro

    var body: some View {
        VStack(spacing: 6) {
            PomodoroClockText(size: 20)
            PomodoroStatusLine()

            if pomodoro.canPickMode {
                PomodoroModePicker()
                    .padding(.horizontal, 12)
            }

            PomodoroPlanRow()

            PomodoroControls(spacing: 14)

            if pomodoro.isFlowMode {
                Text("今日 \(pomodoro.todayCount) 顆")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                // 循環進度條
                HStack(spacing: 3) {
                    ForEach(0..<pomodoro.cycleLength, id: \.self) { i in
                        Capsule()
                            .fill(segmentColor(i))
                            .frame(height: 4)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)

                Text("第 \(min(pomodoro.cyclePosition + 1, pomodoro.cycleLength)) / \(pomodoro.cycleLength) 顆 · 今日 \(pomodoro.todayCount)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
    }

    private func segmentColor(_ index: Int) -> Color {
        if index < pomodoro.cyclePosition {
            return .accentColor
        }
        if index == pomodoro.cyclePosition && pomodoro.phase == .work && pomodoro.isRunning {
            return .accentColor.opacity(0.4)
        }
        return .primary.opacity(0.15)
    }
}

// MARK: - 無限模式：螢幕鎖定／睡眠記成非工作時間

/// iPhone 是「離開蕃茄鐘那頁」就算離開；Mac 上本來就是開著別的 app 工作，
/// 所以改成：螢幕鎖定、螢幕保護程式、螢幕／電腦睡眠、切換使用者 → 非工作時間，回來接著記。
@MainActor
final class FlowAwayWatcher {
    private weak var pomodoro: PomodoroModel?
    private var reasons: Set<String> = []
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    func start(_ pomodoro: PomodoroModel) {
        guard self.pomodoro == nil else { return }
        self.pomodoro = pomodoro
        // 剛開 app 一定在螢幕前（上次關 app 時若正鎖著，旗標別卡住）
        pomodoro.setFlowOffScreen(false)

        let ws = NSWorkspace.shared.notificationCenter
        watch(ws, NSWorkspace.willSleepNotification, "sleep", away: true)
        watch(ws, NSWorkspace.didWakeNotification, "sleep", away: false)
        watch(ws, NSWorkspace.screensDidSleepNotification, "screen", away: true)
        watch(ws, NSWorkspace.screensDidWakeNotification, "screen", away: false)
        watch(ws, NSWorkspace.sessionDidResignActiveNotification, "session", away: true)
        watch(ws, NSWorkspace.sessionDidBecomeActiveNotification, "session", away: false)
        let dc = DistributedNotificationCenter.default()
        watch(dc, .init("com.apple.screenIsLocked"), "lock", away: true)
        watch(dc, .init("com.apple.screenIsUnlocked"), "lock", away: false)
        watch(dc, .init("com.apple.screensaver.didstart"), "saver", away: true)
        watch(dc, .init("com.apple.screensaver.didstop"), "saver", away: false)
    }

    private func watch(_ center: NotificationCenter, _ name: Notification.Name, _ reason: String, away: Bool) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(reason, away: away) }
        }
        tokens.append((center, token))
    }

    private func set(_ reason: String, away: Bool) {
        if away { reasons.insert(reason) } else { reasons.remove(reason) }
        // 醒來／解鎖時順序不一定，全部都回來才算回到螢幕前
        pomodoro?.setFlowOffScreen(!reasons.isEmpty)
    }
}
#endif
