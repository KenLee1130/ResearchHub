import SwiftUI
import HubStore
#if os(macOS)
import AppKit
#endif

#if os(macOS)
// MARK: - 浮動面板（置頂於所有 app 之上的玻璃小窗）

@MainActor
final class PomodoroPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var hosting: NSHostingController<AnyView>?
    private static let widthKey = "pomodoro.panelWidth"
    private static let widthRange: ClosedRange<CGFloat> = 240...960

    func toggle(pomodoro: PomodoroModel) {
        if let panel, panel.isVisible {
            panel.close()
            return
        }
        let hosting = NSHostingController(rootView: AnyView(
            PomodoroPanelView { [weak self] _ in self?.fitHeight() }
                .environment(pomodoro)))
        // 視窗大小全由這裡決定（寬度＝使用者拉的、高度＝內容需要的）。
        // 不讓 SwiftUI 自動調視窗：sizingOptions = .preferredContentSize 會在無邊框面板上無限遞迴當掉。
        hosting.sizingOptions = []
        let panel = NSPanel(contentViewController: hosting)
        // 無邊框：關閉鈕做在面板內，避免透明標題列的點擊穿透問題。
        // 不用 .utilityWindow —— 它會在 app 失焦時自動把面板藏起來,正是「切桌面後消失」的元兇。
        // .resizable：拉邊角縮放（高度跟著寬度，見 windowWillResize）
        panel.styleMask = [.nonactivatingPanel, .borderless, .resizable]
        panel.level = .floating
        // 出現在所有桌面、跟著 Space 不動、全螢幕也在;切換桌面/切到別的 app 都不消失。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false   // 關鍵:app 不在前景時也保持顯示,直到使用者自己關
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        self.panel = panel
        self.hosting = hosting

        let saved = CGFloat(UserDefaults.standard.double(forKey: Self.widthKey))
        let width = saved > 0 ? saved.clamped(to: Self.widthRange) : 300
        panel.setContentSize(NSSize(width: width, height: contentHeight(forWidth: width)))
        panel.center()
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.close()
    }

    /// 這個寬度下內容要多高
    private func contentHeight(forWidth width: CGFloat) -> CGFloat {
        guard let hosting else { return 200 }
        return ceil(hosting.sizeThatFits(in: CGSize(width: width, height: 10_000)).height)
    }

    /// 內容變了（計時中多出影片、切到無限模式…）：高度跟著改，頂端不動。
    private func fitHeight() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, !panel.inLiveResize else { return }
            var frame = panel.frame
            let height = self.contentHeight(forWidth: frame.width)
            guard height > 0, abs(frame.height - height) > 1 else { return }
            frame.origin.y += frame.height - height
            frame.size.height = height
            panel.setFrame(frame, display: true, animate: false)
        }
    }

    // MARK: NSWindowDelegate

    /// 使用者拉邊角：寬度照拉的，高度剛好包住內容（影片 16:9 跟著放大）
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let width = frameSize.width.clamped(to: Self.widthRange)
        return NSSize(width: width, height: contentHeight(forWidth: width))
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        endResize()
    }

    // MARK: 自訂縮放把手（系統的無邊框視窗邊緣只有 1–2 pt、又在透明邊距外，太難抓）

    var frame: NSRect? { panel?.frame }

    /// 拖把手時：寬度 = 開始時的寬度 + delta，高度跟著內容；頂端不動，往左拉時右邊不動
    func resize(from start: NSRect, widthDelta: CGFloat, keepRightEdge: Bool) {
        guard let panel else { return }
        let width = (start.width + widthDelta).clamped(to: Self.widthRange)
        let height = contentHeight(forWidth: width)
        let frame = NSRect(x: keepRightEdge ? start.maxX - width : start.minX,
                           y: start.maxY - height, width: width, height: height)
        panel.setFrame(frame, display: true, animate: false)
    }

    func endResize() {
        guard let panel else { return }
        UserDefaults.standard.set(Double(panel.frame.width), forKey: Self.widthKey)
        fitHeight()
    }
}

