#if os(macOS)
import SwiftUI

/// 格子裡的就地改名欄：出現就自動取得焦點。
/// Enter 或點到別處＝確定（跟 Finder 一樣），Esc＝取消。
struct InlineRenameField: View {
    @Binding var text: String
    let placeholder: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool
    @State private var finished = false

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.callout)
            .multilineTextAlignment(.center)
            .focused($focused)
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onSubmit { finish(commit: true) }
            .onExitCommand { finish(commit: false) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { finish(commit: true) }
            }
    }

    private func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        commit ? onCommit() : onCancel()
    }
}
#endif
