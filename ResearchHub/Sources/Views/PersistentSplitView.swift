#if os(macOS)
import SwiftUI
import AppKit

/// 可拖曳、會記住位置的左右分割視圖（包 AppKit 的 NSSplitViewController）。
///
/// 為什麼不用 SwiftUI 的 HSplitView：
///   1. 它不記分隔位置，而且子畫面內容一變（例如檔案樹多了一個改名欄）就重新分配寬度——
///      使用者拖好的版面會自己跑掉。
///   2. 分隔線的粗細與可抓取範圍沒有 API 可調，1pt 的線很難剛好抓到。
/// 位置只記「使用者拖的那一下」（見 Controller 的 Layout 段），視窗大小變了再照記住的
/// 比例重排；抓取範圍在 effectiveRect 裡往兩側放寬，線本身維持細的。
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
        /// 上次排版時分割視圖的寬度與看得到的欄：其中一個變了才重排
        private var lastLayoutWidth: CGFloat = 0
        private var lastVisiblePanes: [String] = []
        private var applyScheduled = false
        /// 正在用程式設分隔線：這時候的欄寬變化不能當成使用者拖的存起來（保險）
        private var isApplying = false

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
            // 不用 splitView.autosaveName：NSSplitView 每次縮放都會存，新視窗先以小尺寸排版時
            // 欄被壓到最小寬度，放大時又等比例長大 → 存下來的就是被壓扁的版面
            // （2026-10-14：筆記分頁的原始碼欄一直只剩 150pt）。
        }

        override func viewDidAppear() {
            super.viewDidAppear()
            scheduleApply()
        }

        override func viewDidLayout() {
            super.viewDidLayout()
            // 收起／展開後，要到這次排版欄的 frame 才是新的 → 以這裡為準重排
            let width = splitView.bounds.width
            let visible = initialPanes.map(\.id).filter { items[$0]?.isCollapsed == false }
            guard width > 0, abs(width - lastLayoutWidth) > 0.5 || visible != lastVisiblePanes
            else { return }
            lastLayoutWidth = width
            lastVisiblePanes = visible
            scheduleApply()
        }

        // MARK: - Layout：只記使用者拖的位置，尺寸變了就照記住的版面重排
        //
        // 規則跟 holdingPriority 一致：「不想動」的欄（檔案樹、論文清單、對話欄）維持記住的
        // 寬度；其餘的欄照記住的寬度比例分剩下的空間。沒記過的欄：前者用 initialWidth，
        // 後者平均分。

        private var storageKey: String { "PersistentSplitView.\(autosave)" }

        private var savedWidths: [String: Double] {
            get {
                if let saved = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Double] {
                    return saved
                }
                return migratedWidths()
            }
            set { UserDefaults.standard.set(newValue, forKey: storageKey) }
        }

        /// 舊版存在 NSSplitView autosave 裡的位置（"x, y, 寬, 高, 收起, 隱藏"，依欄順序）。
        /// 有欄剛好是最小寬度＝當初被壓扁時存的，不搬，回到預設版面。
        private func migratedWidths() -> [String: Double] {
            guard let frames = UserDefaults.standard.array(
                forKey: "NSSplitView Subview Frames \(autosave)") as? [String],
                  frames.count == initialPanes.count else { return [:] }
            var result: [String: Double] = [:]
            for (pane, frame) in zip(initialPanes, frames) {
                let parts = frame.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 5, let width = Double(parts[2]) else { return [:] }
                if parts[4] == "YES" || width < 1 { continue }   // 收起的欄沒有寬度可搬
                if !Self.isHeld(pane), width <= Double(pane.minWidth) + 1 { return [:] }
                result[pane.id] = width
            }
            return result
        }

        /// 視窗縮放時維持寬度的欄（檔案樹、論文清單、對話欄）
        private static func isHeld(_ pane: Pane) -> Bool {
            pane.holdingPriority.rawValue > NSLayoutConstraint.Priority.defaultLow.rawValue
        }

        private func scheduleApply() {
            guard !applyScheduled else { return }
            applyScheduled = true
            // 不在版面計算途中動分隔線（會重入 SwiftUI 的更新，見 c610ec9 的卡死）
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                applyScheduled = false
                applySavedLayout()
            }
        }

        private func applySavedLayout() {
            splitView.layoutSubtreeIfNeeded()   // 剛展開的欄 frame 可能還沒更新
            let visible = initialPanes.enumerated().filter { items[$0.element.id]?.isCollapsed == false }
            guard visible.count > 1 else { return }
            let saved = savedWidths
            let available = splitView.bounds.width
                - splitView.dividerThickness * CGFloat(visible.count - 1)
            let isHeld = Self.isHeld
            var widths: [String: CGFloat] = [:]
            var flexWeight: CGFloat = 0
            for (_, pane) in visible {
                if isHeld(pane) {
                    let w = saved[pane.id].map { CGFloat($0) } ?? pane.initialWidth
                        ?? hosts[pane.id]?.view.frame.width ?? pane.minWidth
                    widths[pane.id] = max(pane.minWidth, w)
                } else {
                    flexWeight += CGFloat(saved[pane.id] ?? 1)
                }
            }
            let flexSpace = available - widths.values.reduce(0, +)
            for (_, pane) in visible where !isHeld(pane) {
                let share = flexWeight > 0 ? CGFloat(saved[pane.id] ?? 1) / flexWeight : 0
                widths[pane.id] = flexSpace * share
            }
            // 塞不下（視窗太窄）就交給 NSSplitView 自己依最小寬度處理
            guard visible.allSatisfy({ widths[$0.element.id, default: 0] >= $0.element.minWidth })
            else { return }

            isApplying = true
            defer { isApplying = false }
            for (k, entry) in visible.dropLast().enumerated() {
                let pane = entry.element
                guard let view = hosts[pane.id]?.view, let target = widths[pane.id] else { continue }
                guard abs(view.frame.width - target) > 1 else { continue }
                // 分隔線＝下一個看得到的欄左邊那條
                let nextIndex = visible[k + 1].offset
                splitView.setPosition(view.frame.minX + target, ofDividerAt: nextIndex - 1)
                splitView.layoutSubtreeIfNeeded()   // 下一欄的 minX 要是更新後的
            }
        }

        /// 這次欄寬改變是不是使用者在拖分隔線。
        /// 「NSSplitViewDividerIndex」不夠：NSSplitViewController 自己排版、縮放視窗也會帶，
        /// 實測會存到全部最小寬度。實測只有使用者拖曳時才另外帶「NSSplitViewUserResizeKey」
        /// （AppKit 沒寫進文件；萬一哪天拿掉了，結果只是拖了不記，不會存錯）。
        private func isUserDraggingDivider(_ note: Notification) -> Bool {
            guard !isApplying else { return false }
            return (note.userInfo?["NSSplitViewUserResizeKey"] as? NSNumber)?.boolValue == true
        }

        /// 使用者拖完分隔線：記下每個看得到的欄的寬度（收起的欄保留上次的）
        private func saveCurrentWidths() {
            var saved = savedWidths
            for pane in initialPanes {
                guard let item = items[pane.id], !item.isCollapsed else { continue }
                saved[pane.id] = Double(item.viewController.view.frame.width)
            }
            savedWidths = saved
        }

        func update(_ panes: [Pane]) {
            var changed = false
            for pane in panes {
                hosts[pane.id]?.rootView = pane.content
                visibilityCallbacks[pane.id] = pane.onVisibilityChange
                guard items[pane.id] != nil, desiredVisible[pane.id] != pane.isVisible else { continue }
                desiredVisible[pane.id] = pane.isVisible
                changed = true
            }
            // ⚠️ 不能在這裡（SwiftUI 更新途中）直接收起：被收起的欄如果含有游標（例如正在打字的
            // 原始碼），AppKit 會去找下一個可聚焦的 view → 回頭問 SwiftUI 的焦點樹 → 重入正在
            // 更新的 view graph → 無限循環，app 卡死（2026-10-01 hang report：按「只看 PDF」）。
            if changed {
                DispatchQueue.main.async { [weak self] in self?.applyDesiredVisibility() }
            }
        }

        /// 把實際的收／展對齊外面要的狀態。先展開再收起，避免中途所有欄都收起來。
        private func applyDesiredVisibility() {
            let order = initialPanes.map(\.id)
            for expanding in [true, false] {
                for id in order {
                    guard let item = items[id], let want = desiredVisible[id],
                          want == expanding, item.isCollapsed == want else { continue }
                    if !want { resignFocus(inside: item.viewController.view) }
                    item.isCollapsed = !want   // 收起／展開會保留原本的寬度
                }
            }
        }

        /// 游標在要收起的欄裡 → 先交還給視窗，AppKit 就不必去找「下一個」可聚焦的 view
        private func resignFocus(inside pane: NSView) {
            guard let window = pane.window,
                  let responder = window.firstResponder as? NSView,
                  responder.isDescendant(of: pane) else { return }
            window.makeFirstResponder(nil)
        }

        @objc private func splitResized(_ note: Notification) {
            if isUserDraggingDivider(note) { saveCurrentWidths() }
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
