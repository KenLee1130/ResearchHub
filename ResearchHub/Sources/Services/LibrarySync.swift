import SwiftUI
import Observation
import Combine

extension Notification.Name {
    /// 資料夾裡有檔案被另一台裝置（經 iCloud）或外部工具改動、或剛從 iCloud 下載完成。
    /// userInfo["urls"]: [URL]；空陣列＝不確定是哪些（例如切回 app），全部重讀。
    static let rhLibraryDidChange = Notification.Name("ResearchHub.libraryDidChange")
}

/// 整個資料夾的 iCloud 同步：打開／切回 app 時先跟 iCloud 要另一台裝置的更新。
///
/// 以前只有「正在編輯的那一篇」會跟 iCloud 要最新版；一般待辦、行事曆事件、
/// 蕃茄鐘紀錄、Claude 觀察、筆記清單都只在開 app 時讀一次——手機改了，
/// Mac 要重開 app 才看得到（反之亦然）。iPhone 的 iCloud 雲碟更是用到才下載，
/// 不主動要就一直是舊的。
///
/// 做法：
/// 1. `syncNow()`：掃整個資料夾（含 .hub），不是最新版的檔案都請 iCloud 下載，
///    每秒檢查一次，下載好的就廣播 `.rhLibraryDidChange`，各 store 自己重讀。
/// 2. 對根資料夾掛一個 NSFilePresenter：app 開著時另一台裝置同步進來的改動也會廣播。
@MainActor
@Observable
final class LibrarySync {
    static let shared = LibrarySync()

    /// 還在從 iCloud 下載的檔案數（>0 時畫面顯示「正在同步」）
    private(set) var pendingCount = 0

    private var rootURL: URL?
    private var watcher: DirectoryWatcher?
    private var pending: Set<URL> = []
    private var pollTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var changedBuffer: Set<URL> = []
    private var broadcastTask: Task<Void, Never>?

    private init() {}

    /// 下載等待上限：超過就不再轉圈（檔案之後到了，presenter 一樣會通知）
    private static let pollLimit = 90

    func configure(rootURL: URL?) {
        guard rootURL?.path != self.rootURL?.path else { return }
        self.rootURL = rootURL
        watcher?.stop()
        watcher = nil
        pending = []
        pendingCount = 0
        resume()
        syncNow()
    }

    /// 開始監看根資料夾（iOS 回到前景時呼叫）
    func resume() {
        guard watcher == nil, let root = rootURL else { return }
        watcher = DirectoryWatcher(url: root) { [weak self] url in
            self?.noteChanged(url)
        }
    }

    /// 停止監看（iOS 進背景時呼叫：被暫停的 app 掛著 presenter 會拖住別人的協調寫入）
    func suspend() {
        watcher?.stop()
        watcher = nil
    }

    /// 跟 iCloud 要所有檔案的最新版，並請畫面重讀。打開 app、切回 app、下拉重新整理時呼叫。
    func syncNow() {
        guard let root = rootURL else { return }
        // 先請大家重讀一次：本機檔可能早就更新了，只是記憶體裡還是舊的
        broadcast([])
        scanGeneration += 1
        let generation = scanGeneration
        Task.detached(priority: .utility) {
            let found = Self.requestDownloads(under: root)
            await MainActor.run {
                guard generation == self.scanGeneration else { return }
                self.track(found)
            }
        }
    }

    // MARK: - 下載追蹤

