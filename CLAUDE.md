# ResearchHub

macOS + iOS SwiftUI app（日記 + 筆記 + 事件 + 番茄鐘）。所有資料都是純文字檔，
Claude 可以直接讀寫下列檔案來參與工作流程。

> ⚠️ **本 repo 只有程式碼。使用者的資料（根資料夾）在
> `~/Library/Mobile Documents/com~apple~CloudDocs/ResearchHubLibrary/`**
> （iCloud Drive，Mac 與 iPhone 共用）。下表的相對路徑都以那裡為準；
> **不要**在 repo 目錄下建立或讀寫 `.hub/`、`Journal/`、`Notes/`。

## 資料佈局（Claude 介入接口）

| 路徑 | 內容 | Claude 可做的事 |
|---|---|---|
| `Journal/yyyy/MM/yyyy-MM-dd.md` | 每日日記，待辦格式 `- [ ] 文字`／完成 `- [x]`／已放棄 `- [-]` | 讀取分析；**不要**主動改寫歷史日記 |
| （待辦標記語法） | `- [ ] 文字 !high @due(7/10) @line(A)`：`!high`/`!low` 優先級、`@due(M/d)` 到期日、`@line(名字)` 主線歸屬。白名單制，其他 @ 內容不受影響 | 排程時把 `!high` 與快到期的排前面；週檢討按 line 分線統計 |
| `Notes/**/*.md` | 筆記（資料夾 = 分類，`assets/` 是圖片附件） | 讀取；可餵給 Claude project 當知識庫 |
| `.hub/events.json` | 行事曆事件與標籤（`title`、`notes`、`start`、`end` ISO8601、`isAllDay`、`tagID`） | 可代使用者新增／修改事件 |
| `.hub/todos.json` | 首頁「一般待辦」與垃圾桶：`{ "todos": [...], "trash": [...] }` | 可新增待辦、把放棄的項目搬進 `trash` |
| `.hub/claude/insights.json` | Claude 寫給使用者的觀察與鼓勵，顯示在首頁「Claude 觀察」區 | **這是 Claude 的主要輸出口**，見下方格式 |
| `Pomodoro/pomodoro.json` | 番茄鐘紀錄 | 讀取統計 |

所有 JSON 的日期都是 ISO8601 字串；缺欄位可容忍（app 解碼會補預設值）。
改 JSON 後不用重啟 app——首頁每次出現時會重新讀檔。

## 對外橋樑（不限 Claude，任何工具皆可用）

- **資料契約隨資料夾走**：app 會在根資料夾自動生成 `.hub/README.md`（英文版接口說明），
  外部工具不需要讀本 repo 的 CLAUDE.md 也能整合。
- **URL scheme**：`open "researchhub://note?path=<相對 Notes/ 的路徑>"` 開筆記、
  `open "researchhub://journal?date=YYYY-MM-DD"` 開日記（省略 date = 今天）。
  Claude 在報告裡引用筆記時可以直接給這種連結。
- **行事曆**：日記分頁可把全部事件匯出成標準 `.ics`（Apple／Google 行事曆可匯入）。
- **Zotero**：本地 API 埠可在設定調整（預設 23119），不再寫死。

## insights.json 格式

> 語言：`message`／`schedule` 跟隨使用者的介面語言（app 是中英雙語；
> 使用者日記用什麼語言就用什麼語言寫，目前預設繁體中文）。

```json
{
  "updatedAt": "2026-07-02T10:00:00Z",
  "message": "顯示在首頁的一段話（觀察 + 鼓勵，繁體中文，2–4 句）",
  "schedule": "可選。今日排程建議（多行文字），顯示在首頁「今日排程建議」區塊"
}
```

### schedule 的產生方式（Claude 排程建議）

使用者習慣前一晚把隔天要做的事寫進隔天的日記（`- [ ]` 待辦）。Claude 排程時：

1. 讀當天日記的未完成待辦（沒有就看昨天剩下的）。
2. 讀 `Pomodoro/pomodoro.json` 統計每小時完成顆數，找出高產時段。
   **注意**：`startedAt == null` 且 plan/done 皆空、時間正午 12:00 整的是舊資料補登，要排除。
   app 內建同一套統計（首頁「生產力分析」卡，取最近 60 天、依開始時刻）。
