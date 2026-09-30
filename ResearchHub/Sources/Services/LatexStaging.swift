#if os(macOS)
import Foundation
import CryptoKit

/// 沙盒外小幫手的工作區。
///
/// 小幫手是被 com.apple.foundation.UserScriptService 執行的，那個 XPC 服務**沒有 iCloud Drive
/// 的存取權**：只要去 open() 一個 ~/Library/Mobile Documents 底下的路徑，就會被 file provider
/// 無限期擋住——不回錯誤、也不跳權限視窗，整支腳本就這樣掛在那裡。
/// （從終端機跑同一行沒事，是因為終端機有完全磁碟取用權限。）
///
/// 所以規矩是：**小幫手只准碰純本機路徑**，iCloud 那側的讀寫一律由 app 自己做。
/// 編譯時把專案原始檔鏡射到 app 容器的 Caches/latex/<雜湊>/src，小幫手在那裡編譯，
/// 成品 PDF 再由 app 搬回 <專案>/.researchhub/output.pdf。
nonisolated enum LatexStaging {
    /// LaTeX 的編譯中間檔。鏡射時不能因為「專案裡沒有」就把它們刪掉——
    /// latexmk 要靠這些檔案做增量編譯。
    static let artifactExtensions: Set<String> = [
        "aux", "log", "pdf", "fls", "fdb_latexmk", "gz", "out", "toc", "lof", "lot",
        "bbl", "blg", "bcf", "xml", "xdv", "nav", "snm", "vrb", "idx", "ind", "ilg", "dvi"
    ]

    /// app 容器裡的編譯工作區（用專案路徑的雜湊當資料夾名，每個專案各自獨立）。
    static func workDir(for project: URL) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let digest = SHA256.hash(data: Data(project.standardizedFileURL.path.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        return caches.appendingPathComponent("latex/\(digest)/src", isDirectory: true)
    }

    /// 一次性的暫存資料夾（匯入 zip、打包匯出用完就丟）。
    static func scratchDir() throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("latex/scratch/\(UUID().uuidString)",
                                                isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 專案 → 工作區的單向鏡射（大小或修改時間不一樣才複製）。
    static func sync(project: URL, to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var wanted = Set<String>()
        guard let walker = fm.enumerator(at: project, includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return }

        for case let url as URL in walker {
            let rel = relative(url, under: project)
            guard !rel.isEmpty else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let target = dest.appendingPathComponent(rel)
            if values?.isDirectory == true {
                wanted.insert(rel)
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            wanted.insert(rel)
            if let old = try? target.resourceValues(forKeys: [.fileSizeKey,
                                                             .contentModificationDateKey]),
               old.fileSize == values?.fileSize,
               let a = old.contentModificationDate, let b = values?.contentModificationDate,
               abs(a.timeIntervalSince(b)) < 1 {
                continue
            }
            try? fm.createDirectory(at: target.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: url, to: target)
        }

        // 專案裡已經刪掉的來源檔，工作區也要跟著刪（中間檔留著）
        guard let cleaner = fm.enumerator(at: dest, includingPropertiesForKeys: [.isDirectoryKey],
                                          options: [.skipsPackageDescendants]) else { return }
        var staleDirs: [URL] = []
        for case let url as URL in cleaner {
            let rel = relative(url, under: dest)
            guard !rel.isEmpty, !wanted.contains(rel) else { continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                staleDirs.append(url)
            } else if !artifactExtensions.contains(url.pathExtension.lowercased()) {
                try? fm.removeItem(at: url)
            }
        }
        // 深的先刪，空了才刪得掉；裡面還有中間檔的就留著
        for dir in staleDirs.sorted(by: { $0.path.count > $1.path.count }) {
            if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                try? fm.removeItem(at: dir)
            }
        }
    }

    /// 把整棵樹複製過去（匯入專案用；略過 .researchhub 與 .DS_Store 之類的隱藏檔）。
    static func copyTree(from src: URL, to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        guard let walker = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return }
        for case let url as URL in walker {
            let rel = relative(url, under: src)
            guard !rel.isEmpty else { continue }
            let target = dest.appendingPathComponent(rel)
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try? fm.createDirectory(at: target.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                try? fm.removeItem(at: target)
                try fm.copyItem(at: url, to: target)
            }
        }
    }

    private static func relative(_ url: URL, under base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(basePath + "/") else { return "" }
        return String(path.dropFirst(basePath.count + 1))
    }
}
#endif
