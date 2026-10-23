# ResearchHub 架構

> 定稿日期：2026-10-23。這份文件是之後每個 PR 的對照表：改動歸哪個套件、
> 能不能 import 這個框架、快捷鍵該走哪條路、新功能要填哪四格。
> 資料契約（檔案格式、Claude 接口）仍在根目錄 `CLAUDE.md` 與資料夾的 `.hub/README.md`，
> 本文件只管程式碼的結構。

## 0. 為什麼要整理（2026-10-23 的診斷）

- 112 個 commit、26k 行 Swift、68 個檔案、**零測試**。
- 13 個「修正」commit 幾乎全在 AppKit／SwiftUI 橋接層：NSTextView 焦點與第一個按鍵、
  ⌘Z 閃退、分隔欄寬度、全螢幕多分頁跳桌面、PDFView 跳頁、LaTeX 主檔路徑與底線跳脫。
- 三個巨檔是狀態「同時住在三個地方」的典型：
  `Views/BlockEditorView.swift`（2624 行，WKWebView 橋接＋JS 訊息＋檔案讀寫）、
  `Views/SourceTextView.swift`（2024 行，一個 NSTextView 子類佔 1200 行）、
  `Views/PapersView.swift`（View＋PDF controller＋下載 watcher＋NSViewRepresentable）。
- 狀態散在 @Environment store、12 個 singleton、NSView 子類的 ivar，彼此靠 7 個
  `Notification.Name` 字串匯流排同步。
- iOS 目標只共用 9 個檔案，其餘在 `Mobile/` 另寫一份。

結論：**不拆成獨立部署的服務**（資料層早已獨立：iCloud 資料夾的純文字檔＋契約；
拆 process 只會多一層 IPC 讓 bug 更難追）。要做的是在**一個 Xcode 專案內**
用 SwiftPM 套件把邊界交給編譯器守。

## 1. 套件分層

```
ResearchHub/
  Packages/
    HubCore/      Package.swift  Sources/HubCore   Tests/HubCoreTests
    HubStore/     Package.swift  Sources/HubStore  Tests/HubStoreTests
    HubEditor/    Package.swift  Sources/HubEditor Tests/HubEditorTests
  Apps/
    ResearchHub/        macOS target：只有 SwiftUI view 與 composition root
    ResearchHubMobile/  iOS target：只有 SwiftUI view 與 composition root
  EditorWeb/            網頁編輯器（獨立建置，產出帶 version.json 的 bundle）
  scripts/              install-mac.sh、test.sh
  docs/                 本文件
```

| 套件 | 放什麼 | 允許 import | 禁止 import | 依賴 |
|---|---|---|---|---|
| **HubCore** | 純邏輯：`TodoSyntax`、`NotePreprocessor`、`LatexProject`／`LatexProjectIndex`、`LatexBibliography`、搜尋引擎、`AppCommand`、Zotero 與 PaperChat 的 client（純 URLSession）、記帳／回顧的 parser | Foundation | **AppKit、UIKit、SwiftUI、WebKit、PDFKit** | 無 |
| **HubStore** | 持久化與索引：`FileSystemStore`、`FileWatcher`、`LibraryIndex`、`LibrarySync`、`LatexHistory`、`LatexStaging`、`.hub/*.json` 的讀寫、快取 | Foundation、Combine／Observation | AppKit、UIKit、SwiftUI、WebKit | HubCore |
| **HubEditor** | 所有 AppKit／WebKit／PDFKit 橋接：`SourceTextView` 的 NSTextView 子類、`BlockEditorHost`、`PDFViewerController`、`PageFind` 的尋找列、`PersistentSplitView`、`WindowAccessor` | AppKit、WebKit、PDFKit、SwiftUI（僅 Representable 外殼） | — | HubCore、HubStore |
| **App targets** | SwiftUI 頁面、composition root（唯一允許建立 singleton 的地方）、選單與 `.commands` | 全部 | — | 三個套件 |

守則：

1. **HubCore 不碰檔案系統**。它收 `String`／`Data` 回傳結構；路徑由 HubStore 管。
   這讓 HubCore 的測試不需要 fixture 目錄，`swift test` 一秒內跑完。
2. **HubEditor 是唯一允許 AppKit 的非 view 套件**。橋接 bug 的搜尋範圍就是這個套件。
3. **singleton 只剩 composition root**。`static let shared` 全部收進 App target 的
   `AppContainer`，套件內一律用建構子注入。
4. **`Notification.Name` 匯流排歸零**，改走第 3 節的命令路由。
5. iOS 直接 link HubCore 與 HubStore，`Mobile/` 裡與 mac 重複的邏輯合併後刪除。