/// 浮動面板的縮放把手：左右兩邊、下方兩角。滑過去游標變縮放箭頭，拖了改寬度（高度跟著內容）。
struct PanelResizeHandle: NSViewRepresentable {
    enum Position { case left, right, bottomLeft, bottomRight }
    let position: Position

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.position = position
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.position = position
    }

    final class HandleView: NSView {
        var position: Position = .right
        private var startFrame: NSRect = .zero
        private var startMouse: NSPoint = .zero
        private var dragging = false

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private var cursor: NSCursor {
            switch position {
            case .left: return .frameResize(position: .left, directions: .all)
            case .right: return .frameResize(position: .right, directions: .all)
            case .bottomLeft: return .frameResize(position: .bottomLeft, directions: .all)
            case .bottomRight: return .frameResize(position: .bottomRight, directions: .all)
            }
        }

        // 面板是不搶焦點的 panel，不一定是 key window → 用 activeAlways 的 tracking area 換游標
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self))
        }

        override func mouseEntered(with event: NSEvent) { cursor.set() }
        override func mouseMoved(with event: NSEvent) { cursor.set() }
        override func mouseExited(with event: NSEvent) { if !dragging { NSCursor.arrow.set() } }

        override func mouseDown(with event: NSEvent) {
            startFrame = window?.frame ?? .zero
            startMouse = NSEvent.mouseLocation
            dragging = true
            cursor.set()
        }

        override func mouseDragged(with event: NSEvent) {
            let p = NSEvent.mouseLocation
            let dx = p.x - startMouse.x
            // 角落往下拉也算放大：換算成等比例的寬度變化，取動得多的那個方向
            let down = (startMouse.y - p.y) * startFrame.width / max(startFrame.height, 1)
            let delta: CGFloat
            switch position {
            case .right: delta = dx
            case .left: delta = -dx
            case .bottomRight: delta = abs(dx) >= abs(down) ? dx : down
            case .bottomLeft: delta = abs(dx) >= abs(down) ? -dx : down
            }
            AppContainer.shared.pomodoroPanel.resize(
                from: startFrame, widthDelta: delta,
                keepRightEdge: position == .left || position == .bottomLeft)
            cursor.set()
        }

        override func mouseUp(with event: NSEvent) {
            dragging = false
            AppContainer.shared.pomodoroPanel.endResize()
        }
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
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
    /// 面板寬度（使用者拉的）：數字跟著放大
    @State private var width: CGFloat = 300
    /// 內容大小變了（給面板視窗調整高度）
    var onSize: (CGSize) -> Void = { _ in }

    private var clockSize: CGFloat { Swift.min(Swift.max(width * 0.15, 36), 120) }
    private var scale: CGFloat { Swift.min(Swift.max(width / 300, 1), 2.2) }

    var body: some View {
        VStack(spacing: 8 * scale) {
            PomodoroSceneStrip(cornerRadius: 10 + 4 * scale)
            PomodoroClockText(size: clockSize)
            PomodoroStatusLine()
            if pomodoro.canPickMode {
                PomodoroModePicker()
                    .frame(width: 170)
            }
            PomodoroPlanRow()
                .frame(maxWidth: 200 * scale)
            PomodoroControls(spacing: 18 * scale, iconFont: .system(size: 17 * scale), showsPanelButton: false)
            if !pomodoro.isFlowMode {
                HStack(spacing: 4) {
                    ForEach(0..<pomodoro.cycleLength, id: \.self) { i in
                        Capsule()
                            .fill(i < pomodoro.cyclePosition
                                  ? Color.accentColor : Color.primary.opacity(0.15))
                            .frame(height: 4)
                    }
                }
                .frame(width: 120 * scale)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        // 面板內容全是 SwiftUI，NSHostingView 會吃掉滑鼠，isMovableByWindowBackground 不會生效 →
        // 背景鋪一層：按下就請視窗跟著拖。按鈕、計畫欄蓋在上面，照樣能點。
        .background(WindowDragArea())
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .contextMenu { PomodoroSceneMenu() }
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: pomodoro.isActive)
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
        // 縮放把手：左右兩條（從透明邊距一路蓋到卡片邊緣）、下方兩角（滑過面板時顯示握把）
        .overlay(alignment: .leading) { edgeHandle(.left) }
        .overlay(alignment: .trailing) { edgeHandle(.right) }
        .overlay(alignment: .bottomLeading) { cornerHandle(.bottomLeft) }
        .overlay(alignment: .bottomTrailing) { cornerHandle(.bottomRight) }
        // 寬度聽視窗的，高度用內容自己需要的（視窗再跟著調）
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            width = size.width
            onSize(size)
        }
    }
}

