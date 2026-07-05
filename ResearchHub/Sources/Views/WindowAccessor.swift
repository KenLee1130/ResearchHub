#if os(macOS)
import SwiftUI
import AppKit

/// 直接抓底層 NSWindow,把最小尺寸釘死,並在視窗比最小還小時立刻撐大。
///
/// 為什麼需要「撐大」:macOS 會記住視窗上次的大小,下次開啟時還原。如果之前被縮到
/// 很小(例如 530 寬),光設 `contentMinSize` 並不會把已經太小的視窗變大 —— 它只擋
/// 未來的縮放。於是每次打開都還原成那個太小的尺寸、側欄一樣被切掉,看起來「一模一樣」。
/// 這裡在掛上視窗的瞬間(`viewDidMoveToWindow`)設定最小尺寸,並主動把過小的視窗撐到最小。
struct WindowMinSizeSetter: NSViewRepresentable {
    let minWidth: CGFloat
    let minHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        Tracker(minWidth: minWidth, minHeight: minHeight)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Tracker)?.apply()
    }

    final class Tracker: NSView {
        private let minW: CGFloat
        private let minH: CGFloat

        init(minWidth: CGFloat, minHeight: CGFloat) {
            self.minW = minWidth
            self.minH = minHeight
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            // 同步先做一次。
            enforce()
            // 再延後一個 runloop 做一次:SwiftUI 的 frame autosave 會在我們之後把視窗
            // 還原成記憶中的舊尺寸,把同步那次蓋掉;延後這次跑在還原之後,才壓得過它。
            DispatchQueue.main.async { [weak self] in self?.enforce() }
        }

        private func enforce() {
            guard let window else { return }
            let minSize = NSSize(width: minW, height: minH)
            window.contentMinSize = minSize
            window.minSize = minSize

            // 若目前內容區比最小還小,立刻撐大到最小(處理「還原成舊的小尺寸」的情況)。
            let content = window.contentRect(forFrameRect: window.frame).size
            if content.width < minW - 0.5 || content.height < minH - 0.5 {
                window.setContentSize(NSSize(width: max(content.width, minW),
                                             height: max(content.height, minH)))
            }
        }
    }
}
#endif
