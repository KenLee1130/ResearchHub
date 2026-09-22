#if os(macOS)
import SwiftUI
import AppKit

/// 包裝 NSVisualEffectView，強制 behind-window blur（透出視窗後方的桌布/視窗）。
/// state = .active 讓視窗非作用中時也保持玻璃效果。
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}

/// 內容區的環境背景：桌布 behind-window 模糊 + 色彩場。
/// 玻璃（.glassEffect / material）需要背後有顏色才有通透感，這就是顏色的來源。
///
/// 色彩場刻意是「靜止」的：以前用 TimelineView 以 6fps 永遠在緩慢流動，
/// 但上面疊的每一塊 liquid glass 都要取樣背景，背景每動一格所有玻璃就得重新合成——
/// 實測 app 閒置時一直吃 ~25% CPU、在背景也照跑（系統記了三份 cpu_resource 報告），
/// 打字時跟主執行緒搶資源。流動慢到幾乎看不出來，定格成一幀視覺上沒差。
struct AmbientBackground: View {
    /// 定格的相位（取原本動畫中構圖最平衡的一刻）
    private static let t: Double = 7.0

    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.ambient.rawValue

    var body: some View {
        if AppTheme(rawValue: themeRaw) == .ink {
            // 墨黑主題：不透桌布、不上漸層，純粹的底色。
            // 一點點 highlight 留在左上角，免得整片死黑失去深度。
            ZStack {
                InkPalette.canvas
                RadialGradient(
                    colors: [Color.white.opacity(0.035), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 720)
            }
            .ignoresSafeArea()
        } else {
            ambient
        }
    }

    private var ambient: some View {
        let t = Self.t
        return ZStack {
            VisualEffectView(material: .underWindowBackground, blending: .behindWindow)
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5],
                    [Float(0.5 + 0.18 * sin(t * 0.13)), Float(0.5 + 0.18 * cos(t * 0.11))],
                    [1, 0.5],
                    [0, 1], [Float(0.5 + 0.15 * cos(t * 0.09)), 1], [1, 1]
                ],
                colors: [
                    .clear, Color.purple.opacity(0.22), .clear,
                    Color.teal.opacity(0.18), Color.blue.opacity(0.24), Color.indigo.opacity(0.20),
                    .clear, Color.cyan.opacity(0.14), .clear
                ]
            )
        }
        .ignoresSafeArea()
    }
}
#endif
