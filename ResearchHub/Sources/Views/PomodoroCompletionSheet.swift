import SwiftUI

/// 工作 / 休息結束時跳出的小視窗。
/// 工作結束:先記「這顆做了什麼」,再選 繼續工作(分鐘+下一顆計畫) / 開始休息 / 稍後再說。
/// 休息結束:選 繼續工作(分鐘+計畫) / 繼續休息(分鐘) / 稍後再說。
/// 「稍後再說」=關掉視窗、不啟動下一段計時器,等使用者自己開始。
struct PomodoroCompletionSheet: View {
    @EnvironmentObject private var pomodoro: PomodoroModel
    let prompt: PomodoroModel.CompletionPrompt

    // 哪些欄位必填（由設定 → 蕃茄鐘 控制）
    @AppStorage(PomodoroModel.SettingsKey.requireContinueWorkMinutes) private var reqContinueWork = false
    @AppStorage(PomodoroModel.SettingsKey.requireLastWorkNote) private var reqLastWork = false
    @AppStorage(PomodoroModel.SettingsKey.requirePlannedNote) private var reqPlanned = false
    @AppStorage(PomodoroModel.SettingsKey.requireExtendBreakMinutes) private var reqExtendBreak = true

    // 工作結束
    @State private var doneText = ""        // 這顆完成了什麼
    @State private var nextPlanText = ""    // 下一顆要做什麼
    @State private var extraWorkMin = ""    // 還要工作幾分鐘
    // 休息結束
    @State private var afterBreakPlan = ""  // 繼續工作：這顆要做什麼
    @State private var afterBreakMin = ""   // 繼續工作：幾分鐘（可留空）
    @State private var extendBreakMin = ""  // 繼續休息：幾分鐘

    private var isWorkDone: Bool {
        if case .workDone = prompt { return true }
        return false
    }
    private var breakWasLong: Bool {
        if case .breakDone(let wasLong) = prompt { return wasLong }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isWorkDone ? "🍅 完成一顆蕃茄" : "☕ 休息結束")
                .font(.title2.bold())
            Text(isWorkDone ? "記一下這顆做了什麼，再決定下一步。" : "準備好了嗎？")
                .font(.callout)
                .foregroundStyle(.secondary)

            if isWorkDone { workContent } else { breakContent }
        }
        .padding(28)
        .frame(width: 470)
        // 預設把「完成內容」填成這顆原本的計畫，省得重打（不對再改）。
        .onAppear { if isWorkDone && doneText.isEmpty { doneText = pomodoro.currentPlan } }
    }

    // MARK: - 工作結束

    private var workContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(reqLastWork ? "這顆完成了什麼" : "這顆完成了什麼（可留空）")
                    .font(.subheadline.weight(.medium))
                TextField("例如：算完 free boson 的 IRCFT 部分", text: $doneText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }

            Divider()

            twoFieldCard(
                title: "繼續工作", tint: .accentColor,
                numberLabel: reqContinueWork ? "幾分鐘" : "幾分鐘（留空=預設）", numberText: $extraWorkMin,
                descLabel: reqPlanned ? "下一顆要做什麼" : "下一顆要做什麼（可留空）", descText: $nextPlanText,
                buttonTitle: "繼續工作",
                disabled: (reqContinueWork && parsedInt(extraWorkMin) == nil)
                    || (reqPlanned && trimmedOrNil(nextPlanText) == nil)
            ) {
                pomodoro.continueWorkAfterWork(
                    doneNote: doneText, extraMinutes: parsedInt(extraWorkMin), nextPlan: nextPlanText)
            }

            actionCard(
                title: "開始休息", tint: .green, buttonTitle: "開始休息",
                disabled: reqLastWork && trimmedOrNil(doneText) == nil
            ) {
                pomodoro.startBreakAfterWork(doneNote: doneText)
            }

            laterButton { pomodoro.dismissAfterWork(doneNote: doneText) }
        }
    }

    // MARK: - 休息結束

    private var breakContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            twoFieldCard(
                title: "繼續工作", tint: .accentColor,
                numberLabel: "幾分鐘（留空=預設）", numberText: $afterBreakMin,
                descLabel: reqPlanned ? "這顆要做什麼" : "這顆要做什麼（可留空）", descText: $afterBreakPlan,
                buttonTitle: "繼續工作",
                disabled: reqPlanned && trimmedOrNil(afterBreakPlan) == nil
            ) {
                pomodoro.continueWorkAfterBreak(
                    nextPlan: afterBreakPlan, extraMinutes: parsedInt(afterBreakMin),
                    wasLong: breakWasLong)
            }

            oneNumberCard(
                title: "繼續休息", tint: .green,
                numberLabel: reqExtendBreak ? "還要休息幾分鐘" : "還要休息幾分鐘（留空=預設）",
                numberText: $extendBreakMin, buttonTitle: "繼續休息",
                disabled: reqExtendBreak && parsedInt(extendBreakMin) == nil
            ) {
                pomodoro.extendBreak(minutes: parsedInt(extendBreakMin))
            }

            laterButton { pomodoro.dismissAfterBreak(wasLong: breakWasLong) }
        }
    }

    // MARK: - 卡片元件

    private func twoFieldCard(
        title: LocalizedStringKey, tint: Color,
        numberLabel: LocalizedStringKey, numberText: Binding<String>,
        descLabel: LocalizedStringKey, descText: Binding<String>,
        buttonTitle: LocalizedStringKey, disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            HStack(spacing: 8) {
                TextField(numberLabel, text: numberText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                TextField(descLabel, text: descText)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent).tint(tint).disabled(disabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func oneNumberCard(
        title: LocalizedStringKey, tint: Color,
        numberLabel: LocalizedStringKey, numberText: Binding<String>,
        buttonTitle: LocalizedStringKey, disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            TextField(numberLabel, text: numberText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !disabled { action() } }
            HStack {
                Spacer()
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent).tint(tint).disabled(disabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func actionCard(
        title: LocalizedStringKey, tint: Color, buttonTitle: LocalizedStringKey,
        disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent).tint(tint).disabled(disabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func laterButton(_ action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button("稍後再說（先關掉，待會自己開始）", action: action)
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 2)
    }

    // MARK: - Helpers

    private func trimmedOrNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func parsedInt(_ s: String) -> Int? {
        guard let v = Int(s.trimmingCharacters(in: .whitespaces)), v > 0 else { return nil }
        return v
    }
}
