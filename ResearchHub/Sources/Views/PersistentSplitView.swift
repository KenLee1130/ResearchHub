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
        /// 使用者用拖曳把這一欄收起／拉開時通知外面，讓畫面上的開關跟著更新
        var onVisibilityChange: ((Bool) -> Void)? = nil
    }

    /// 存分隔位置用的名字（不同畫面要不同名字）
    let autosaveName: String
    let panes: [Pane]

    func makeNSViewController(context: Context) -> Container {
        Container(split: Controller(autosaveName: autosaveName, panes: panes))
    }

    func updateNSViewController(_ container: Container, context: Context) {
        container.split.update(panes)
    }

    /// 分隔視圖本身不需要內容的寬度——給多少就用多少（見 AdaptiveSizing.swift）
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: Container,
                      context: Context) -> CGSize? {
        proposal.adaptive
    }

    /// 分割視圖＋疊在上面的分隔線高亮層。
    /// 不能用 NSSplitView 子類別自己畫（替換 NSSplitViewController 的 splitView 會閃退），
    /// 所以另外疊一層：不收任何點擊，只負責在滑鼠靠近分隔線時畫藍色。
    final class Container: NSViewController {
        let split: Controller
        private let highlight = DividerHighlightView()

        init(split: Controller) {
            self.split = split
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func loadView() {
            let root = NSView()
            addChild(split)
            split.view.frame = root.bounds
            split.view.autoresizingMask = [.width, .height]
            root.addSubview(split.view)
            highlight.frame = root.bounds
            highlight.autoresizingMask = [.width, .height]
            highlight.splitView = split.splitView
            root.addSubview(highlight)   // 疊在最上面
            view = root
        }
    }

    final class Controller: NSSplitViewController {
        private let autosave: String
        private var hosts: [String: NSHostingController<AnyView>] = [:]
        private var items: [String: NSSplitViewItem] = [:]
        private var initialPanes: [Pane]
        /// 「外面要的」和「實際的」顯示狀態分開記：
        ///   • 只有外面要的狀態**改變**時才去收／展。以前是每次畫面更新都拿外面的狀態
        ///     去對齊實際狀態，使用者用拖曳收起的欄，下一次更新（例如按編譯）就被彈回來。
        ///   • 實際狀態因使用者拖曳而改變時，通知外面（有 onVisibilityChange 的會同步開關）。
        private var desiredVisible: [String: Bool] = [:]
        private var actualVisible: [String: Bool] = [:]
        private var visibilityCallbacks: [String: (Bool) -> Void] = [:]

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
                desiredVisible[pane.id] = pane.isVisible
                actualVisible[pane.id] = pane.isVisible
                visibilityCallbacks[pane.id] = pane.onVisibilityChange
                addSplitViewItem(item)
            }
            // 使用者拖曳造成的收起／展開：回寫給外面
            NotificationCenter.default.addObserver(
                self, selector: #selector(splitResized),
                name: NSSplitView.didResizeSubviewsNotification, object: splitView)
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
                visibilityCallbacks[pane.id] = pane.onVisibilityChange
                guard let item = items[pane.id], desiredVisible[pane.id] != pane.isVisible else { continue }
                desiredVisible[pane.id] = pane.isVisible
                if item.isCollapsed == pane.isVisible {
                    item.isCollapsed = !pane.isVisible   // 收起／展開會保留原本的寬度
                }
            }
        }

        @objc private func splitResized(_ note: Notification) {
            for (id, item) in items {
                let visible = !item.isCollapsed
                guard actualVisible[id] != visible else { continue }
                actualVisible[id] = visible
                // 外面本來就要這樣（程式收起／展開造成的）→ 不用通知
                guard desiredVisible[id] != visible, let callback = visibilityCallbacks[id] else { continue }
                // 不在分割視圖的版面計算中途改 SwiftUI 狀態
                DispatchQueue.main.async { callback(visible) }
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

/// 分隔線高亮層：滑鼠移到可以拖的範圍內（或正在拖）時，在分隔線上畫一條藍色。
/// hitTest 永遠回 nil，所以點擊、拖曳都直接穿透到下面的分割視圖。
final class DividerHighlightView: NSView {
    /// 跟 effectiveRect 的放寬一致：線的兩側各 5pt 都算「在線上」
    static let grabSlop: CGFloat = 5
    private static let barWidth: CGFloat = 3

    weak var splitView: NSSplitView? {
        didSet {
            NotificationCenter.default.removeObserver(self)
            if let splitView {
                // 拖曳時 NSSplitView 自己跑事件迴圈，這裡收不到 mouseMoved——
                // 改聽「欄寬變了」來讓藍線跟著分隔線走
                NotificationCenter.default.addObserver(
                    self, selector: #selector(splitResized),
                    name: NSSplitView.didResizeSubviewsNotification, object: splitView)
            }
        }
    }

    private var litDivider: Int? {
        didSet { if oldValue != litDivider { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 每條看得到的分隔線中心的 x（本視圖座標）
    private var dividerCenters: [CGFloat] {
        guard let splitView else { return [] }
        let visible = splitView.arrangedSubviews.filter { !$0.isHidden && $0.frame.width > 1 }
        return visible.dropLast().map { pane in
            let edge = pane.frame.maxX + splitView.dividerThickness / 2
            return convert(NSPoint(x: edge, y: 0), from: splitView).x
        }
    }

    private func divider(near x: CGFloat) -> Int? {
        dividerCenters.firstIndex { abs($0 - x) <= Self.grabSlop + 1 }
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
        litDivider = divider(near: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseExited(with event: NSEvent) {
        if NSEvent.pressedMouseButtons == 0 { litDivider = nil }
    }

    @objc private func splitResized(_ note: Notification) {
        // 正在拖：保持亮著，位置重新算；放開之後由下一次 mouseMoved 決定
        if NSEvent.pressedMouseButtons != 0, litDivider != nil { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let index = litDivider, index < dividerCenters.count else { return }
        let x = dividerCenters[index]
        NSColor.controlAccentColor.setFill()
        NSRect(x: x - Self.barWidth / 2, y: bounds.minY,
               width: Self.barWidth, height: bounds.height).fill()
    }
}
#endif
