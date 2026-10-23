import Foundation

/// 把 app 裡的檔案拿出去給使用者（匯出 PDF、側欄「下載」）。
///
/// 來源常帶「隱藏」旗標：`.researchhub/` 裡的編譯檔會被 iCloud 標成 hidden，
/// 直接 `copyItem` 會把旗標（與舊日期）一起帶過去，Finder 根本看不到匯出的檔。
nonisolated enum FileExport {
    /// 讀出內容寫成全新的檔案，不沿用來源的旗標與日期（匯出 PDF 用）。
    static func writeFreshCopy(of source: URL, to dest: URL) throws {
        let data = try Data(contentsOf: source)
        try data.write(to: dest, options: .atomic)
    }

    /// 複製（檔案或資料夾）後把日期設成現在、清掉隱藏旗標（側欄「下載」用）。
    static func copyVisible(_ source: URL, to dest: URL) throws {
        try FileManager.default.copyItem(at: source, to: dest)
        // 下載出來的是新檔案：日期設成現在，「下載項目」依日期排序時才會在最上面
        let now = Date()
        try? FileManager.default.setAttributes(
            [.creationDate: now, .modificationDate: now], ofItemAtPath: dest.path)
        var values = URLResourceValues()
        values.isHidden = false
        var visible = dest
        try? visible.setResourceValues(values)
    }
}
