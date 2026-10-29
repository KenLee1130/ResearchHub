import Foundation
import HubEditor
import HubCore
import HubStore

/// Composition root：全 app 唯一允許建立 singleton 的地方（docs/ARCHITECTURE.md 第 1 節守則 3）。
/// 套件裡的型別一律用建構子注入；app 裡要拿共用實例就從這裡拿，不再各自 `static let shared`。
@MainActor
final class AppContainer {
    static let shared = AppContainer()

    /// 整個資料夾的 iCloud 同步與「檔案變了」事件
    let librarySync = LibrarySync()
    /// Zotero 文獻快取（論文頁、\cite 補全共用）
    let zotero = ZoteroStore()
    /// 論文 PDF 全文索引（論文頁搜尋、⌘K 共用；文字來自 Zotero 的索引）
    let paperFulltext: PaperFulltextIndex
    /// 閱讀關卡（iPhone 用；Mac 端寫 focus state 給它讀）
    let readingGate: ReadingGateStore
    /// [[筆記]] 互相引用的索引
    let noteLinks = NoteLinkIndex()
    /// 常駐的 block 編輯器（WKWebView 只建一次）
    let blockEditor = BlockEditorHost()
    /// 推播通知的 delegate（蕃茄鐘、@remind）
    let notificationDelegate = NotificationDelegate()
    #if os(macOS)
    /// ⌘F 尋找列
    let pageFinder = PageFinder()
    /// 最後取得焦點的 markdown 編輯器（插入引用用）
    let activeEditor = ActiveEditorRegistry()
    /// 筆記 → PDF
    let pdfExporter = PDFExporter()
    /// ChatGPT 帳號能選的模型清單
    let paperModels = PaperModelCatalog()
    /// 蕃茄鐘浮動面板
    let pomodoroPanel = PomodoroPanelController()
    #endif

    private init() {
        readingGate = ReadingGateStore(librarySync: librarySync)
        let zotero = zotero
        paperFulltext = PaperFulltextIndex(
            resolve: { item in
                // 一篇有多個附件時 API 不給捷徑，得問 children
                if let key = item.pdfAttachmentKey { return key }
                return await zotero.pdfAttachment(for: item)?.key
            },
            fetch: { key in await zotero.fulltext(attachmentKey: key) })
        // @est 進度條一格 = 一顆蕃茄的分鐘數（蕃茄鐘設定）
        blockEditor.pomoMinutesProvider = {
            let v = UserDefaults.standard.integer(forKey: PomodoroModel.SettingsKey.workMinutes)
            return v > 0 ? v : 25
        }
    }
}
