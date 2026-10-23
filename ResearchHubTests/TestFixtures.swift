import Foundation
import XCTest

/// 測試用暫存目錄：每個測試自建、用完刪掉，絕不碰使用者的 iCloud 資料夾。
enum TestFixtures {
    static func makeTempDir(_ name: String = #function) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResearchHubTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // /var → /private/var 這類符號連結先解掉，之後比對路徑才一致
        return base.resolvingSymlinksInPath()
    }

    /// 在 root 底下寫一個文字檔（自動建中間資料夾），回傳其 URL。
    @discardableResult
    static func write(_ text: String, at relative: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
