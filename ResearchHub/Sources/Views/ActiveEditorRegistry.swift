#if os(macOS)
import SwiftUI
import HubCore
import AppKit

/// 記住最後取得焦點的 markdown 編輯器，讓「插入引用」能把 \cite{...} 插到游標處
/// （即使焦點已移到引用挑選視窗，selectedRange 仍保留）。
final class ActiveEditorRegistry {
    static let shared = ActiveEditorRegistry()
    weak var textView: NSTextView?

    /// 把文字插到目前作用中的編輯器游標處（取代選取範圍）。
    func insert(_ string: String) {
        guard let tv = textView else { return }
        tv.insertText(string, replacementRange: tv.selectedRange())
    }
}
#endif
