import SwiftUI
import AVFoundation
#if os(macOS)
import AppKit
#endif

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

/// AVPlayerLooper：填滿裁切、靜音、不搶音訊（Spotify 照常播）。iPhone、Mac 共用。
final class LoopingPlayer {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var current: URL?
    private var wantsPlay = false
    /// Mac：視窗被蓋住／縮到 Dock 時不解碼
    var hidden = false { didSet { apply() } }

    init() {
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false   // 常亮由蕃茄鐘自己決定
        player.audiovisualBackgroundPlaybackPolicy = .pauses
    }

    func load(_ url: URL?) {
        guard url != current else { return }
        current = url
        looper?.disableLooping()
        player.removeAllItems()
        guard let url else { return }
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        apply()
    }

    func setPaused(_ paused: Bool) {
        wantsPlay = !paused
        apply()
    }

    private func apply() {
        if wantsPlay && !hidden {
            if player.rate == 0 { player.play() }
        } else {
            player.pause()
        }
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        player.removeAllItems()
    }
}

#if os(iOS)
private struct LoopingVideo: UIViewRepresentable {
    let url: URL?
    let paused: Bool

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.looping.load(url)
        view.looping.setPaused(paused)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.looping.load(url)
        view.looping.setPaused(paused)
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.looping.stop()
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        let looping = LoopingPlayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            let layer = layer as? AVPlayerLayer
            layer?.player = looping.player
            layer?.videoGravity = .resizeAspectFill
        }

        required init?(coder: NSCoder) { nil }
    }
}
#else
private struct LoopingVideo: NSViewRepresentable {
    let url: URL?
    let paused: Bool

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.looping.load(url)
        view.looping.setPaused(paused)
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        view.looping.load(url)
        view.looping.setPaused(paused)
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) {
        view.looping.stop()
    }

    final class PlayerView: NSView {
        let looping = LoopingPlayer()
        private let playerLayer = AVPlayerLayer()
        private var occlusionObserver: NSObjectProtocol?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.player = looping.player
            playerLayer.videoGravity = .resizeAspectFill
            layer = playerLayer
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
            occlusionObserver = nil
            guard let window else { return }
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateHidden() }
            }
            updateHidden()
        }

        private func updateHidden() {
            looping.hidden = !(window?.occlusionState.contains(.visible) ?? false)
        }

        deinit {
            if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        }
    }
}
#endif
