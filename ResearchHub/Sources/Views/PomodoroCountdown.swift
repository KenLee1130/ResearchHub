import SwiftUI
import HubStore

/// 顯示倒數的唯一元件：外觀（字體等）由呼叫端加 modifier。觀察的是 HubStore 的 PomodoroClock。
struct PomodoroCountdownText: View {
    @ObservedObject var clock: PomodoroClock

    var body: some View {
        Text(clock.timeString)
    }
}
