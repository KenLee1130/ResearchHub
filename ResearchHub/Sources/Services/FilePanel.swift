#if os(macOS)
import AppKit

/// 存檔／開檔面板一律掛在目前的視窗上（sheet），不要獨立彈出。
///
/// 獨立的面板（`runModal()`／`begin`）在主視窗全螢幕時會開到別的桌面：
/// 使用者按了「匯出 PDF」什麼都沒看到，`runModal` 又把整個 app 卡住，看起來就像壞了。
@MainActor
enum FilePanel {
    static func present(_ panel: NSSavePanel,
                        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if let host = hostWindow() {
            panel.beginSheetModal(for: host) { response in
                MainActor.assumeIsolated { completion(response) }
            }
        } else {
            panel.begin { response in
                MainActor.assumeIsolated { completion(response) }
            }
        }
    }

    /// 按下按鈕的那個視窗。蕃茄鐘之類的浮動小面板不算（sheet 掛上去會很怪）。
    private static func hostWindow() -> NSWindow? {
        [NSApp.keyWindow, NSApp.mainWindow]
            .compactMap { $0 }
            .first { !($0 is NSPanel) && $0.isVisible && $0.attachedSheet == nil }
    }
}
#endif
