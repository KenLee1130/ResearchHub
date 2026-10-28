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
            PomodoroCountdownText(clock: pomodoro.clock)
                .font(.system(size: 36, weight: .medium, design: .monospaced))
            Text(pomodoro.phase.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            PomodoroPlanRow()
                .frame(maxWidth: 200)
            HStack(spacing: 18) {
                Button {
                    pomodoro.toggle()
                } label: {
                    Image(systemName: pomodoro.isRunning ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .padding(5)
                        .contentShape(Rectangle())
                }
                Button {
                    pomodoro.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.title3)
                        .padding(5)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
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

// MARK: - 「這顆要做什麼」計畫列（計時器上顯示 / 點擊編輯）

/// work 階段顯示目前這顆的計畫;點一下用 popover 編輯。其他階段不顯示。
struct PomodoroPlanRow: View {
    @Environment(PomodoroModel.self) private var pomodoro
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        if pomodoro.phase == .work {
            Button {
                draft = pomodoro.currentPlan
                editing = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "target").font(.caption2)
                    Group {
                        if pomodoro.currentPlan.isEmpty {
                            Text("這顆要做什麼？")
                        } else {
                            Text(pomodoro.currentPlan)
                        }
                    }
                        .font(.caption2)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(pomodoro.currentPlan.isEmpty ? .tertiary : .secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $editing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("這顆蕃茄鐘要做什麼").font(.headline)
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
        pomodoro.currentPlan = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
    }
}

// MARK: - Sidebar mini view

struct PomodoroMiniView: View {
    @Environment(PomodoroModel.self) private var pomodoro

    var body: some View {
        VStack(spacing: 6) {
            PomodoroCountdownText(clock: pomodoro.clock)
                .font(.system(size: 20, weight: .medium, design: .monospaced))
            Text(LocalizedStringKey(pomodoro.phase.label))
                .font(.caption)
                .foregroundStyle(.secondary)

            PomodoroPlanRow()

            HStack(spacing: 14) {
                Button {
                    pomodoro.toggle()
                } label: {
                    Image(systemName: pomodoro.isRunning ? "pause.fill" : "play.fill")
                        .padding(5)
                        .contentShape(Rectangle())
                }
                Button {
                    pomodoro.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .help("重設目前這顆；右鍵可將整個循環歸零")
                .contextMenu {
                    Button("整個循環歸零") { pomodoro.resetCycle() }
                }
                Button {
                    AppContainer.shared.pomodoroPanel.toggle(pomodoro: pomodoro)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .help("浮動面板（置頂於其他視窗）")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

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
#endif
