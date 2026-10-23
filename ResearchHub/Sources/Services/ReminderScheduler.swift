import Foundation
import UserNotifications
import HubStore

/// @remind 的推播：HubStore 算出要提醒什麼，這裡用 UserNotifications 排程（app 啟動時掛上）。
enum ReminderScheduler {
    static func install() {
        LibraryScan.reminderScheduler = { reminders in
            let center = UNUserNotificationCenter.current()
            for r in reminders {
                let content = UNMutableNotificationContent()
                content.title = "⏰ \(r.text)"
                content.sound = .default
                let comps = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: r.at)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                center.add(UNNotificationRequest(
                    identifier: "todo.remind.\(r.text)",
                    content: content, trigger: trigger))
            }
        }
    }
}
