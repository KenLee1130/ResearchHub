import Foundation

/// 這個 app 自己剛寫過哪些檔案。
///
/// 編輯器的自動存檔是協調寫入，掛在根資料夾上的 presenter（LibrarySync）也會收到通知；
/// 不擋掉的話，每打幾個字存一次檔，整個 app 就以為「另一台裝置改了東西」而全部重讀——
/// 首頁重掃所有筆記，主執行緒卡一百多毫秒，打字就一頓一頓的。
nonisolated enum OwnWrites {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stamps: [String: Date] = [:]
    private static let window: TimeInterval = 3

    static func note(_ url: URL) {
        let key = url.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        stamps[key] = Date()
        if stamps.count > 64 {
            let cutoff = Date().addingTimeInterval(-window)
            stamps = stamps.filter { $0.value > cutoff }
        }
    }

    /// 這個檔案是不是 app 自己剛剛寫的
    static func isRecent(_ url: URL) -> Bool {
        let key = url.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        guard let t = stamps[key] else { return false }
        return Date().timeIntervalSince(t) < window
    }
}

/// 監看一個檔案被「別人」改動——另一台裝置經 iCloud 同步進來，或其他程式寫入。
///
/// 以前的編輯器打開時讀一次檔就再也不看，所以 iPhone 寫的日記在 Mac 上
/// 永遠顯示舊的（反之亦然），更糟的是本機一打字、autosave 就把雲端那份蓋掉。
///
/// 用 NSFilePresenter：iCloud 的同步程序以 NSFileCoordinator 寫檔，會通知到這裡。
/// 自己的寫入一律走 `write(_:)`（協調寫入並帶上 filePresenter: self），
/// 這樣不會通知回自己。讀寫都在背景序列佇列上做——協調讀取在檔案還沒從
/// iCloud 下載完時會等下載，放主執行緒會卡死（iPhone 之前的 watchdog 閃退就是這樣）。
nonisolated final class FileWatcher: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let io = DispatchQueue(label: "ResearchHub.FileWatcher.io")
    private let onChange: @MainActor @Sendable () -> Void
    private var registered = false

    init(url: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        presentedItemURL = url
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        presentedItemOperationQueue = q
        self.onChange = onChange
        super.init()
        NSFileCoordinator.addFilePresenter(self)
        registered = true
    }

    func stop() {
        guard registered else { return }
        NSFileCoordinator.removeFilePresenter(self)
        registered = false
    }

    deinit { stop() }

    // MARK: NSFilePresenter

    func presentedItemDidChange() {
        let cb = onChange
        Task { @MainActor in cb() }
    }

    /// iCloud 用「新版本」取代檔案時走這條（例如另一台裝置存檔後同步下來）
    func presentedItemDidGain(_ version: NSFileVersion) {
        presentedItemDidChange()
    }

    // MARK: iCloud

    /// 本機這份不是最新的（或還沒下載）→ 請 iCloud 去抓。抓完會觸發 presentedItemDidChange。
    func requestLatest() {
        guard let url = presentedItemURL else { return }
        io.async {
            let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                .ubiquitousItemDownloadingStatus
            if status != nil, status != .current {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        }
    }

    // MARK: 協調讀寫

    /// 背景協調讀取，結果回主執行緒。檔案不存在回 nil。
    func read(_ completion: @escaping @MainActor @Sendable (String?) -> Void) {
        guard let url = presentedItemURL else {
            Task { @MainActor in completion(nil) }
            return
        }
        io.async { [self] in
            var result: String?
            var err: NSError?
            NSFileCoordinator(filePresenter: self).coordinate(
                readingItemAt: url, options: [], error: &err
            ) { u in
                result = try? String(contentsOf: u, encoding: .utf8)
            }
            let r = result
            Task { @MainActor in completion(r) }
        }
    }

    /// 背景協調寫入（不會通知回自己）。完成後在主執行緒回報成功與否。
    func write(_ text: String,
               completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        guard let url = presentedItemURL else {
            if let completion { Task { @MainActor in completion(false) } }
            return
        }
        io.async { [self] in
            var ok = false
            var err: NSError?
            OwnWrites.note(url)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            NSFileCoordinator(filePresenter: self).coordinate(
                writingItemAt: url, options: .forReplacing, error: &err
            ) { u in
                ok = (try? text.write(to: u, atomically: true, encoding: .utf8)) != nil
            }
            OwnWrites.note(url)   // 寫完再記一次：通知可能晚到
            let done = ok
            if let completion { Task { @MainActor in completion(done) } }
        }
    }
}

/// 監看一整個資料夾：裡面任何檔案被改動（包含另一台裝置經 iCloud 同步進來）都會回報。
/// LaTeX 專案用它來更新檔案樹、並在來源檔變動時重新編譯。
nonisolated final class DirectoryWatcher: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onChange: @MainActor @Sendable (URL?) -> Void
    private var registered = false

    init(url: URL, onChange: @escaping @MainActor @Sendable (URL?) -> Void) {
        presentedItemURL = url
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        presentedItemOperationQueue = q
        self.onChange = onChange
        super.init()
        NSFileCoordinator.addFilePresenter(self)
        registered = true
    }

    func stop() {
        guard registered else { return }
        NSFileCoordinator.removeFilePresenter(self)
        registered = false
    }

    deinit { stop() }

    func presentedItemDidChange() {
        let cb = onChange
        Task { @MainActor in cb(nil) }
    }

    func presentedSubitemDidChange(at url: URL) {
        // app 自己的狀態資料夾（output.pdf 等）不算使用者的改動，否則會編譯到無窮迴圈
        guard !url.path.contains("/\(LatexProject.stateDirName)/"),
              !url.lastPathComponent.hasPrefix(".") else { return }
        let cb = onChange
        Task { @MainActor in cb(url) }
    }
}

