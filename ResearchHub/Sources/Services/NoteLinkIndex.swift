import Foundation

/// 一筆「可被引用的筆記」。供 [[...]] 自動補全、預覽解析與插入挑選器共用。
/// 只含值型別，方便傳進非主執行緒隔離的 NotePreprocessor。
struct NoteLink: Hashable, Sendable {
    let url: URL
    /// 相對於 Notes/ 的路徑（含 .md）
    let relativePath: String

    /// 檔名（不含副檔名）
    var name: String { url.deletingPathExtension().lastPathComponent }

    /// 顯示用：相對路徑去掉 .md，便於分辨不同資料夾下的同名筆記。
    var displayPath: String {
        relativePath.lowercased().hasSuffix(".md")
            ? String(relativePath.dropLast(3))
            : relativePath
    }
}

/// 「筆記互相引用」的索引：列出 Notes/ 下所有筆記，供 `[[...]]` 自動補全與點擊解析。
///
/// 寫筆記時用 `[[另一份筆記]]` 或 `[[資料夾/筆記|顯示文字]]` 連到別的筆記；
/// 預覽中點該連結即可開啟對應筆記（透過 researchhub://note 內部協定，由
/// MarkdownPreviewView 攔截處理）。
@MainActor
final class NoteLinkIndex {
    static let shared = NoteLinkIndex()

    /// Notes/ 根目錄；由 FileSystemStore 設定。
    var notesRoot: URL? {
        didSet {
            if notesRoot != oldValue {
                cache = []
                lastScan = .distantPast
            }
        }
    }

    private var cache: [NoteLink] = []
    private var lastScan = Date.distantPast
    private let fm = FileManager.default

    /// 所有筆記（每 2 秒最多重掃一次磁碟，避免每次按鍵都掃）。
    func entries() -> [NoteLink] {
        if Date().timeIntervalSince(lastScan) > 2 { rescan() }
        return cache
    }

    /// 強制下次取用時重掃（檔案新增／改名／移動／刪除後呼叫）。
    func invalidate() { lastScan = .distantPast }

    private func rescan() {
        lastScan = Date()
        guard let root = notesRoot,
              let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else {
            cache = []
            return
        }
        let rootPath = root.path
        var result: [NoteLink] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard url.deletingLastPathComponent().lastPathComponent != "assets" else { continue }
            let rel = url.path.hasPrefix(rootPath + "/")
                ? String(url.path.dropFirst(rootPath.count + 1))
                : url.lastPathComponent
            result.append(NoteLink(url: url, relativePath: rel))
        }
        cache = result.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    /// 解析 `[[target]]` 的目標：先比對相對路徑／顯示路徑，再比對檔名（皆不分大小寫）。
    /// 純函式（只看傳入的 links），標 nonisolated 讓非主執行緒的前處理器也能呼叫。
    nonisolated static func resolve(_ target: String, in links: [NoteLink]) -> NoteLink? {
        let t = target.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let tl = t.lowercased()
        let tlMd = tl.hasSuffix(".md") ? tl : tl + ".md"
        if let e = links.first(where: {
            $0.relativePath.lowercased() == tlMd || $0.displayPath.lowercased() == tl
        }) { return e }
        if let e = links.first(where: { $0.name.lowercased() == tl }) { return e }
        return nil
    }

    /// 由相對路徑取回檔案 URL（供預覽點擊開啟）。
    func url(forRelativePath rel: String) -> URL? {
        guard let root = notesRoot else { return nil }
        let url = root.appendingPathComponent(rel)
        return fm.fileExists(atPath: url.path) ? url : nil
    }
}
