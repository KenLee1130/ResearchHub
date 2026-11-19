import Foundation

/// 一首聽過的歌（Spotify Web API 回來的資料整理成這樣）。
public struct SpotifyTrack: Identifiable, Equatable, Sendable {
    public var id: String { "\(playedAt.timeIntervalSince1970)-\(trackID)" }
    public let trackID: String
    public let name: String
    public let artists: [String]
    /// Spotify 記的播放時刻（實測是那首播完／切走的時刻）；正在播的那首用查詢當下
    public let playedAt: Date
    /// 還在播，還沒進「最近播放」
    public let nowPlaying: Bool
    public let url: URL?

    public init(trackID: String, name: String, artists: [String], playedAt: Date,
                nowPlaying: Bool = false, url: URL? = nil) {
        self.trackID = trackID; self.name = name; self.artists = artists
        self.playedAt = playedAt; self.nowPlaying = nowPlaying; self.url = url
    }

    /// 寫進蕃茄鐘紀錄的那一行：「歌名 — 歌手」
    public var line: String {
        artists.isEmpty ? name : "\(name) — \(artists.joined(separator: ", "))"
    }
}

/// 把 Spotify 的「最近播放」「正在播放」整理成某段時間聽過的歌。純解析、不連網，可以測。
public enum SpotifyListening {

    private struct Artist: Decodable { let name: String }
    private struct ExternalURLs: Decodable { let spotify: String? }
    private struct Track: Decodable {
        let id: String?
        let name: String
        let artists: [Artist]
        let external_urls: ExternalURLs?
    }
    private struct PlayHistory: Decodable {
        let track: Track
        let played_at: String
    }
    private struct RecentlyPlayed: Decodable { let items: [PlayHistory] }
    private struct CurrentlyPlaying: Decodable {
        let is_playing: Bool
        let item: Track?
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private static func track(_ t: Track, at date: Date, nowPlaying: Bool) -> SpotifyTrack {
        SpotifyTrack(trackID: t.id ?? t.name, name: t.name, artists: t.artists.map(\.name),
                     playedAt: date, nowPlaying: nowPlaying,
                     url: t.external_urls?.spotify.flatMap(URL.init(string:)))
    }

    /// `GET /v1/me/player/recently-played` 的回應 → 落在 (start, end] 的歌，舊到新。
    /// played_at 是播完的時刻，所以結束後一分鐘內播完的也算（按結束時那首通常還差一點）。
    public static func recentlyPlayed(_ data: Data, from start: Date, to end: Date) -> [SpotifyTrack] {
        guard let decoded = try? JSONDecoder().decode(RecentlyPlayed.self, from: data) else { return [] }
        return decoded.items.compactMap { item -> SpotifyTrack? in
            guard let date = parseDate(item.played_at), date > start, date <= end.addingTimeInterval(60)
            else { return nil }
            return track(item.track, at: date, nowPlaying: false)
        }
        .sorted { $0.playedAt < $1.playedAt }
    }

    /// `GET /v1/me/player/currently-playing` 的回應（204 沒內容時傳空 Data）→ 正在播的那首。
    public static func currentlyPlaying(_ data: Data, at now: Date) -> SpotifyTrack? {
        guard !data.isEmpty,
              let decoded = try? JSONDecoder().decode(CurrentlyPlaying.self, from: data),
              decoded.is_playing, let item = decoded.item else { return nil }
        return track(item, at: now, nowPlaying: true)
    }

    /// 合併：最近播放＋正在播的那首（如果它不是剛好最後一首）。
    public static func merge(_ recent: [SpotifyTrack], current: SpotifyTrack?) -> [SpotifyTrack] {
        guard let current else { return recent }
        if let last = recent.last, last.trackID == current.trackID,
           current.playedAt.timeIntervalSince(last.playedAt) < 30 { return recent }
        return recent + [current]
    }
}