## 2. 部署與維護分離

單一 app 做不到只重新部署一個套件，但「一個 bug 對應一個單位、改一個單位不用驗整個 app」
做得到：

- **每套件一組測試、一個 CI job。** `scripts/test.sh` 依序跑
  `swift test --package-path Packages/HubCore` 等三個，不開 Xcode；App target 的
  xcodebuild 另一個 job。bug 進來先依症狀歸位：

  | 症狀 | 單位 |
  |---|---|
  | 字串、解析、路徑跳脫、排程計算錯 | HubCore |
  | 檔案沒同步、watcher 漏事件、索引過期、JSON 解碼 | HubStore |
  | 焦點、按鍵、尋找列、分隔欄、PDF 捲動、全螢幕分頁 | HubEditor |
  | 排版、顏色、頁面狀態 | App |

- **每套件一個 OSLog subsystem**：`hub.core`、`hub.store`、`hub.editor`、`hub.app`。
  Console.app 依 subsystem 過濾就是「target to the bug」最便宜的工具。
- **三個真正可分開部署的產物各帶版本，邊界做相容檢查，不相容就明確報錯：**

  | 產物 | 版本放哪 | 誰檢查 |
  |---|---|---|
  | Swift app | `CFBundleShortVersionString` | — |
  | EditorWeb bundle | `EditorWeb/version.json` | `BlockEditorHost` 載入時比對支援區間 |
  | 資料契約（`.hub/README.md`、JSON 格式） | `.hub/contract-version` | HubStore 開啟資料夾時比對；Claude／外部工具讀 README 得知 |

- **歷史跟著單位走**：`git log -- Packages/HubStore` 就是該單位的履歷。

## 3. 命令路由（快捷鍵）

現況：`PageFinder` 走 NSResponder chain，猜不到就挑「畫面上面積最大的那塊」；
7 個 `Notification.Name` 廣播，誰接收看不出來。用幾何猜焦點是橋接 bug 的根源。

新規則：**頁面主動宣告它接手哪些命令**。

```swift
// HubCore
public enum AppCommand: Sendable {
    case find, findNext, findPrevious, globalSearch
    case save, compile, newTab, closeTab
    case toggleSidebar, insertCitation
}

@MainActor public protocol CommandHandler: AnyObject {
    /// 回傳 false 代表不接手，App 走退路
    func handle(_ command: AppCommand) -> Bool
}
```

- 每個頁面（首頁、日記、筆記、LaTeX、論文）用 `.focusedSceneValue(\.commandHandler, self)`
  登記。SwiftUI 跟著 key window 走，全螢幕多分頁自動選對視窗，不碰 `NSApp.keyWindow`。
- 頁面用 `@FocusState var focusedPane` 記錄哪個面板有焦點，`handle` 依此轉交：
  LaTeX 頁原始碼有焦點 → 尋找列，否則 → PDF；論文頁 → PDF；首頁 → 回傳 false。
- App 的 `.commands` 只剩：讀 `@FocusedValue(\.commandHandler)`，呼叫 `handle`，
  回傳 false 或 nil 時走退路（⌘F 的退路是 ⌘K 全 app 搜尋）。
- **唯一的回呼**：焦點進 NSTextView 時 SwiftUI 的 `@FocusState` 不會自動更新，
  HubEditor 的 representable 在 `becomeFirstResponder` 時透過 binding 回報頁面。
- `performKeyEquivalent` 覆寫只留純文字編輯鍵（自動補括號、⌘/ 註解），
  不再攔 app 層級快捷鍵。
- 可測性：給定 `focusedPane == .pdf`，斷言 `handle(.find)` 送到 PDF finder。

落地（2026-10-23）與上面的差異：
- 一個視窗一個 `CommandRouter`（HubCore），根畫面用 `.focusedSceneValue(\.commandRouter)` 登記；
  頁面與 sheet 進場 `push` 自己、退場 `pop`（`pageCommands`），最上面的先接，不接走
  `windowFallback`（新分頁、收側欄、⌘K），⌘F 沒人接退成 ⌘K。選單在 `AppCommands`，只讀路由。
- 焦點不用 `@FocusState`，用 `EditorHandle`：頁面持有，各 representable 建好 NSView 時回報
  （`onTextViewReady`／`onWebViewReady`／`onPDFViewReady`），`findTarget()` 挑「firstResponder
  所在的那塊，否則看得到的第一塊（原始碼 > PDF > 預覽 > 區塊編輯器）」——只看頁面自己的 view，
  不再掃整個視窗。`PageFinder` 只剩呈現尋找列。
