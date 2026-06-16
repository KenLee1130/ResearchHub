import AppKit

/// 一筆補全建議。display = 清單上顯示的文字；insert = 接受時實際插入（cite 是 Zotero key）。
struct CompletionItem {
    let display: String
    let insert: String
    enum Kind { case command, cite, env, eqref, noteLink }
    let kind: Kind
}

/// Overleaf 式浮動補全清單：非啟用面板（不搶焦點），由編輯器用方向鍵/Tab 控制，
/// 滑鼠也可點選。不會像系統補全那樣強制把建議插進文字。
@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private let scroll = NSScrollView()

    private(set) var items: [CompletionItem] = []
    private(set) var selectedIndex = 0
    var onAccept: ((CompletionItem) -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
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

        panel.contentView = glass
    }

    var isVisible: Bool { panel.isVisible }

    func show(items: [CompletionItem], below caretRect: NSRect, parent: NSWindow) {
        self.items = items
        if selectedIndex >= items.count { selectedIndex = 0 }
        table.reloadData()

        let rowH = table.rowHeight + table.intercellSpacing.height
        let visible = min(max(items.count, 1), 9)
        let height = CGFloat(visible) * rowH + 6
        let width: CGFloat = 380
        let frame = NSRect(x: caretRect.minX,
                           y: caretRect.minY - height - 2,
                           width: width, height: height)
        panel.setFrame(frame, display: false)
        if let cv = panel.contentView { scroll.frame = cv.bounds; scroll.autoresizingMask = [.width, .height] }

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
        field.stringValue = items[row].display
        return field
    }
}
