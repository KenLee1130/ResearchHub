import Foundation
import Observation

/// 一份正在編輯的文字檔：讀（含「在 iCloud 上但還沒下載」）、自動存檔、外部改動時重讀。
///
/// 以前 mac 的 EditorCore、iPhone 的日記頁與規劃儀式各有一份幾乎相同的邏輯（三份拷貝、
/// 各自修 bug）；現在共用這一個，畫面只管把 `text` 綁給編輯器。
///
/// 安全規則（全部來自過去的 bug）：
/// - 檔案在 iCloud 上還沒下載到本機時（`awaitingDownload`）絕不存檔，否則會用空內容蓋掉雲端那份。
/// - 本機有未存修改時外部改動不重讀（autosave 0.8 秒內就會寫出去）。
/// - 換檔／換日後晚到的寫入回呼不能把舊檔的狀態套到新檔上（比對 watcher 身分）。
/// - 檔案原本不存在且內容仍是空的 → 不落地，避免製造空檔案。
@MainActor
@Observable
final class EditorDocument {
    private(set) var fileURL: URL?
    /// 編輯器綁定的內容
    var text = ""
    /// 上次讀到／寫出的內容；`text != initialText` 就是有未存修改
    private(set) var initialText = ""
    private(set) var fileExisted = false
    /// 檔案在 iCloud 上但還沒下載到本機
    private(set) var awaitingDownload = false
    /// 存檔完成後（LaTeX 專案用來觸發重新編譯）
    var onSaved: (() -> Void)?

    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let autosaveDelay: UInt64

    init(autosaveDelay: UInt64 = 800_000_000) {
        self.autosaveDelay = autosaveDelay
    }

    var isDirty: Bool { text != initialText }

    /// 打開（或換到）一個檔案。nil＝沒有檔案（例如還沒選資料夾）：內容清空、不監看。
    func open(_ url: URL?) {
        watcher?.stop()
        saveTask?.cancel()
        fileURL = url
        guard let url else {
            watcher = nil
            text = ""; initialText = ""; fileExisted = false; awaitingDownload = false
            return
        }
        let w = FileWatcher(url: url) { [weak self] in self?.reloadIfClean() }
        watcher = w
        if let content = FileSystemStore.safeRead(url) {
            text = content
            initialText = content
            fileExisted = true
            awaitingDownload = false
            w.requestLatest()           // 本機這份可能不是最新的：背景跟 iCloud 要
        } else if (try? url.checkResourceIsReachable()) == true {
            // 在 iCloud 上但還沒下載：先顯示下載中，下載完 watcher 會通知 → reloadIfClean
            text = ""; initialText = ""; fileExisted = false
            awaitingDownload = true
            w.requestLatest()
        } else {
            text = ""; initialText = ""; fileExisted = false; awaitingDownload = false
        }
    }

    /// 切到另一個檔案：先把目前這份寫出去，再載入新的。
    /// 不走 saveNow()，因為它的完成回呼會改 initialText——那時候已經是新檔案了。
    func switchFile(to url: URL?) {
        if !awaitingDownload, isDirty, fileExisted || !text.isEmpty {
            watcher?.write(text) { _ in }
        }
        open(url)
    }

    /// 切回 app／從背景回來：另一台裝置可能改過 → 請 iCloud 抓最新版，沒有未存修改就重讀
    func refreshFromDisk() {
        watcher?.requestLatest()
        reloadIfClean()
    }

    /// 檔案被外部改動（另一台裝置同步進來）時重讀；本機有未存修改就以本機為準。
    func reloadIfClean() {
        guard !isDirty, let w = watcher else { return }
        w.read { [weak self] content in
            guard let self, let content, w === self.watcher else { return }   // 讀檔期間換了檔案
            guard !self.isDirty else { return }                                 // 讀檔期間又打字了
            self.awaitingDownload = false
            self.fileExisted = true
            if content != self.text {
                self.text = content
                self.initialText = content
            }
        }
    }

    func scheduleAutosave() {
        saveTask?.cancel()
        saveTask = Task { [weak self, autosaveDelay] in
            try? await Task.sleep(nanoseconds: autosaveDelay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard !awaitingDownload else { return }   // 還沒拿到雲端那份，寫出去就是蓋掉它
        guard fileExisted || !text.isEmpty else { return }
        guard isDirty || !fileExisted else { return }
        guard let w = watcher else { return }
        let snapshot = text
        // 協調寫入：iCloud 會正確接手上傳，也不會通知回自己的 watcher
        w.write(snapshot) { [weak self] ok in
            guard ok, let self, w === self.watcher else { return }   // 失敗保持靜默；換檔後晚到的回呼不算
            self.initialText = snapshot
            self.fileExisted = true
            self.onSaved?()
        }
    }

    /// 把文字附加到尾端（經過編輯器，不直接改檔案，否則會被 autosave 蓋掉）
    func append(_ appended: String) {
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += appended
    }

    /// 畫面卸下：存檔、停止監看
    func close() {
        saveNow()
        watcher?.stop()
    }
}