- 7 個 `Notification.Name` 歸零：`newTab`／`search` → 路由；`collapseSidebar` → 環境值閉包；
  `EditorCore.saveNow`／`append` → `EditorHandle`；`rhEditorCommand` → `BlockEditorView.onCommand`；
  `rhLibraryDidChange` → `LibrarySync.shared.changes`（型別化 `PassthroughSubject<LibraryChange>`）。
- 尋找列是 NSPanel（非 SwiftUI scene），它是 key 時路由為 nil，⌘F 只把焦點放回尋找列。

## 4. 搜尋

⌘F 的語意是**以頁面為範圍的跨文件搜尋**，不是「在目前這一頁找字」。⌘K 是範圍＝全部。
同一個引擎、四種範圍、三種呈現。

```swift
// HubCore
public enum SearchScope { case journal, papersAndNotes, notes, all }

public struct SearchHit: Identifiable, Hashable, Sendable {
    public enum Field { case fileName, title, body }
    public let kind: Kind            // journal / note / latex / paper / todo
    public let target: Target        // 要點過去的地方
    public let field: Field          // 命中檔名、標題還是內文
    public let line: Int             // 第幾行（0-based）
    public let range: Range<Int>     // 該行內的字元範圍
    public let snippet: String
}
```

與現有 `GlobalSearch` 的差異：多 `field`／`line`／`range`，日記範圍**不設每類 30 筆上限**。
比對規則不變：不分大小寫、空白分開的關鍵字全部出現（AND）、
檔案內容依「路徑＋修改時間」快取。

| 頁面 | scope | 呈現 |
|---|---|---|
| 日記 | `.journal` | **時間軸模式**：命中序列依日期排序，右上角「第 n 個／共 N 個」，上下鍵在天與天之間跳，跳到的那天自動打開並反白該字。預設最新在最上、往下是往舊；可切換。需要日記頁提供 `jump(to: Date, line: Int)`。 |
| 論文 | `.papersAndNotes` | **兩段式列表**：先論文、再筆記，各自可收合。論文目前只搜標題／作者／摘要／標籤；全文搜尋要讀 `Papers/<key>/` 已抽出的 PDF 文字，沒有就抽一次並快取。 |
| 筆記 | `.notes` | **合併列表**：檔名命中排前、內文命中排後，每筆標「檔名」或「內文」；同篇兩者都中合併成一筆、兩個標籤。 |
| 首頁／⌘K | `.all` | 現有的 palette。 |

## 5. 擴充功能模板

每個新功能填四格；前三格必填，第四格可選。

| 格 | 內容 | 歸屬 |
|---|---|---|
| ① 資料契約 | 日記內的標記語法，或 `.hub/<name>.json`；寫進 `.hub/README.md` 與 `CLAUDE.md` | 契約 |
| ② 模組 | parser／彙總，純 Swift，附測試 | HubCore |
| ③ 呈現 | 首頁卡片或獨立分頁；若需命令，實作 `CommandHandler` | App |
| ④ Claude 旁路 | Claude 透過檔案契約讀寫的部分（分類、摘要、建議） | 契約 |

原則：**不改歷史日記內文**（既有規則），衍生資料一律放旁車檔。

### 5.1 記帳

- ① 寫在日記裡，沿用 `@` 標記家族：`- 午餐 @spend(120, 餐費)`。
  編輯器 /command 多一個 `/spend`。不另開 `ledger.json`（多一個要打開的地方，且脫離 ⌘F）。
- ② `LedgerParser`：掃日記 → 依月份、類別彙總；類別白名單放 `.hub/ledger-categories.json`。
- ③ 先做首頁一張卡（本月支出、前三類別、月趨勢）；資料格式定好後再決定要不要獨立分頁。
- ④ Claude 可在 insights 裡提醒異常支出；不自動改數字。

### 5.2 日記回顧

- ① 旁車檔 `.hub/journal-meta.json`，每天一筆：
  `{ "2026-10-11": { "kind": "log" | "reflective", "mood": -2..2, "themes": [...] } }`。
- ② `JournalClassifier` 第一層本地啟發式：待辦行佔比高且短 → `log`；
  散文多、有第一人稱情緒詞 → `reflective`。結果可被 ④ 覆寫。
- ③ 回顧頁：「一年前的今天」、每月心得精選、心情時間軸；日記 ⌘F 多「只搜心得日」開關。
- ④ Claude 的 insights 流程順手補 `themes`／`mood`，寫回同一個檔。

## 6. 遷移順序

每一步可單獨 ship；**搬家與改行為分開 commit**；用舊 worktree 的 diff 驗證輸出不變；
**先找「同一份邏輯幾份拷貝」再分堆**。

