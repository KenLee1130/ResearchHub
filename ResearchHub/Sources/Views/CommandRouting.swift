#if os(macOS)
import SwiftUI
import HubEditor
import HubStore
import AppKit
import WebKit
import PDFKit
import HubCore

// MARK: - 視窗 ↔ 選單

struct CommandRouterKey: FocusedValueKey { typealias Value = CommandRouter }

extension FocusedValues {
    /// key window 的命令路由（視窗根畫面用 .focusedSceneValue 登記）
    var commandRouter: CommandRouter? {
        get { self[CommandRouterKey.self] }
        set { self[CommandRouterKey.self] = newValue }
    }
}

extension EnvironmentValues {
    /// 這個視窗的命令路由：頁面進場時把自己 push 進去（見 pageCommands）
    @Entry var commandRouter: CommandRouter? = nil
    /// 收起這個視窗的導覽側欄（筆記／LaTeX 彈到獨立視窗後主視窗用不到側欄）
    @Entry var collapseSidebar: (() -> Void)? = nil
}

/// 選單與快捷鍵：只讀 key window 的路由，自己不猜焦點。
/// 尋找列是 NSPanel（不是 SwiftUI scene），它是 key 時路由是 nil → 只把焦點放回尋找列。
struct AppCommands: Commands {
    @FocusedValue(\.commandRouter) private var router

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("新分頁") { router?.handle(.newTab) }
                .keyboardShortcut("t", modifiers: .command)
        }
        CommandGroup(after: .textEditing) {
            // ⌘F：以頁面為範圍找（頁面決定目標，見 EditorHandle.findTarget）；首頁等沒人接 → ⌘K
            Button("在此頁尋找…") {
                if let router { router.handle(.find) } else { AppContainer.shared.pageFinder.refocusIfVisible() }
            }
            .keyboardShortcut("f", modifiers: .command)
            // ⌘K：全 app 搜尋（日記、筆記、LaTeX、論文、待辦），只在 key window 跳出來
            Button("搜尋全部…") { router?.handle(.globalSearch) }
                .keyboardShortcut("k", modifiers: .command)
        }
    }
}

// MARK: - 視窗根畫面登記

/// 視窗的根畫面用：把路由登記成 focusedSceneValue、提供給子畫面、接上退路，
/// 並在這個視窗跳出全 app 搜尋（⌘K；⌘F 沒人接也退到這裡）。
struct WindowCommandsModifier: ViewModifier {
    @Environment(FileSystemStore.self) private var store
    @Environment(GeneralTodoStore.self) private var generalTodos
    let router: CommandRouter
    @Binding var searchPresented: Bool
    var fallback: ((AppCommand) -> Bool)?

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.commandRouter, router)
            .environment(\.commandRouter, router)
            .sheet(isPresented: $searchPresented) {
                SearchPaletteView()
                    .environment(store)
                    .environment(generalTodos)
            }
            .onAppear {
                router.windowFallback = { cmd in
                    if cmd == .globalSearch { searchPresented = true; return true }
                    return fallback?(cmd) ?? false
                }
            }
    }
}

extension View {
    func windowCommands(_ router: CommandRouter, searchPresented: Binding<Bool>,
                        fallback: ((AppCommand) -> Bool)? = nil) -> some View {
        modifier(WindowCommandsModifier(router: router, searchPresented: searchPresented, fallback: fallback))
    }
}

// MARK: - 頁面登記

/// 頁面（或 sheet）進場時把自己 push 進視窗的路由，退場時 pop。
/// `onCommand` 每次 body 都重新指定，所以閉包裡讀到的 @State 永遠是現在的值。
struct PageCommandsModifier: ViewModifier {
    @Environment(\.commandRouter) private var router
    let handler: ClosureCommandHandler

    func body(content: Content) -> some View {
        content
            .onAppear { router?.push(handler) }
            .onDisappear { router?.pop(handler) }
    }
}

extension View {
    func pageCommands(_ handler: ClosureCommandHandler,
                      _ onCommand: @escaping (AppCommand) -> Bool) -> some View {
        handler.onCommand = onCommand
        return modifier(PageCommandsModifier(handler: handler))
    }
}

// MARK: - 頁面握著編輯器的把手

/// 頁面持有、交給 EditorCore 與各 representable 填：頁面靠它決定 ⌘F 找哪裡、要求存檔、附加文字。
/// 取代以前的 EditorCore.saveNow／append 通知與 PageFinder 的「畫面上最大那塊」猜法。
@MainActor
final class EditorHandle {
    weak var textView: NSTextView?
    weak var previewWebView: WKWebView?
    weak var pdfView: PDFView?
    /// 區塊模式：目標是共用的 BlockEditorHost webView
    var usesBlockEditor = false

    /// 目前掛著的 EditorCore（換檔／重建時用來判斷閉包是不是自己的）
    var owner: UUID?
    var saveNow: (() -> Void)?
    var append: ((String) -> Void)?

    /// ⌘F 的目標：焦點所在的那塊 > 看得到的（原始碼 > PDF > 預覽 > 區塊編輯器）
    func findTarget() -> NSView? {
        let blocks: NSView? = usesBlockEditor ? AppContainer.shared.blockEditor.webView : nil
        let visible = [textView, pdfView, previewWebView, blocks].compactMap { $0 }.filter(Self.isShowing)
        if let focused = visible.first(where: { v in
            (v.window?.firstResponder as? NSView)?.isDescendant(of: v) ?? false
        }) { return focused }
        return visible.first
    }

    static func isShowing(_ view: NSView) -> Bool {
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return false }
        let r = view.visibleRect
        return r.width * r.height > 100
    }
}
#endif
