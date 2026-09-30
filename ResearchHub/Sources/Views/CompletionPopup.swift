#if os(macOS)
import AppKit

/// 一筆補全建議。display = 清單上顯示的文字；insert = 接受時實際插入（cite 是 Zotero key）。
struct CompletionItem {
    let display: String
    let insert: String
    /// 參數補全：texFile＝\input{、image＝\includegraphics{、package＝\usepackage{、
    /// docClass＝\documentclass{、bibFile＝\bibliography{
    enum Kind { case command, cite, env, eqref, noteLink, texFile, image, package, docClass, bibFile }
    let kind: Kind
    /// 清單上跟在後面的灰字（指令說明、符號長相）
    var detail: String = ""
}

/// Overleaf 式浮動補全清單：非啟用面板（不搶焦點），由編輯器用方向鍵/Tab 控制，
/// 滑鼠也可點選。不會像系統補全那樣強制把建議插進文字。
@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private let scroll = NSScrollView()
    /// 清單上方的一行灰字（例如 \cite 的搜尋說明）；沒有就不佔空間
    private let hintLabel = NSTextField(labelWithString: "")
    private static let hintHeight: CGFloat = 20

    private(set) var items: [CompletionItem] = []
    private(set) var selectedIndex = 0
    var onAccept: ((CompletionItem) -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        super.init()

        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false

        let glass = NSVisualEffectView()
        glass.material = .menu
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 8
        glass.layer?.masksToBounds = true
        glass.addSubview(scroll)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        glass.addSubview(hintLabel)

        panel.contentView = glass
    }

    var isVisible: Bool { panel.isVisible }

    func show(items: [CompletionItem], hint: String? = nil,
              below caretRect: NSRect, parent: NSWindow) {
        // 內容換了（例如多打一個字篩選）就回到第一筆：最符合的在最上面
        if items.map(\.insert) != self.items.map(\.insert) { selectedIndex = 0 }
        self.items = items
        if selectedIndex >= items.count { selectedIndex = 0 }
        table.reloadData()

        let rowH = table.rowHeight + table.intercellSpacing.height
        let visible = min(items.count, 9)
        let hintH = (hint ?? "").isEmpty ? 0 : Self.hintHeight
        let height = CGFloat(visible) * rowH + 6 + hintH
        let width: CGFloat = hintH > 0 ? 560 : 440   // 文獻標題長，給寬一點
        let frame = NSRect(x: caretRect.minX,
                           y: caretRect.minY - height - 2,
                           width: width, height: height)
        panel.setFrame(frame, display: false)
        if let cv = panel.contentView {
            // AppKit 座標原點在左下：提示列在最上面，清單在它下面
            hintLabel.isHidden = hintH == 0
            hintLabel.stringValue = hint ?? ""
            hintLabel.frame = NSRect(x: 8, y: cv.bounds.height - hintH + 2,
                                     width: cv.bounds.width - 16, height: hintH - 4)
            scroll.frame = NSRect(x: 0, y: 0, width: cv.bounds.width,
                                  height: cv.bounds.height - hintH)
            scroll.autoresizingMask = []
        }

        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        selectRow(selectedIndex)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func move(by delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + items.count) % items.count
        selectRow(selectedIndex)
    }

    func acceptSelected() {
        guard items.indices.contains(selectedIndex) else { return }
        onAccept?(items[selectedIndex])
    }

    private func selectRow(_ i: Int) {
        guard items.indices.contains(i) else { return }
        table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    @objc private func clicked() {
        let r = table.clickedRow
        guard items.indices.contains(r) else { return }
        selectedIndex = r
        acceptSelected()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let tf = NSTextField(labelWithString: "")
            tf.identifier = id
            tf.lineBreakMode = .byTruncatingTail
            tf.font = .systemFont(ofSize: 12)
            tf.drawsBackground = false
            return tf
        }()
        let item = items[row]
        if item.detail.isEmpty {
            field.stringValue = item.display
        } else {
            let text = NSMutableAttributedString(
                string: item.display,
                attributes: [.font: NSFont.systemFont(ofSize: 12),
                             .foregroundColor: NSColor.labelColor])
            text.append(NSAttributedString(
                string: "   " + item.detail,
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor]))
            field.attributedStringValue = text
        }
        return field
    }
}
#endif
