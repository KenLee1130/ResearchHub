#if os(iOS)
import SwiftUI
import UIKit

/// 閱讀關卡畫面：讀 abstract → 答理解題 → 全對才放行回原本的 app。
/// 由 `researchhub://gate?app=<scheme>` 觸發（捷徑自動化在打開黑名單 app 時導過來）。
struct ReadingGateView: View {
    /// 要放行回去的 app（nil = 從 app 內自己點進來預習，通過後只是關掉）
    let target: GateApp?
    var onFinish: () -> Void

    private var gate = ReadingGateStore.shared
    @Environment(\.openURL) private var openURL

    @State private var paper: GatePaper?
    @State private var stage: Stage = .reading
    /// 每題選了哪個選項
    @State private var picked: [Int: Int] = [:]
    /// 已判過且答錯的題（顯示紅框與說明）
    @State private var wrong: Set<Int> = []
    @State private var attempts = 0
    /// 讀 abstract 的最短停留時間（避免直接跳答案）
    @State private var readSecondsLeft = 0
    @State private var timer: Timer?
    /// 目前的蕃茄鐘狀態（用來提醒「你現在該做什麼」）
    @State private var focus = GateFocusState()

    enum Stage { case reading, quiz, passed }

    private var minReadSeconds: Int {
        // 依 abstract 長度給 8–25 秒
        let words = max(1, (paper?.abstract.count ?? 0) / 6)
        return min(25, max(8, words / 12))
    }

    var body: some View {
        Group {
            if let paper {
                content(paper)
            } else {
                emptyBank
            }
        }
        .interactiveDismissDisabled()
        .onAppear(perform: start)
        .onDisappear { timer?.invalidate() }
    }

    // MARK: - 內容

    private func content(_ p: GatePaper) -> some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    currentTaskBanner
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.title).font(.headline)
                        if let a = p.authors, !a.isEmpty {
                            Text(a + (p.year.map { " · \($0)" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(p.abstract)
                        .font(.callout)
                        .textSelection(.enabled)

                    if stage == .quiz || stage == .passed {
                        Divider().padding(.vertical, 2)
                        ForEach(Array(p.questions.enumerated()), id: \.offset) { i, q in
                            questionBlock(i, q)
                        }
                    }
                }
                .padding(16)
            }
            footer(p)
        }
    }

    /// 「你現在該做的是這件事」——比 paper 更重要的提醒，所以放最上面。
    @ViewBuilder
    private var currentTaskBanner: some View {
        if focus.pomodoroActive && focus.phase == "work" {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                    Text("蕃茄鐘進行中").font(.caption.weight(.semibold))
                    if let i = focus.pomoIndex, let t = focus.pomoTotal {
                        Text("第 \(i)/\(t) 顆").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let left = focus.remainingSeconds {
                        Text("剩 \(left / 60):\(String(format: "%02d", left % 60))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if focus.plan.isEmpty {
                    Text("這顆沒有寫下計畫——回去補一句，會比較好收心。")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("你現在應該在做：").font(.caption).foregroundStyle(.secondary)
                    Text(focus.plan)
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.14)))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: stage == .passed ? "checkmark.seal.fill" : "lock.fill")
                .foregroundStyle(stage == .passed ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(stage == .passed ? "通過了" : "先讀一篇再滑")
                    .font(.subheadline.weight(.semibold))
                if let t = target {
                    Text("讀完就回到 \(t.name)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if attempts > 0 && stage != .passed {
                Text("第 \(attempts + 1) 次作答")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private func questionBlock(_ i: Int, _ q: GateQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(i + 1). \(q.q)").font(.subheadline.weight(.medium))
            ForEach(Array(q.options.enumerated()), id: \.offset) { j, opt in
                let isPicked = picked[i] == j
                let isCorrect = stage == .passed || (wrong.contains(i) && j == q.answer)
                Button {
                    guard stage == .quiz else { return }
                    picked[i] = j
                    wrong.remove(i)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: isPicked ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isPicked ? Color.accentColor : .secondary)
                        Text(opt).font(.callout).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isCorrect && j == q.answer
                                  ? Color.green.opacity(0.15)
                                  : (wrong.contains(i) && isPicked
                                     ? Color.red.opacity(0.15) : Color.clear)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(stage == .passed)
            }
            if wrong.contains(i), let e = q.explain, !e.isEmpty {
                Text(e).font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func footer(_ p: GatePaper) -> some View {
        VStack(spacing: 8) {
            switch stage {
            case .reading:
                Button {
                    stage = .quiz
                } label: {
                    Text(readSecondsLeft > 0 ? "再讀 \(readSecondsLeft) 秒" : "讀完了，開始作答")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(readSecondsLeft > 0)
            case .quiz:
                Button {
                    grade(p)
                } label: {
                    Text("送出答案").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(picked.count < p.questions.count)
                if !wrong.isEmpty {
                    Text("有 \(wrong.count) 題答錯了——看一下上面的說明再改。")
                        .font(.caption).foregroundStyle(.red)
                }
            case .passed:
                Button {
                    release()
                } label: {
                    Label(target.map { "回到 \($0.name)" } ?? "完成",
                          systemImage: "arrow.uturn.forward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if focus.pomodoroActive && focus.phase == "work" && !focus.plan.isEmpty {
                    Text("……不過你這顆蕃茄鐘要做的是「\(focus.plan)」")
                        .font(.caption).foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                Text("接下來 \(gate.graceMinutes) 分鐘不會再攔你")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.bar)
    }

    /// 題庫是空的：不能把人鎖在這裡，直接放行並說明怎麼補題庫。
    private var emptyBank: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("題庫是空的").font(.headline)
            Text("請在 Mac 上讓 Claude 從 Zotero 生成題庫\n（寫進 .hub/claude/reading_gate.json）")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("先放行") { release() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    // MARK: - 流程

    private func start() {
        focus = gate.focusState()
        paper = gate.nextPaper()
        readSecondsLeft = minReadSeconds
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            Task { @MainActor in
                if readSecondsLeft > 0 { readSecondsLeft -= 1 } else { t.invalidate() }
            }
        }
    }

    private func grade(_ p: GatePaper) {
        attempts += 1
        var bad = Set<Int>()
        for (i, q) in p.questions.enumerated() where picked[i] != q.answer {
            bad.insert(i)
        }
        wrong = bad
        if bad.isEmpty {
            gate.recordPass(p)
            withAnimation { stage = .passed }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    /// 放行：有目標 app 就跳回去，否則只是關掉。
    private func release() {
        if let url = target?.openURL {
            openURL(url)
        }
        onFinish()
    }
}
#endif
