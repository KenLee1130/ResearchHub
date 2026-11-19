#if os(iOS)
import SwiftUI
import AVFoundation

/// 蕃茄鐘計時中畫面中間的動畫：Pixabay 上授權可用的 anime lofi 循環影片
/// （來源與授權見 `Resources/PomodoroScenes/PomodoroScenes-CREDITS.md`）。
/// 影片已裁成 4:5、結尾淡入開頭，無縫循環播放；沒有聲音，不會打斷正在聽的音樂。
///
/// 加一個新場景：放一支 `pomo-scene-<rawValue>.mp4` 到資源資料夾，在這裡加 case、`title`、`symbol`。
enum PomodoroScene: String, CaseIterable, Identifiable {
    case study, bedread, nightdesk, windowview, raincat, fireplacecat, traincat, sunsettrain, lakecamp, kettlecamp

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .study: return "雨夜寫作業"
        case .bedread: return "床上看書"
        case .nightdesk: return "深夜書桌"
        case .windowview: return "窗邊看夜景"
        case .raincat: return "雨夜的貓"
        case .fireplacecat: return "壁爐邊的貓"
        case .traincat: return "火車上的貓"
        case .sunsettrain: return "黃昏電車"
        case .lakecamp: return "湖邊營火"
        case .kettlecamp: return "營火與茶壺"
        }
    }

    var symbol: String {
        switch self {
        case .study: return "pencil.and.scribble"
        case .bedread: return "book"
        case .nightdesk: return "lamp.desk"
        case .windowview: return "moon.stars"
        case .raincat: return "cloud.rain"
        case .fireplacecat: return "fireplace"
        case .traincat: return "cat"
        case .sunsettrain: return "tram"
        case .lakecamp: return "tent"
        case .kettlecamp: return "flame"
        }
    }

    var videoURL: URL? { Bundle.main.url(forResource: "pomo-scene-\(rawValue)", withExtension: "mp4") }

    /// 隨機挑一個，盡量不跟上一個一樣。
    static func random(excluding last: PomodoroScene?) -> PomodoroScene {
        let pool = allCases.filter { $0 != last }
        return pool.randomElement() ?? .study
    }

    var next: PomodoroScene {
        let all = Self.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }
}

/// 播場景影片。`paused` 時停在當下那一格（暫停蕃茄鐘時畫面也定格）。
struct PomodoroSceneView: View {
    let scene: PomodoroScene
    var paused = false

    var body: some View {
        LoopingVideo(url: scene.videoURL, paused: paused)
            .background(Color.black)
            .accessibilityLabel(Text(scene.title))
    }
}

/// AVPlayerLooper 包成 SwiftUI：填滿裁切、靜音、不搶音訊（Spotify 照常播）。
private struct LoopingVideo: UIViewRepresentable {
    let url: URL?
    let paused: Bool

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.load(url)
        view.setPaused(paused)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.load(url)
        view.setPaused(paused)
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.stop()
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private var current: URL?

        override init(frame: CGRect) {
            super.init(frame: frame)
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false   // 常亮由蕃茄鐘自己決定
            player.audiovisualBackgroundPlaybackPolicy = .pauses
            playerLayer?.player = player
            playerLayer?.videoGravity = .resizeAspectFill
        }

        required init?(coder: NSCoder) { nil }

        func load(_ url: URL?) {
            guard url != current else { return }
            current = url
            looper?.disableLooping()
            player.removeAllItems()
            guard let url else { return }
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        }

        func setPaused(_ paused: Bool) {
            if paused { player.pause() } else if player.rate == 0 { player.play() }
        }

        func stop() {
            player.pause()
            looper?.disableLooping()
            player.removeAllItems()
        }
    }
}
#endif
