#if os(macOS)
import AppKit
import HubCore
import HubEditor

/// 日記頁的 ⌘F（docs/ARCHITECTURE.md 第 4 節「時間軸模式」）：
/// 範圍是所有日記，命中依日期排序（最新在上、往下是往舊），尋找列顯示「第 n 個／共 N 個」，
/// 上下鍵在天與天之間跳：跳到的那天自動打開，再用那天編輯器自己的找字把關鍵字反白。
/// 實作既有的 FindEngine，所以尋找列、快捷鍵、狀態文字都跟在單一檔案裡找一樣。
@MainActor
final class JournalTimelineFindEngine: FindEngine {
    /// 根資料夾（SearchEngine 從 <root>/Journal 掃）
    var root: URL?
    /// 切到某一天（JournalView：selectedDay／displayedMonth）
    var jump: (Date) -> Void
    /// 那一天的編輯器目前的 NSView（原始碼 NSTextView 或區塊編輯器的 WKWebView）
    var innerTarget: () -> NSView?

    private var hits: [SearchEngine.Hit] = []
    private var index = 0
    private var lastQuery = ""
    private var inner: FindEngine?

    init(root: URL?, jump: @escaping (Date) -> Void, innerTarget: @escaping () -> NSView?) {
        self.root = root
        self.jump = jump
        self.innerTarget = innerTarget
    }

    func find(_ query: String, forward: Bool, restart: Bool) async -> (index: Int, total: Int) {
        if restart || query != lastQuery {
            let root = self.root
            hits = await Task.detached(priority: .userInitiated) {
                SearchEngine.search(query, scope: .journal, root: root)
            }.value
            lastQuery = query
            index = 0
            if Task.isCancelled { return (0, 0) }
        }
        guard !hits.isEmpty else { return (0, 0) }
        index = forward ? (index % hits.count) + 1 : (index <= 1 ? hits.count : index - 1)
        guard let date = hits[index - 1].date else { return (index, hits.count) }
        inner?.clear()
        inner = nil
        jump(date)
        // 等那一天的編輯器載好（原始碼模式會重建 NSTextView；區塊模式要把 markdown 推進網頁），
        // 再在裡面反白關鍵字。網頁還沒推完時找不到，最多再試兩次。
        for attempt in 0..<3 {
            try? await Task.sleep(nanoseconds: attempt == 0 ? 350_000_000 : 300_000_000)
            if Task.isCancelled { return (index, hits.count) }
            guard let view = innerTarget(), let engine = PageFinder.engine(for: view) else { continue }
            let r = await engine.find(query, forward: true, restart: true)
            if r.total > 0 { inner = engine; break }
        }
        return (index, hits.count)
    }

    func clear() {
        inner?.clear()
        inner = nil
        hits = []
        lastQuery = ""
        index = 0
    }
}
#endif
