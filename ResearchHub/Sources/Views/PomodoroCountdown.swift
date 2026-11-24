import SwiftUI
import HubStore

/// 顯示倒數的唯一元件：外觀（字體等）由呼叫端加 modifier。觀察的是 HubStore 的 PomodoroClock。
struct PomodoroCountdownText: View {
    @ObservedObject var clock: PomodoroClock

    var body: some View {
        Text(clock.timeString)
    }
}

enum PomodoroFormat {
    /// 秒數 → 「12:34」或「1:02:03」
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// 「1 小時 23 分」「12 分 30 秒」
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = s / 60 % 60, sec = s % 60
        if h > 0 { return L("\(h) 小時 \(m) 分") }
        if m > 0 { return L("\(m) 分 \(sec) 秒") }
        return L("\(sec) 秒")
    }
}