3. 把最難/最需要動腦的任務排進高產時段，行政瑣事排低谷；3–5 行就好，留白也是行程。
   待辦有 `!high` 或快到期的 `@due` 要優先排。
4. **行格式是可執行的**：`HH:MM–HH:MM 任務內容`（en dash 或 hyphen 皆可）。
   使用者按首頁「加入行事曆」會把符合此格式的行直接建成當天事件，
   所以任務內容要能當事件標題；說明性文字放在不含時間範圍的行（會被略過）。
   另外首頁 hero 有「規劃明天」儀式：使用者晚上會看著 Claude 建議寫明天的日記。

## 重複待辦的規則（app 內建，Claude 撰寫 insights 時請沿用同一口徑）

- 同一句 `- [ ] 文字`（trim 後全字相同）出現在 **≥ 2 天**的日記 → 首頁列為「重複出現」並顯示次數。
- **≥ 3 次**未完成 → 標紅，建議使用者「放棄（進垃圾桶）」或拆小今天做。
- 使用者按「放棄」或「收進一般待辦」時，app 會把日記中的複本改成 `- [-]`（已放棄標記），
  之後不再列入統計。

Claude 更新 insights 時的建議流程：掃 `Journal/` 統計重複未完成待辦 → 對照 `.hub/todos.json`
的 trash（已放棄的不要再提）→ 用鼓勵、不責備的語氣寫 `message`（可點名 1–2 件最該處理的事）。

## 週檢討（使用者的進度追蹤機制，來源：Notes/Planning/2026~2027 計畫.md）

使用者說「幫我週檢討」（或排程於每週日晚）時，照計畫檔第四節的機制執行：

1. **算四個數字**（資料都在資料夾裡）：
   - 執行率 = 本週「時段」類事件（標籤為 大塊/固定/碎片）中，時間窗口（±15 分鐘）內
     有 ≥1 顆蕃茄鐘的比例（events.json × pomodoro.json；app 首頁也即時顯示同一口徑）
   - artifact 數 = **由你判定**：掃本週日記的已完成項與內文，依計畫檔標準
     （圖/commit/送出的文件/筆記新增一節）列出候選清單並計數，寫進 Log 供使用者否決。
     「讀了很多/想了很久/debug 一整天」不算。待辦若標了 `@line(名字)` 依線歸類，
     沒標就由內容判斷（A=物理 bootstrap、B=ML interpretability）。
   - referee 未關閉 = 審稿清單筆記中未勾的 `- [ ]` 數（審稿期）
   - 空轉週數 = 讀 `.hub/weekly.json` 歷史，artifact=0 則 +1，否則歸零
2. **套修正規則 R1–R5**（見計畫檔），有觸發就在檢討輸出裡明講。
3. **寫回三個地方**：
   - 計畫檔「五、Weekly Log」補一行：`YYYY-Www | 執行率 x/y | artifact: … | referee 剩 n | 空轉 n | 借用 是/否 | 備註`
   - `.hub/weekly.json` append 同樣數字，schema：
     `[{week:"2026-W28", executed, planned, artifacts, refereeOpen, idleWeeks}]`
     （app 首頁「本週檢視」卡會讀最後一筆顯示）
   - `.hub/claude/insights.json`：檢討摘要（含觸發的規則）＋下週 schedule
4. 語氣照舊：鼓勵不責備；超過範圍的策略調整先問使用者。

### 相關約定
- 排時段 = 行事曆事件掛「大塊」「固定」「碎片」其中一個標籤。
- 待辦可標 `@line(名字)` 標主線歸屬（可選；分線統計用）。
- 每月一次（月初的週日）改用計畫檔的每月檢討清單，取代當週週檢討。

- Xcode 專案：`ResearchHub.xcodeproj`，target `ResearchHub`，synchronized folder group
  （新增 Swift 檔免改 pbxproj）。
- 建置驗證：`xcodebuild -project ResearchHub.xcodeproj -scheme ResearchHub build`
- UI 全部繁體中文；字串走 `Sources/Localizable.xcstrings`。
