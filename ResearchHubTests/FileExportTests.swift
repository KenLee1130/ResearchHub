// 守 commit 7855ff6：匯出的 PDF 在 Finder 看不到（帶了隱藏旗標）。
import XCTest
@testable import ResearchHub
@testable import HubCore

final class FileExportTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try TestFixtures.makeTempDir()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 模擬 .researchhub/ 裡被 iCloud 標成隱藏的編譯檔
    private func makeHiddenSource() throws -> (url: URL, data: Data) {
        let data = Data("%PDF-1.7\n%fake\n".utf8)
        let src = dir.appendingPathComponent(".researchhub/output.pdf")
        try FileManager.default.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: src)
        var values = URLResourceValues()
        values.isHidden = true
        var hidden = src
        try hidden.setResourceValues(values)
        XCTAssertEqual(try src.resourceValues(forKeys: [.isHiddenKey]).isHidden, true, "前提：來源要先是隱藏的")
        return (src, data)
    }

    private func isHidden(_ url: URL) throws -> Bool {
        var probe = url
        probe.removeAllCachedResourceValues()
        return try probe.resourceValues(forKeys: [.isHiddenKey]).isHidden ?? false
    }

    func testFreshCopyIsVisibleAndIdentical() throws {
        let (src, data) = try makeHiddenSource()
        let dest = dir.appendingPathComponent("Exported.pdf")
        try FileExport.writeFreshCopy(of: src, to: dest)
        XCTAssertEqual(try Data(contentsOf: dest), data)
        XCTAssertFalse(try isHidden(dest), "匯出的檔不能帶隱藏旗標")
    }

    func testFreshCopyOverwritesExistingDestination() throws {
        let (src, data) = try makeHiddenSource()
        let dest = dir.appendingPathComponent("Exported.pdf")
        try Data("old".utf8).write(to: dest)
        try FileExport.writeFreshCopy(of: src, to: dest)
        XCTAssertEqual(try Data(contentsOf: dest), data)
    }

    func testCopyVisibleClearsHiddenFlagAndRefreshesDate() throws {
        let (src, data) = try makeHiddenSource()
        let old = Date(timeIntervalSinceNow: -86_400 * 30)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: src.path)
        let dest = dir.appendingPathComponent("Downloaded.pdf")
        try FileExport.copyVisible(src, to: dest)
        XCTAssertEqual(try Data(contentsOf: dest), data)
        XCTAssertFalse(try isHidden(dest))
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: dest.path)[.modificationDate] as? Date)
        XCTAssertLessThan(abs(modified.timeIntervalSinceNow), 60, "下載出來的檔日期要是現在")
    }
}
