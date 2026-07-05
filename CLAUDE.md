# ResearchHub

macOS SwiftUI app（日記 + 筆記 + 事件 + 番茄鐘）。使用者選定的根資料夾就是本 repo 根目錄，
所有資料都是純文字檔，Claude 可以直接讀寫下列檔案來參與工作流程。

## 資料佈局（Claude 介入接口）

| 路徑 | 內容 | Claude 可做的事 |
|---|---|---|
| `Journal/yyyy/MM/yyyy-MM-dd.md` | 每日日記，待辦格式 `- [ ] 文字`／完成 `- [x]`／已放棄 `- [-]` | 讀取分析；**不要**主動改寫歷史日記 |
| （待辦標記語法） | `- [ ] 文字 !high @due(7/10)`：`!high`/`!low` 優先級、`@due(M/d)` 或 `@due(yyyy-M-d)` 到期日 | 排程時把 `!high` 與快到期的排前面；寫待辦時可加標記 |
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

## 開發

- Xcode 專案：`ResearchHub.xcodeproj`，target `ResearchHub`，synchronized folder group
  （新增 Swift 檔免改 pbxproj）。
- 建置驗證：`xcodebuild -project ResearchHub.xcodeproj -scheme ResearchHub build`
- UI 全部繁體中文；字串走 `Sources/Localizable.xcstrings`。