1. **加 test target。** 把 13 個已修 bug 中能寫成純邏輯測試的補成回歸測試
   （主檔偵測、底線跳脫、PDF 隱藏旗標、todo 語法）。不動架構。
2. **抽出 HubCore。** `TodoSyntax`、`NotePreprocessor`、`LatexProject*`、`GlobalSearch`
   （改名 `SearchEngine`，加 scope／hit 欄位）、Zotero 與 PaperChat client。
   - 第一批（已搬，2026-10-23）：`TodoSyntax`、`LatexCommandCatalog`、`LatexFormat`、
     `LatexProject`、`LatexProjectIndex`、`GlobalSearch`，加上從 `FileSystemStore` 抽出的
     `ICloudFile.safeRead` 與 `JournalLayout.journalFiles`（原處保留轉呼叫）。只搬家＋加 `public`，
     沒改行為；`LatexProject`／`GlobalSearch` 仍直接讀檔，守則 1 留到第 4 步再收。
   - 第二批（已搬，2026-10-23）：`NotePreprocessor`、`LatexBibliography`，連同資料型別
     `ZoteroItem`（從 `Models/Zotero.swift` 切出，`ZoteroStore` 留在 app）與 `NoteLink`＋
     `NoteLinkResolver`（從 `NoteLinkIndex` 切出，原處保留轉呼叫）。
     `LatexBibliography.cite` 不再自己找 `ZoteroStore.shared`，改收 `exportedBibtex:`，
     由呼叫端先向 ZoteroStore 要——這是本批唯一的簽名變動。
   - 第三批（已拆，2026-10-23）：這批是「拆分」不是搬家。`ZoteroClient`（純 URLSession：
     抓文獻、BibTeX、附件）搬進 HubCore，`ZoteroStore` 留在 app 只管狀態、port 設定與
     資料夾書籤，請求全部轉呼叫 client。PaperChat 拆成 HubCore 的 `PaperChatModels`
     （資料模型＋ISO8601 的 JSON coder）、`PaperText`（引文正規化與核對；PDF 抽字的
     `pages(from:)` 用 PDFKit，以 extension 留在 app）、`PaperChatStream`（小幫手 JSONL 解析）、
     `PaperPrompt`（system prompt 與每輪提示詞）；`PaperChatSession`／`PaperModelCatalog`
     （檔案、小幫手、UserDefaults）留在 app。至此第 2 步列的項目都已進 HubCore。
3. **拆三個巨檔並去重。** 三個編輯器各自的尋找／undo 處理合併；`Mobile/` 與 mac 重複邏輯合併。
   同時落地第 3 節的命令路由，刪除 7 個 `Notification.Name`。
   - 已做（2026-10-23）：三個巨檔依型別分割、`PastingTextView` 依功能拆成 extension 檔、
     第 3 節的命令路由落地、7 個 `Notification.Name` 刪光。
   - 已做（續）：mac／iPhone 的讀檔、自動存檔、外部改動重讀合併成 `EditorDocument`；
     編輯器 HTML＋JS 搬成 `Resources/EditorWeb/editor.html`＋`version.json`
     （`EditorWebVersion` 比對支援區間，不相容就在編輯器位置報錯）。
     undo 不需要合併：af8c472 已讓每個 `SourceTextView` 自己擁有 UndoManager。
   - `Mobile/` 剩下的重複是畫面層（筆記清單、番茄鐘、設定）各寫一份，第 4 步再看要不要合。
