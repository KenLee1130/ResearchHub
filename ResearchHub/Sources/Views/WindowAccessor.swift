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

/// 把這個畫面所在的 NSWindow 交出去（用來判斷鍵盤事件是不是自己這個視窗的）。
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}

/// 把這塊畫面對應的 NSView 交出去（用來判斷鍵盤焦點是不是落在這一區裡面）。
struct ViewProbe: NSViewRepresentable {
    let onView: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onView(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// NavigationSplitView 側欄的寬度控制。
///
/// 側欄寬度**只**由右緣的自訂把手（SidebarResizeHandle）決定：系統原生的分隔線鎖死不能拖。
/// 原因：兩套同時存在時會互搶——原生分隔線會把邊緣幾 pt 的點擊攔走、SwiftUI 的
/// navigationSplitViewColumnWidth 又常常不套用新寬度，結果「游標變了卻拖不動」；
/// 原生的還會在拖太窄時把整個側欄收掉。
///
/// SwiftUI 沒有這些選項，所以往下找它內部的 NSSplitViewController 直接設。
/// 鎖住之後程式也收不起側欄——所以按左上角按鈕要收的那一刻先呼叫 allowCollapse。
@MainActor
enum SidebarSplitControl {
    /// 把側欄設成這個寬度並鎖住（min = max，原生分隔線就拖不動）
    static func lock(in window: NSWindow?, width: CGFloat) {
        guard let (split, item) = sidebar(in: window) else { return }
        if item.canCollapse { item.canCollapse = false }
        if item.minimumThickness != width { item.minimumThickness = width }
        if item.maximumThickness != width { item.maximumThickness = width }
        if abs(item.viewController.view.frame.width - width) > 0.5 {
            split.setPosition(width, ofDividerAt: 0)
        }
    }

    static func allowCollapse(in window: NSWindow?) {
        guard let (_, item) = sidebar(in: window) else { return }
        item.minimumThickness = 0
        item.canCollapse = true
    }

    /// 由外往內找第一個「側欄型」的分割項目。
    /// 用 behavior == .sidebar 辨認，才不會抓到 LaTeX 專案、筆記編輯器裡的 PersistentSplitView。
    private static func sidebar(in window: NSWindow?) -> (NSSplitView, NSSplitViewItem)? {
        guard let root = window?.contentView else { return nil }
        var queue: [NSView] = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let split = view as? NSSplitView,
               let controller = split.delegate as? NSSplitViewController,
               let first = controller.splitViewItems.first, first.behavior == .sidebar {
                return (split, first)
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}
#endif
