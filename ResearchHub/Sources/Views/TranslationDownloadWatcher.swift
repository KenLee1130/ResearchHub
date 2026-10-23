#if os(macOS)
import SwiftUI
import HubCore
import PDFKit
import CoreImage
import Combine
import UniformTypeIdentifiers

/// 盯著「下載」資料夾：開始之後新出現的 PDF（下載完、大小不再變）就交給 onFound。
/// 檔名有原文 PDF 的前幾個字的優先（沈浸式翻譯的輸出檔名會沿用原檔名）。最多等 30 分鐘。
@Observable
@MainActor
final class TranslationDownloadWatcher {
    private(set) var isWatching = false
    @ObservationIgnored private var task: Task<Void, Never>?

    static var downloadsURL: URL {
        URL(fileURLWithPath: "/Users/\(NSUserName())/Downloads", isDirectory: true)
    }

    func start(nameHint: String?, onFound: @escaping @MainActor (URL) -> Void) {
        stop()
        isWatching = true
        let dir = Self.downloadsURL
        let before = Set(Self.pdfs(in: dir).map(\.path))
        let hint = nameHint.map { String($0.prefix(20)).lowercased() }
        task = Task { [weak self] in
            var lastSizes: [String: Int] = [:]
            for _ in 0..<600 {   // 3 秒一次，30 分鐘
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                let fresh = Self.pdfs(in: dir).filter { !before.contains($0.path) }
                let ranked = fresh.sorted { a, b in
                    let ma = hint.map { a.lastPathComponent.lowercased().contains($0) } ?? false
                    let mb = hint.map { b.lastPathComponent.lowercased().contains($0) } ?? false
                    return ma && !mb
                }
                for url in ranked {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    defer { lastSizes[url.path] = size }
                    // 大小連續兩次一樣才算下載完
                    if size > 0, lastSizes[url.path] == size {
                        self?.isWatching = false
                        onFound(url)
                        return
                    }
                }
            }
            self?.isWatching = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isWatching = false
    }

    private static func pdfs(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "pdf" }
    }
}
#endif