4. **HubStore 與 HubEditor 邊界。** singleton 收進 `AppContainer`；OSLog subsystem；
   三個產物的版本契約。
   - HubStore 第一批（已搬，2026-10-23）：`FileWatcher`／`DirectoryWatcher`、`LatexHistory`、
     `LatexStaging`、`EditorDocument`、`LibrarySync`（SwiftUI 的狀態列 `LibrarySyncBanner` 留在 app）、
     `LibraryIndex`／`LibraryScan`（@remind 推播改成 app 注入的 `LibraryScan.reminderScheduler`，
     UserNotifications 不進套件）、`FileItem`、`ZoteroStore`、`ReadingGateStore`，以及從
     `FileSystemStore` 切出的 `LibraryTreeNode`／`LibraryTodoItem`／`RepeatedTodo`（原處留 typealias）。
     OSLog：`CoreLog`（hub.core）、`StoreLog`（hub.store）已建，待各處從 NSLog 換過去。
   - HubStore 第二批（已搬，2026-10-23）：`FileSystemStore`（`NoteLinkIndex`、`LibrarySync` 改建構子注入；
     `AppTab` 本體搬到 HubCore，SwiftUI 的 `title` 留在 app 的 extension；`requestedTab`／`pendingOpenNote`
     這些導覽「請求」留在 store 當純資料，由頁面消化）、`NoteLinkIndex`。
     資料契約版本：`DataContract`（HubCore）＋ `.hub/contract-version`，開資料夾時沒有就寫、
     比 app 新就警告照開（第 7 節的未決事項暫定如此）。`NSLog` 已全部換成 OSLog（`AppLog`，hub.app）。
   - HubStore 待做：`.hub/*.json` 的 `EventStore`／`GeneralTodoStore`（用了 SwiftUI `Color`）、
     `PomodoroModel`（1174 行，含 AppKit 面板）。
   - HubEditor 第一批（已搬，2026-10-23）：沒有 app 相依的橋接——`CompletionPopup`、
     `PDFViewerController`／`PDFKitView`、`PageFind`（尋找列與三種 `FindEngine`）、
     `PersistentSplitView`、`WindowAccessor`（視窗探針、`SidebarSplitControl`）、`LatexPDFView`、
     `ActiveEditorRegistry`、`AdaptiveSizing`。套件 deployment target 跟 app 一樣是 26.0。
     OSLog：`EditorLog`（hub.editor）。
   - HubEditor 第二批（已搬，2026-10-23）：`PastingTextView`＋三個 extension、`SourceTextView`、
     `BlockEditorHost`／`BlockEditorView`／`BlockEditorTemplate`、`MarkdownPreviewView`、`WebResources`。
     注入方式：`EditorLocalization.L`（app 啟動時掛上自己的 `L()`，套件字串跟隨 app 語言）；
     `EditorPalette`（app 依主題算好傳給 `SourceTextView`，取代直接讀 `AppTheme`）；
     `SourceTextView` 轉交 `zotero`／`noteLinks`／`activeEditor` 給 `PastingTextView`；
     `BlockEditorView` 明確收 `host`，`BlockEditorHost.pomoMinutesProvider` 由 `AppContainer` 掛上；
     `MarkdownPreviewView` 收 `noteLinks`。HubEditor 不再引用 app 的任何型別。
     `Views/` 只剩 SwiftUI 頁面與 `CommandRouting`／`EditorHandle`（守則 2 達成）。
   - `AppContainer`（已落地，2026-10-23）：`Services/AppContainer.swift` 是唯一的 composition root，
     持有 `LibrarySync`、`ZoteroStore`、`ReadingGateStore`（建構子注入 `LibrarySync`）、
     `NoteLinkIndex`、`BlockEditorHost`、`NotificationDelegate`，mac 另有 `PageFinder`、
     `ActiveEditorRegistry`、`PDFExporter`、`PaperModelCatalog`、`PomodoroPanelController`。
     12 個 `static let shared` 全部拿掉，呼叫處改 `AppContainer.shared.x`。
     例外：`LibraryIndex.shared` 是 HubStore 模組內部的快取（不 public、不是可注入的相依）。

### dev 版（重構期間與正式版並存）

重構期間**一律跑 `scripts/install-dev.sh`，不跑 `install-mac.sh`**。它用 `Dev` build
configuration 產出 `/Applications/ResearchHub Dev.app`（bundle id `com.ken.ResearchHub.dev`、
URL scheme `researchhub-dev://`、橘色 AccentColor），不碰、不關正式版。
資料也分開：第一次執行會把 iCloud 資料夾複製到 `~/ResearchHubLibrary-dev/`，dev 版第一次啟動
選這個資料夾；之後執行不再覆蓋。dev 版的 LaTeX 小幫手裝在
`~/Library/Application Scripts/com.ken.ResearchHub.dev/`。

全部完成後收尾：跑一次 `scripts/install-mac.sh` 替換正式版；
`rm -rf "/Applications/ResearchHub Dev.app"` 並用 `lsregister -u` 反註冊
（路徑見 `install-dev.sh` 的 `LSREG`）；`~/ResearchHubLibrary-dev` 由使用者決定是否刪。

## 7. 未決事項

- 日記時間軸預設方向（暫定最新在上）。
- 記帳是否需要獨立分頁（暫定首頁卡片）。
- 論文全文搜尋的文字來源：`Papers/<key>/` 現有抽取結果是否完整。
- `.hub/contract-version` 的升級策略：舊版 app 遇到新契約是拒開還是唯讀。
  （2026-10-23 暫定：警告但照開，`errorMessage` 顯示一次；真的要拒開時改 `FileSystemStore.checkContractVersion`。）
