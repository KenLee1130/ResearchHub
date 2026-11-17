// 根資料夾書籤的還原：有效／stale／壞掉三種結果，以及 store 對每一種的反應。
// 背景：iPhone 對 iCloud 雲碟資料夾的書籤常被系統標 stale，以前一 stale 就放棄，
// 使用者開 app 就被打回「選擇資料夾」，看起來像被登出。
import XCTest
@testable import ResearchHub
@testable import HubCore
@testable import HubStore

final class RootBookmarkTests: XCTestCase {
    private struct Boom: Error {}

    /// 假解析器：不碰檔案系統，直接回指定的結果。
    private func resolver(url: URL, stale: Bool, minted: Data = Data("fresh".utf8),
                          failing: Bool = false) -> RootBookmark.Resolver {
        RootBookmark.Resolver(
            resolve: { _ in
                if failing { throw Boom() }
                return (url, stale)
            },
            mint: { _ in minted })
    }

    // MARK: - classify

    func testClassifyReadyStaleAndLost() {
        let url = URL(fileURLWithPath: "/tmp/lib", isDirectory: true)
        XCTAssertEqual(RootBookmark.classify(Data(), using: resolver(url: url, stale: false)), .ready(url))
        XCTAssertEqual(RootBookmark.classify(Data(), using: resolver(url: url, stale: true)), .stale(url))
        if case .lost = RootBookmark.classify(Data(), using: resolver(url: url, stale: false, failing: true)) {
        } else {
            XCTFail("解析丟錯誤要歸成 lost")
        }
    }

    func testSystemResolverRoundTripsARealFolder() throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try RootBookmark.Resolver.system.mint(root)
        guard case .ready(let url) = RootBookmark.classify(data) else {
            return XCTFail("剛做好的書籤應該直接有效")
        }
        XCTAssertEqual(url.resolvingSymlinksInPath().path, root.path)
    }

    // MARK: - FileSystemStore.restoreRoot

    func testStaleBookmarkStillOpensTheFolderAndSavesAFreshOne() throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSystemStore(noteLinks: NoteLinkIndex(), librarySync: LibrarySync())
        var saved: Data?
        store.restoreRoot(from: Data("old".utf8),
                          using: resolver(url: root, stale: true, minted: Data("fresh".utf8))) { saved = $0 }

        XCTAssertEqual(store.rootURL, root, "stale 的 URL 仍然有效，要照開")
        XCTAssertEqual(saved, Data("fresh".utf8), "並用新書籤蓋掉舊的")
        XCTAssertFalse(store.rootRestoreFailed)
    }

    func testStaleBookmarkOpensEvenWhenReMintingFails() throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSystemStore(noteLinks: NoteLinkIndex(), librarySync: LibrarySync())
        let cannotMint = RootBookmark.Resolver(resolve: { _ in (root, true) }, mint: { _ in throw Boom() })
        var saved: Data?
        store.restoreRoot(from: Data(), using: cannotMint) { saved = $0 }

        XCTAssertEqual(store.rootURL, root, "重製書籤失敗這次照用，下次再試")
        XCTAssertNil(saved)
    }

    func testUnresolvableBookmarkAsksToReselect() throws {
        let store = FileSystemStore(noteLinks: NoteLinkIndex(), librarySync: LibrarySync())
        var saved: Data?
        store.restoreRoot(from: Data(),
                          using: resolver(url: URL(fileURLWithPath: "/x"), stale: false, failing: true)) { saved = $0 }

        XCTAssertNil(store.rootURL)
        XCTAssertTrue(store.rootRestoreFailed, "選資料夾的畫面要說是授權失效，不是第一次開 app")
        XCTAssertNil(saved)
    }

    func testChoosingAFolderClearsTheFailureFlag() throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSystemStore(noteLinks: NoteLinkIndex(), librarySync: LibrarySync())
        store.restoreRoot(from: Data(),
                          using: resolver(url: root, stale: false, failing: true)) { _ in }
        XCTAssertTrue(store.rootRestoreFailed)
        store.adopt(root: root)
        XCTAssertFalse(store.rootRestoreFailed)
    }
}
