// 守 .hub/contract-version 的契約：解析、支援區間、開資料夾時寫入。
import XCTest
@testable import ResearchHub
@testable import HubCore
@testable import HubStore

final class DataContractTests: XCTestCase {
    func testParseAndSupportedRange() {
        XCTAssertEqual(DataContract.parse("1\n"), 1)
        XCTAssertNil(DataContract.parse("one"))
        XCTAssertNil(DataContract.problem(with: "1", supported: 1...2))
        XCTAssertNotNil(DataContract.problem(with: "3", supported: 1...2), "比 app 新的契約要警告")
        XCTAssertNotNil(DataContract.problem(with: "x"))
        XCTAssertTrue(DataContract.supported.contains(DataContract.current), "app 要認得自己寫出的版本")
    }

    func testOpeningAFolderWritesContractVersionAndReadme() throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSystemStore(noteLinks: NoteLinkIndex(), librarySync: LibrarySync())
        store.adopt(root: root)   // 不走 setRoot：它會把書籤寫進測試宿主的 UserDefaults
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".hub/contract-version"), encoding: .utf8),
                       "\(DataContract.current)\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".hub/README.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Notes").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Journal").path))
        XCTAssertNil(store.errorMessage)
    }

    func testNewerContractWarnsButStillOpens() throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".hub"), withIntermediateDirectories: true)
        try "99\n".write(to: root.appendingPathComponent(".hub/contract-version"), atomically: true, encoding: .utf8)
        let store = FileSystemStore(noteLinks: NoteLinkIndex(), librarySync: LibrarySync())
        store.adopt(root: root)   // 不走 setRoot：它會把書籤寫進測試宿主的 UserDefaults
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.rootURL?.resolvingSymlinksInPath().path, root.path, "暫定：只警告、照開")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".hub/contract-version"), encoding: .utf8), "99\n", "不覆寫使用者的版本檔")
    }
}
