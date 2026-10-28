#if os(macOS)
import SwiftUI
import HubCore
import HubStore
import AppKit

/// 左欄源碼編輯器：NSTextView 包裝，Overleaf 式多色語法高亮，
/// 可接收右欄預覽雙擊段落後的跳轉請求（SourceJumpRequest）。
/// 配色：定界符（$、$$、\[、\(）橘、數學內容紫、指令藍、
/// 環境名與指令第一個 {…} 參數綠、標題粗體、checkbox 橘。
/// 支援 Cmd+V 貼上圖片的 NSTextView：圖片交給 onPasteImage 存檔，插入回傳的 markdown。
public final class PastingTextView: NSTextView {
    public var onPasteImage: ((NSImage) -> String?)?
    /// LaTeX 專案的根目錄。有值時補全會多出專案才有意義的指令，
    /// 以及 \input{ 列檔案、\ref{ 列整個專案的 label 等（見 LatexProjectIndex）。
    public var completionRoot: URL?

    /// Shift+Return。LaTeX 專案拿來當「編譯」。
    /// 直接攔 keyDown：AppKit 的標準鍵綁定沒有把 Shift+Return 對到 insertLineBreak:，
    /// 它會跟一般 Return 一樣走 insertNewline:，所以改不了行為。
    public var onShiftReturn: (() -> Void)?

    /// 補全用的相依（由 SourceTextView 從 app 轉交；沒給就沒有 \cite／[[ 補全）
    public var zotero: ZoteroStore?
    public var noteLinks: NoteLinkIndex?
    /// 取得焦點時登記自己（插入引用要知道游標在哪個編輯器）
    public var activeEditor: ActiveEditorRegistry?

    // MARK: - 拖曳選取自己來：拖曳中按的鍵不能掉
    //
    // NSTextView 內建的滑鼠追蹤迴圈一收到按鍵就結束追蹤；用三指拖移時「放開」是系統延後合成的，
    // 使用者常在那個空檔就按下 ⌘C／delete，結果那一下在交接處消失（2026-10-22 紀錄：
    // WindowServer 有送到 app，app 的事件入口卻沒收到；第二下才正常）。
    // 這裡只接手最單純的「單擊拖曳選取」：拖曳中收到的按鍵先存起來，選取完成後再送出去，
    // 所以 ⌘C 會複製到完整的選取、delete 會刪掉完整的選取。雙擊／三擊、Shift 等修飾鍵、
    // 點在既有選取上（可能要拖曳文字）、點到連結、輸入法組字中：維持交給系統。
    public override func mouseDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let sel = selectedRange()
        let onLink = index < (string as NSString).length
            && textStorage?.attribute(.link, at: index, effectiveRange: nil) != nil
        guard event.clickCount == 1, mods.isEmpty, let window, isSelectable, !hasMarkedText(),
              !(sel.length > 0 && NSLocationInRange(index, sel)), !onLink
        else {
            super.mouseDown(with: event)
            return
        }

        if window.firstResponder !== self { window.makeFirstResponder(self) }
        let anchor = index
        setSelectedRange(NSRange(location: anchor, length: 0))
        var dragged = false
        var pendingKeys: [NSEvent] = []
        func range(to i: Int) -> NSRange { NSRange(location: min(anchor, i), length: abs(i - anchor)) }
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                           timeout: NSEvent.foreverDuration, mode: .eventTracking) { ev, stop in
            guard let ev else { stop.pointee = true; return }
            switch ev.type {
            case .leftMouseDragged:
                dragged = true
                autoscroll(with: ev)
                let i = characterIndexForInsertion(at: convert(ev.locationInWindow, from: nil))
                setSelectedRange(range(to: i), affinity: i < anchor ? .upstream : .downstream,
                                 stillSelecting: true)
            case .leftMouseUp:
                let i = characterIndexForInsertion(at: convert(ev.locationInWindow, from: nil))
                setSelectedRange(dragged ? range(to: i) : NSRange(location: anchor, length: 0),
                                 affinity: i < anchor ? .upstream : .downstream, stillSelecting: false)
                stop.pointee = true
            case .keyDown:
                pendingKeys.append(ev)   // 拖曳中按的：等選取完成再送
            default:
                break
            }
        }
        for key in pendingKeys { NSApp.sendEvent(key) }
    }

    public override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let onShiftReturn,
           event.keyCode == 36,                       // Return
           flags.contains(.shift),
           flags.isDisjoint(with: [.command, .option, .control]),
           !hasMarkedText() {                         // 輸入法組字中不攔
            onShiftReturn()
            return
        }
        super.keyDown(with: event)
    }

    /// 從別的 app 切回來時，第一下點擊就直接放游標、可以馬上打字
    /// （預設行為是第一下只啟動視窗、被吃掉）。
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { activeEditor?.textView = self }
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        completionPopup.hide()   // 點到別處時關掉浮動清單
        return super.resignFirstResponder()
    }

    // 浮動清單是掛在視窗上的子視窗：擁有它的編輯器被移除（換版面、換檔案、彈出視窗）時，
    // 如果不主動關，它會一直掛在畫面上，而且再也沒有人會去關它。
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            completionPopup.hide()
            if let old = window {
                NotificationCenter.default.removeObserver(
                    self, name: NSWindow.didResignKeyNotification, object: old)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // 切到別的視窗時編輯器本身沒有失去焦點（resignFirstResponder 不會被叫），也要關
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowResignedKey),
            name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowResignedKey(_ note: Notification) {
        completionPopup.hide()
    }

    // MARK: - 剪下／拷貝／貼上／全選：自己接手，不靠選單轉送
    //
    // 使用者回報筆記源碼區選字後 ⌘C 複製不到（2026-09-22），靜態查不出攔截點；
    // 改成文字區是焦點時直接處理這四個快捷鍵後就正常了。

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘/：切換 % 註解。用實體鍵位（44＝/）判斷：注音輸入法下字元不是「/」
        if mods == [.command], event.keyCode == 44 || event.charactersIgnoringModifiers == "/",
           completionRoot != nil, window?.firstResponder === self, !hasMarkedText() {
            // 按住稍久會送出重複按鍵：第二下又把註解拿掉，看起來像沒反應／閃一下
            if !event.isARepeat { toggleLineComments() }
            return true
        }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard mods == [.command], ["c", "x", "v", "a"].contains(key),
              window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "c": copy(nil)
        case "x": cut(nil)
        case "v": paste(nil)
        default: selectAll(nil)
        }
        return true
    }

    // MARK: - 各 extension 用的狀態（儲存屬性不能放 extension）
    public var completionRange = NSRange(location: 0, length: 0)
    public var suppressCompletionOnce = false

    public lazy var completionPopup: CompletionPopup = {
        let p = CompletionPopup()
        p.onAccept = { [weak self] item in self?.acceptCompletion(item) }
        return p
    }()
}
#endif

