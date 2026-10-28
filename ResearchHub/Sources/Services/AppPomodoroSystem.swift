import Foundation
import UserNotifications
import HubStore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// 蕃茄鐘用到的系統服務：推播、提示音、帶到前景、app 結束通知（PomodoroModel 只透過 protocol 用它）。
@MainActor
final class AppPomodoroSystem: PomodoroSystem {
    private var terminationObserver: NSObjectProtocol?

    func observeTermination(_ handler: @escaping @MainActor () -> Void) {
        #if canImport(AppKit)
        let name = NSApplication.willTerminateNotification
        #else
        let name = UIApplication.willTerminateNotification
        #endif
        terminationObserver = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().delegate = AppContainer.shared.notificationDelegate
        Task {
            try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        }
    }

    func scheduleNotification(id: String, title: String, body: String, after seconds: Int) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func cancelNotification(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    func notify(title: String, body: String) {
        #if canImport(AppKit)
        NSSound.beep() // 即時音效（通知被拒絕時仍有提示）
        #endif
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func bringToFront() {
        #if canImport(AppKit)
        NSApp.activate(ignoringOtherApps: true)
        #endif
    }
}

/// 讓通知在 app 位於前景時也顯示橫幅（macOS 預設前景時不顯示）。
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