    private func track(_ urls: [URL]) {
        pending.formUnion(urls)
        pendingCount = pending.count
        guard !pending.isEmpty, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            for _ in 0..<Self.pollLimit {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                let snapshot = self.pending
                let done = await Task.detached(priority: .utility) {
                    snapshot.filter { Self.isCurrent($0) }
                }.value
                if !done.isEmpty {
                    self.pending.subtract(done)
                    self.pendingCount = self.pending.count
                    self.noteChanged(contentsOf: done)
                }
                if self.pending.isEmpty { break }
            }
            guard let self else { return }
            self.pending = []
            self.pendingCount = 0
            self.pollTask = nil
        }
    }

    /// 掃資料夾，把「本機沒有／本機不是最新」的檔案都請 iCloud 下載，回傳這些檔案。
    nonisolated private static func requestDownloads(under root: URL) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .ubiquitousItemDownloadingStatusKey]
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var result: [URL] = []
        for case let url as URL in e {
            let name = url.lastPathComponent
            // LaTeX 專案的編譯產物（.researchhub/）不必搶先下載
            if name == LatexProject.stateDirName { e.skipDescendants(); continue }
            // 舊式 iCloud 佔位檔「.檔名.icloud」→ 下載真正的檔案
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let real = url.deletingLastPathComponent()
                    .appendingPathComponent(String(name.dropFirst().dropLast(7)))
                try? fm.startDownloadingUbiquitousItem(at: real)
                result.append(real)
                continue
            }
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isRegularFile == true,
                  let status = v.ubiquitousItemDownloadingStatus,
                  status != .current else { continue }
            try? fm.startDownloadingUbiquitousItem(at: url)
            result.append(url)
        }
        return result
    }

    nonisolated private static func isCurrent(_ url: URL) -> Bool {
        var u = url
        u.removeAllCachedResourceValues()
        guard let status = try? u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus else {
            // 不在 iCloud 上（或已被刪除）：沒有東西可等
            return true
        }
        return status == .current
    }

    // MARK: - 廣播

    private func noteChanged(_ url: URL?) {
        // url == nil＝「資料夾本身變了」（存檔時的暫存檔進出就會觸發）：
        // 真正的改動會另外以檔案為單位通知，這裡不必讓全 app 重讀
        guard let url else { return }
        // 自己剛存的檔不算「別人改的」（見 OwnWrites）
        guard !OwnWrites.isRecent(url) else { return }
        noteChanged(contentsOf: [url])
    }

    /// 短時間內的多次改動合併成一次廣播（iCloud 常一次同步進好幾個檔）
    private func noteChanged(contentsOf urls: Set<URL>) {
        changedBuffer.formUnion(urls)
        broadcastTask?.cancel()
        broadcastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            let urls = Array(self.changedBuffer)
            self.changedBuffer = []
            self.broadcast(urls)
        }
    }

    private func broadcast(_ urls: [URL]) {
        NotificationCenter.default.post(
            name: .rhLibraryDidChange, object: nil, userInfo: ["urls": urls])
    }

    /// 這則通知會不會改變「筆記清單」的長相（有筆記／資料夾增刪改名）？
    /// LaTeX 專案裡的 .tex、.bib、圖檔內容變了不算——專案在清單上只是一個項目。
    nonisolated static func affectsNoteListing(_ note: Notification, notes: URL?) -> Bool {
        guard affects(note, notes) else { return false }
        let urls = note.userInfo?["urls"] as? [URL] ?? []
        return urls.isEmpty || urls.contains {
            if $0.pathExtension.lowercased() == "md" { return true }
            // 資料夾（或已經不在了的東西＝被刪／被改名）才算；latexmkrc 這種沒副檔名的檔案不算
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir)
            return !exists || isDir.boolValue
        }
    }

    /// 這則通知跟 `item`（檔案或資料夾）有關嗎？
    /// 沒列檔案＝全部都算；改動的是它本身、它所在的資料夾、或它底下的東西都算。
    nonisolated static func affects(_ note: Notification, _ item: URL?) -> Bool {
        guard let item else { return false }
        let urls = note.userInfo?["urls"] as? [URL] ?? []
        if urls.isEmpty { return true }
        let target = item.standardizedFileURL.path
        return urls.contains { changed in
            let p = changed.standardizedFileURL.path
            return p == target || target.hasPrefix(p + "/") || p.hasPrefix(target + "/")
        }
    }
}

// MARK: - 安全讀 JSON

/// 讀資料夾裡的機器檔（.hub/*.json、pomodoro.json）。
/// 區分「檔案不存在」與「在 iCloud 上但還沒下載」——後者絕對不能當成空的，
/// 否則下一次存檔就會拿空內容蓋掉另一台裝置的資料。
enum LibraryFileRead {
    case data(Data)
    case missing
    case notDownloaded

    nonisolated static func read(_ url: URL) -> LibraryFileRead {
        if let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus {
            if status == .notDownloaded {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                return .notDownloaded
            }
            if status == .downloaded {
                // 本機有一份但不是最新：先用本機這份，背景請 iCloud 抓（抓完會廣播重讀）
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        }
        if let data = try? Data(contentsOf: url) { return .data(data) }
        return FileManager.default.fileExists(atPath: url.path) ? .notDownloaded : .missing
    }
}

/// 以 id 合併：以磁碟那份為主，補上只存在本機的項目。
/// 用在「檔案還沒下載完時使用者就先動手」的情況，兩邊的新增都保得住。
func mergeByID<T: Identifiable>(disk: [T], local: [T]) -> [T] {
    let ids = Set(disk.map(\.id))
    return disk + local.filter { !ids.contains($0.id) }
}

// MARK: - 同步狀態列

/// 「正在從 iCloud 取得另一台裝置的更新…」提示；沒在下載時不佔空間。
struct LibrarySyncBanner: View {
    private var sync = LibrarySync.shared

    var body: some View {
        if sync.pendingCount > 0 {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在從 iCloud 取得另一台裝置的更新（\(sync.pendingCount) 個檔案）…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        }
    }
}
