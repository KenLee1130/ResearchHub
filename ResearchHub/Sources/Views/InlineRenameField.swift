#if os(macOS)
import SwiftUI
import AppKit

/// 就地改名欄：出現就自動取得焦點。
/// Enter 或點到別處＝確定（跟 Finder 一樣），Esc＝取消。
///
/// 用 AppKit 的 NSTextField 而不是 SwiftUI TextField + @FocusState：
/// 在有 selection 綁定的 List 裡（LaTeX 專案的檔案樹），List 會把 first responder
/// 留給自己處理選取，剛插入的那一列上 @FocusState 常常搶不到焦點——
/// 結果欄位跳出來了卻打不了字。這裡直接 makeFirstResponder，行為才確定。
struct InlineRenameField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onCommit: () -> Void
    let onCancel: () -> Void
    /// 格狀檢視（筆記瀏覽）置中，清單檢視（檔案樹）靠左
    var centered = true

    /// 寬度照給的（見 AdaptiveSizing.swift）；高度用文字欄本身的高度
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 120, height: nsView.intrinsicContentSize.height)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.alignment = centered ? .center : .left
        field.lineBreakMode = .byTruncatingTail
        field.cell?.sendsActionOnEndEditing = false
        context.coordinator.grabFocus(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // 只有在不是使用者正在打字時才回寫，免得游標被打斷
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineRenameField
        private var finished = false

        init(_ parent: InlineRenameField) { self.parent = parent }

        /// List 會在同一個 runloop 之後把焦點收回去，所以多試幾次才穩。
        func grabFocus(_ field: NSTextField) {
            for delay in [0.0, 0.05, 0.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak field] in
                    guard let field, let window = field.window else { return }
                    guard window.firstResponder !== field.currentEditor() else { return }
                    window.makeFirstResponder(field)
                    field.currentEditor()?.selectedRange = NSRange(
                        location: 0, length: field.stringValue.count)
                }
            }
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ note: Notification) {
            finish(commit: true)      // 點到別處＝確定，跟 Finder 一樣
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                finish(commit: true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finish(commit: false)
                return true
            default:
                return false
            }
        }

        private func finish(commit: Bool) {
            guard !finished else { return }
            finished = true
            let action = commit ? parent.onCommit : parent.onCancel
            // 收尾會改動 SwiftUI 狀態（拆掉這個欄位），延到下一輪再做比較安全
            DispatchQueue.main.async(execute: action)
        }
    }
}
#endif
