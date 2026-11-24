import SwiftUI
import AVFoundation
#if os(macOS)
import AppKit
#endif

/// 蕃茄鐘計時中的動畫：Pixabay 上授權可用的 anime lofi 循環影片
/// （來源與授權見 `Resources/PomodoroScenes*/…-CREDITS.md`）。
/// 截一段、結尾淡入開頭，無縫循環播放；沒有聲音，不會打斷正在聽的音樂。
///
/// iPhone 用直的 4:5（`PomodoroScenes/pomo-scene-<rawValue>.mp4`）；
/// Mac 浮動面板用橫的 16:9（`PomodoroScenesWide/pomo-wide-<rawValue>.mp4`，不裁切），
/// 而且 Mac 多 15 支只有橫版的場景。兩個資料夾各自只打包進對應的 target。
///
/// 加一個新場景：照 CREDITS 的參數做影片放進資料夾，在這裡加 case、`title`、`symbol`，
/// 只有橫版的話也加進 `wideOnly`。
enum PomodoroScene: String, CaseIterable, Identifiable {
    case study, bedread, nightdesk, windowview, raincat, fireplacecat, traincat, sunsettrain, lakecamp, kettlecamp
    // 只有 Mac（橫版）
    case readcat, umbrella, nighttrain, desklamp, sunsetwrite, raincafe, lampcat, fireread,
         rainlaptop, heavyrain, sunrisecat, headphones, lamplaptop, raincabin, rainbook

    var id: String { rawValue }

    private static let wideOnly: Set<PomodoroScene> = [
        .readcat, .umbrella, .nighttrain, .desklamp, .sunsetwrite, .raincafe, .lampcat, .fireread,
        .rainlaptop, .heavyrain, .sunrisecat, .headphones, .lamplaptop, .raincabin, .rainbook,
    ]

    /// 這台裝置有影片的場景
    static var available: [PomodoroScene] {
        #if os(macOS)
        allCases
        #else
        allCases.filter { !wideOnly.contains($0) }
        #endif
    }

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
        case .readcat: return "窗邊看書與貓"
        case .umbrella: return "雨夜撐傘"
        case .nighttrain: return "夜車喝茶"
        case .desklamp: return "夜窗檯燈"
        case .sunsetwrite: return "黃昏寫字"
        case .raincafe: return "雨夜咖啡店"
        case .lampcat: return "檯燈下睡貓"
        case .fireread: return "壁爐邊看書"
        case .rainlaptop: return "雨夜筆電"
        case .heavyrain: return "大雨夜景"
        case .sunrisecat: return "日出看海的貓"
        case .headphones: return "戴耳機讀書"
        case .lamplaptop: return "檯燈與筆電"
        case .raincabin: return "雨天小木屋"
        case .rainbook: return "雨窗邊的書"
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
        case .readcat: return "book.pages"
        case .umbrella: return "umbrella"
        case .nighttrain: return "train.side.front.car"
        case .desklamp: return "lamp.table"
        case .sunsetwrite: return "sunset"
        case .raincafe: return "cup.and.saucer"
        case .lampcat: return "cat.fill"
        case .fireread: return "sofa"
        case .rainlaptop: return "laptopcomputer"
        case .heavyrain: return "cloud.heavyrain"
        case .sunrisecat: return "sunrise"
        case .headphones: return "headphones"
        case .lamplaptop: return "desktopcomputer"
        case .raincabin: return "house"
        case .rainbook: return "book.closed"
        }
    }

    var videoURL: URL? {
        #if os(macOS)
        Bundle.main.url(forResource: "pomo-wide-\(rawValue)", withExtension: "mp4")
        #else
        Bundle.main.url(forResource: "pomo-scene-\(rawValue)", withExtension: "mp4")
        #endif
    }

    /// 隨機挑一個，盡量不跟上一個一樣。
    static func random(excluding last: PomodoroScene?) -> PomodoroScene {
        let pool = available.filter { $0 != last }
        return pool.randomElement() ?? .study
    }

    var next: PomodoroScene {
        let all = Self.available
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
