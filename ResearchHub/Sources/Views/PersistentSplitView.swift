#if os(macOS)
import SwiftUI
import AppKit

/// 可拖曳、會記住位置的左右分割視圖（包 AppKit 的 NSSplitViewController）。
///
/// 為什麼不用 SwiftUI 的 HSplitView：
///   1. 它不記分隔位置，而且子畫面內容一變（例如檔案樹多了一個改名欄）就重新分配寬度——
///      使用者拖好的版面會自己跑掉。
///   2. 分隔線的粗細與可抓取範圍沒有 API 可調，1pt 的線很難剛好抓到。
/// NSSplitView 只有在使用者拖的時候才動分隔線，位置用 autosaveName 存起來；
/// 抓取範圍在 effectiveRect 裡往兩側放寬，線本身維持細的。
struct PersistentSplitView: NSViewControllerRepresentable {
    struct Pane {
        let id: String
        var minWidth: CGFloat
        /// 第一次開（還沒有存過的位置）時的寬度；nil＝平均分
        var initialWidth: CGFloat?
        /// 視窗縮放時誰先變：數字越大越「不想動」（檔案樹要大，編輯區／預覽要小）
        var holdingPriority: NSLayoutConstraint.Priority = .defaultLow
        var isVisible: Bool = true
        let content: AnyView
    }

    /// 存分隔位置用的名字（不同畫面要不同名字）
    let autosaveName: String
    let panes: [Pane]

    func makeNSViewController(context: Context) -> Controller {
        Controller(autosaveName: autosaveName, panes: panes)
    }

    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.update(panes)
    }

    /// 分隔視圖本身不需要內容的寬度——給多少就用多少（見 AdaptiveSizing.swift）
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: Controller,
                      context: Context) -> CGSize? {
        proposal.adaptive
    }

    final class Controller: NSSplitViewController {
        private let autosave: String
        private var hosts: [String: NSHostingController<AnyView>] = [:]
        private var items: [String: NSSplitViewItem] = [:]
        private var initialPanes: [Pane]

        init(autosaveName: String, panes: [Pane]) {
            self.autosave = autosaveName
            self.initialPanes = panes
            super.init(nibName: nil, bundle: nil)
            // ⚠️ 不能替換 splitView（連空白的 NSSplitView 子類別都會在 viewDidLoad 當掉，
            // 2026-09-24 實測閃退）。分隔線的外觀要改只能另想辦法。
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidLoad() {
            super.viewDidLoad()
            splitView.isVertical = true
            for pane in initialPanes {
                let host = NSHostingController(rootView: pane.content)
                // 不要讓 SwiftUI 內容的理想大小變成約束——那會跟分隔線搶寬度
                host.sizingOptions = []
                let item = NSSplitViewItem(viewController: host)
                item.minimumThickness = pane.minWidth
                item.holdingPriority = pane.holdingPriority
                item.canCollapse = true
                item.isCollapsed = !pane.isVisible
                hosts[pane.id] = host
                items[pane.id] = item
                addSplitViewItem(item)
            }
            // 放在加完 item 之後：有存過的位置會在這時候套回來
            splitView.autosaveName = autosave
        }

        override func viewDidAppear() {
            super.viewDidAppear()
            applyInitialWidthsIfNeeded()
        }

        /// 第一次開、還沒有存過位置時，套用每欄指定的初始寬度
        private func applyInitialWidthsIfNeeded() {
            let key = "NSSplitView Subview Frames \(autosave)"
            guard UserDefaults.standard.object(forKey: key) == nil else { return }
            var x: CGFloat = 0
            var dividerIndex = 0
            for pane in initialPanes {
                defer { dividerIndex += 1 }
                guard let width = pane.initialWidth,
                      dividerIndex < splitViewItems.count - 1,
                      items[pane.id]?.isCollapsed == false else { continue }
                x += width
                splitView.setPosition(x, ofDividerAt: dividerIndex)
                x += splitView.dividerThickness
            }
        }

        func update(_ panes: [Pane]) {
            for pane in panes {
                hosts[pane.id]?.rootView = pane.content
                if let item = items[pane.id], item.isCollapsed == pane.isVisible {
                    item.isCollapsed = !pane.isVisible   // 收起／展開會保留原本的寬度
                }
            }
        }

        // 線很細，但抓取範圍往兩側放寬
        override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                                forDrawnRect drawnRect: NSRect,
                                ofDividerAt dividerIndex: Int) -> NSRect {
            drawnRect.insetBy(dx: -5, dy: 0)
        }
    }
}

#endif
