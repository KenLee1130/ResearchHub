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
            splitView = HoverSplitView()   // 滑鼠移上去／拖曳時分隔線變藍
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
            drawnRect.insetBy(dx: -HoverSplitView.grabSlop, dy: 0)
        }
    }
}

/// 分隔線：平常是一條細灰線，滑鼠移到可以拖的範圍內（或正在拖）時整條變成藍色，
/// 一看就知道「這裡可以拉」。
final class HoverSplitView: NSSplitView {
    /// 分隔線兩側各多幾 pt 算「在線上」（跟 effectiveRect 的放寬一致）
    static let grabSlop: CGFloat = 5

    private var hoveredDivider: NSRect? {
        didSet { if oldValue != hoveredDivider { needsDisplay = true } }
    }
    private var dragging = false {
        didSet { needsDisplay = true }
    }
    private var tracking: NSTrackingArea?

    // 3pt：平常只在中間畫 1pt 的線，另外 2pt 透出底色，看起來還是細線；
    // 變藍時整條 3pt 一起亮，才看得清楚
    override var dividerThickness: CGFloat { 3 }

    override func drawDivider(in rect: NSRect) {
        if dragging || hoveredDivider.map({ abs($0.midX - rect.midX) < 1 }) == true {
            NSColor.controlAccentColor.setFill()
            rect.fill()
        } else {
            NSColor.separatorColor.setFill()
            NSRect(x: rect.midX - 0.5, y: rect.minY, width: 1, height: rect.height).fill()
        }
    }

    /// 目前看得到的每條分隔線的位置（收起來的欄旁邊那條不算）
    private var dividerRects: [NSRect] {
        let visible = arrangedSubviews.filter { !$0.isHidden && $0.frame.width > 0 }
        return visible.dropLast().map {
            NSRect(x: $0.frame.maxX, y: bounds.minY, width: dividerThickness, height: bounds.height)
        }
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        hoveredDivider = dividerRects.first {
            $0.insetBy(dx: -Self.grabSlop, dy: 0).contains(point)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredDivider = nil
    }

    // NSSplitView 的拖曳是在 mouseDown 裡自己跑迴圈，放開滑鼠才回來——
    // 所以前後各設一次，拖的整段時間都維持藍色
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let onDivider = dividerRects.contains {
            $0.insetBy(dx: -Self.grabSlop, dy: 0).contains(point)
        }
        if onDivider { dragging = true }
        super.mouseDown(with: event)
        if onDivider {
            dragging = false
            hoveredDivider = nil
        }
    }
}
#endif
