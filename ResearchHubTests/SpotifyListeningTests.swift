// Spotify「最近播放／正在播放」回應 → 某段時間聽了哪些歌。純解析，不連網。
import XCTest
@testable import HubCore

final class SpotifyListeningTests: XCTestCase {
    private func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    private let recent = Data("""
    {"items":[
      {"track":{"id":"c","name":"Song C","artists":[{"name":"Nujabes"}],"external_urls":{"spotify":"https://open.spotify.com/track/c"}},"played_at":"2026-11-19T10:31:05.123Z"},
      {"track":{"id":"b","name":"Song B","artists":[{"name":"A"},{"name":"B"}]},"played_at":"2026-11-19T10:12:40Z"},
      {"track":{"id":"a","name":"Before","artists":[{"name":"X"}]},"played_at":"2026-11-19T09:59:00Z"}
    ],"next":null}
    """.utf8)

    func testRecentlyPlayedKeepsOnlyTheSessionOldestFirst() {
        let tracks = SpotifyListening.recentlyPlayed(recent, from: iso("2026-11-19T10:00:00Z"),
                                                     to: iso("2026-11-19T10:30:30Z"))
        // C 在結束後 35 秒播完，算在內（結束時通常剛好在聽它）
        XCTAssertEqual(tracks.map(\.name), ["Song B", "Song C"])
        XCTAssertEqual(tracks[0].line, "Song B — A, B")
        XCTAssertEqual(tracks[1].url?.absoluteString, "https://open.spotify.com/track/c")
    }

    func testCurrentlyPlayingAndMerge() {
        let now = iso("2026-11-19T10:40:00Z")
        let playing = Data(#"{"is_playing":true,"item":{"id":"d","name":"Live","artists":[{"name":"Y"}]}}"#.utf8)
        let paused = Data(#"{"is_playing":false,"item":{"id":"d","name":"Live","artists":[]}}"#.utf8)
        XCTAssertNil(SpotifyListening.currentlyPlaying(Data(), at: now))          // 204 沒內容
        XCTAssertNil(SpotifyListening.currentlyPlaying(paused, at: now))
        let current = SpotifyListening.currentlyPlaying(playing, at: now)
        XCTAssertEqual(current?.nowPlaying, true)

        let list = SpotifyListening.recentlyPlayed(recent, from: iso("2026-11-19T10:00:00Z"), to: now)
        XCTAssertEqual(SpotifyListening.merge(list, current: current).map(\.name), ["Song B", "Song C", "Live"])
    }

    func testGarbageResponsesGiveNothing() {
        XCTAssertTrue(SpotifyListening.recentlyPlayed(Data("{}".utf8), from: .distantPast, to: .now).isEmpty)
        XCTAssertNil(SpotifyListening.currentlyPlaying(Data("nope".utf8), at: .now))
    }
}
