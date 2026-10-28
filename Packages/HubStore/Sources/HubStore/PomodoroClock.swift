import Foundation
import Combine

/// 只裝每秒會變的倒數。觀察它的只有 app 的 PomodoroCountdownText，
/// 所以每秒重畫的範圍就是那一行數字。
@MainActor
public final class PomodoroClock: ObservableObject {
    @Published public var remaining: Int = 25 * 60

    public init() {}

    public var timeString: String {
        String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }
}
