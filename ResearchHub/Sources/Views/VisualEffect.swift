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

/// 內容區的環境背景：桌布 behind-window 模糊 + 緩慢流動的色彩場。
/// 玻璃（.glassEffect / material）需要背後有顏色才有通透感，這就是顏色的來源。
struct AmbientBackground: View {
    var body: some View {
        ZStack {
            VisualEffectView(material: .underWindowBackground, blending: .behindWindow)
            // 色彩場流動很慢,不需要高更新率。降到 ~6fps 大幅減少持續的 GPU 重繪,
            // 視覺幾乎無差,但側欄開合／拖曳時不再和它搶資源,整體更順、也更省電。
            TimelineView(.animation(minimumInterval: 1.0 / 6.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
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
        }
        .ignoresSafeArea()
    }
}
