import Foundation

/// iCloud 資料夾裡的檔案：讀取前先看下載狀態（原本住在 FileSystemStore，搬來這裡讓純邏輯也能用）。
public nonisolated enum ICloudFile {
    /// 安全讀檔：iCloud 佔位檔（尚未下載到本機）同步讀取會阻塞到下載完成，
    /// 在 iOS 主執行緒上會被 watchdog 砍掉（0x8BADF00D 黑畫面閃退）。
    /// 尚未下載的檔案改成觸發背景下載、本次視為讀不到，下次掃描自然補上。
    public static func safeRead(_ url: URL) -> String? {
        if let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           let status = v.ubiquitousItemDownloadingStatus {
            if status == .notDownloaded {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                return nil
            }
            if status == .downloaded {
                // 本機有一份但不是最新的（另一台裝置改過）：背景請 iCloud 抓，先回本機這份
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// 日記資料夾的佈局：`Journal/yyyy/MM/yyyy-MM-dd.md`。
public nonisolated enum JournalLayout {
    /// 所有日記檔與其日期（檔名不是 yyyy-MM-dd 的略過）。
    public static func journalFiles(journal: URL?) -> [(URL, Date)] {
        guard let journal,
              let enumerator = FileManager.default.enumerator(
                at: journal, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        var result: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard let day = df.date(from: url.deletingPathExtension().lastPathComponent)
            else { continue }
            result.append((url, day))
        }
        return result
    }
}