extension PomodoroPanelView {
    /// 透明邊距要有一點點不透明，點擊才不會穿到後面的視窗
    private static let grabFill = Color.black.opacity(0.02)

    fileprivate func edgeHandle(_ position: PanelResizeHandle.Position) -> some View {
        PanelResizeHandle(position: position)
            .background(Self.grabFill)
            .frame(width: 16)
            .padding(.vertical, 30)
    }

    fileprivate func cornerHandle(_ position: PanelResizeHandle.Position) -> some View {
        let isLeft = position == .bottomLeft
        return PanelResizeHandle(position: position)
            .background(Self.grabFill)
            .frame(width: 30, height: 30)
            .overlay(alignment: isLeft ? .bottomLeading : .bottomTrailing) {
                // 握把：兩條斜線，跟著卡片圓角往內縮
                Path { p in
                    for offset in [0.0, 5.0] {
                        p.move(to: CGPoint(x: 10, y: offset))
                        p.addLine(to: CGPoint(x: offset, y: 10))
                    }
                }
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 10, height: 10)
                .scaleEffect(x: isLeft ? -1 : 1)
                .padding(isLeft ? .leading : .trailing, 16)
                .padding(.bottom, 16)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(false)
            }
    }
}

// MARK: - 共用小元件（側欄、浮動面板）

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

    private var ticking: Bool { pomodoro.isTicking }

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

// MARK: - 計時中的動畫（跟手機同一批影片）

extension PomodoroModel {
    /// 正在走（倒數中，或無限模式沒暫停）
    var isTicking: Bool { isRunning || (flow.map { !$0.paused } ?? false) }
}

/// 浮動面板的場景：開始計時時挑一次，點影片換下一個（面板關掉再開也接著同一個）。
@MainActor
@Observable
final class PomodoroSceneState {
    private(set) var scene: PomodoroScene = .study
    @ObservationIgnored private var picked = false

    /// 計時開始時挑一次（側欄、面板都會呼叫，只算一次）；停了就等下一段再挑
    func update(active: Bool, choice: String) {
        guard active else { picked = false; return }
        guard !picked else { return }
        picked = true
        pick(choice)
    }

    func pick(_ choice: String) {
        if let fixed = PomodoroScene(rawValue: choice) {
            scene = fixed
        } else if choice != "off" {
            scene = .random(excluding: scene)
        }
    }

    func next() { scene = scene.next }
}

/// 計時中才出現的 16:9 影片；暫停就定格。待命時不佔空間。
struct PomodoroSceneStrip: View {
    @Environment(PomodoroModel.self) private var pomodoro
    @AppStorage("pomodoro.scene") private var choice = "random"
    var cornerRadius: CGFloat = 8
    private var state: PomodoroSceneState { AppContainer.shared.pomodoroScene }

    var body: some View {
        Group {
            if pomodoro.isActive && choice != "off" {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    // 浮動面板量大小時高度沒有提議值：不鎖住的話影片會被壓成 0 高
                    .fixedSize(horizontal: false, vertical: true)
                    .overlay {
                        PomodoroSceneView(scene: state.scene, paused: !pomodoro.isTicking)
                            .id(state.scene)
                            .transition(.opacity)
                    }
                    .overlay {
                        if !pomodoro.isTicking {
                            Color.black.opacity(0.25)
                            Image(systemName: "pause.fill")
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.35)) { state.next() }
                    }
                    .help(Text("\(Text(state.scene.title)) · 點一下換場景，右鍵選擇或關掉動畫"))
                    .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity),
                                            removal: .opacity))
            }
        }
        .onChange(of: pomodoro.isActive, initial: true) { _, active in
            state.update(active: active, choice: choice)
        }
        .onChange(of: choice) { state.pick(choice) }
    }
}

/// 右鍵選單：選場景／隨機／不要動畫（Mac 自己記，不跟手機同步）
struct PomodoroSceneMenu: View {
    @AppStorage("pomodoro.scene") private var choice = "random"

    var body: some View {
        Picker("動畫", selection: $choice) {
            Label("隨機", systemImage: "shuffle").tag("random")
            ForEach(PomodoroScene.available) { s in
                Label(s.title, systemImage: s.symbol).tag(s.rawValue)
            }
            Label("不要動畫", systemImage: "eye.slash").tag("off")
        }
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
