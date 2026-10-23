import Foundation
import HubStore
import HubCore

/// 「筆記互相引用」的索引：列出 Notes/ 下所有筆記，供 `[[...]]` 自動補全與點擊解析。
///
/// 寫筆記時用 `[[另一份筆記]]` 或 `[[資料夾/筆記|顯示文字]]` 連到別的筆記；
/// 預覽中點該連結即可開啟對應筆記（透過 researchhub://note 內部協定，由
/// MarkdownPreviewView 攔截處理）。
@MainActor
public final class NoteLinkIndex {
    public init() {}


    /// Notes/ 根目錄；由 FileSystemStore 設定。
    public var notesRoot: URL? {
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
    public func entries() -> [NoteLink] {
        if Date().timeIntervalSince(lastScan) > 2 { rescan() }
        return cache
    }

    /// 強制下次取用時重掃（檔案新增／改名／移動／刪除後呼叫）。
    public func invalidate() { lastScan = .distantPast }

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

    /// 解析 `[[target]]` 的目標（純函式，本體在 HubCore 的 NoteLinkResolver）。
    public nonisolated static func resolve(_ target: String, in links: [NoteLink]) -> NoteLink? {
        NoteLinkResolver.resolve(target, in: links)
    }

    /// 由相對路徑取回檔案 URL（供預覽點擊開啟）。
    public func url(forRelativePath rel: String) -> URL? {
        guard let root = notesRoot else { return nil }
        let url = root.appendingPathComponent(rel)
        return fm.fileExists(atPath: url.path) ? url : nil
    }
}
