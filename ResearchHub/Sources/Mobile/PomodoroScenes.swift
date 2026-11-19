#if os(iOS)
import SwiftUI

/// 蕃茄鐘計時中畫面中間的動畫。全部用 Canvas 即時畫（沒有圖檔），
/// 以秒數 `t` 推出每一格的畫面，所以停在哪一秒都畫得出來、不會越跑越飄。
///
/// 加一個新場景：在 enum 加 case、`title`／`symbol`，再寫一個 `drawXxx(ctx, size, t)`。
enum PomodoroScene: String, CaseIterable, Identifiable {
    case walker, lofi, rain, campfire, cat

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .walker: return "黃昏散步"
        case .lofi: return "Lofi 讀書"
        case .rain: return "雨夜窗邊"
        case .campfire: return "營火"
        case .cat: return "午睡的貓"
        }
    }

    var symbol: String {
        switch self {
        case .walker: return "figure.walk"
        case .lofi: return "book"
        case .rain: return "cloud.rain"
        case .campfire: return "flame"
        case .cat: return "cat"
        }
    }

    /// 隨機挑一個，盡量不跟上一個一樣。
    static func random(excluding last: PomodoroScene?) -> PomodoroScene {
        let pool = allCases.filter { $0 != last }
        return pool.randomElement() ?? .lofi
    }

    var next: PomodoroScene {
        let all = Self.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }
}

/// 把場景畫出來。`paused` 時停在當下那一格（暫停蕃茄鐘時畫面也定格）。
struct PomodoroSceneView: View {
    let scene: PomodoroScene
    var paused = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 100_000)
            Canvas { ctx, size in
                switch scene {
                case .walker: SceneArt.walker(&ctx, size, t)
                case .lofi: SceneArt.lofi(&ctx, size, t)
                case .rain: SceneArt.rain(&ctx, size, t)
                case .campfire: SceneArt.campfire(&ctx, size, t)
                case .cat: SceneArt.cat(&ctx, size, t)
                }
            }
        }
        .accessibilityLabel(Text(scene.title))
    }
}

// MARK: - 繪圖

private enum SceneArt {

    /// 固定的偽亂數（同一個 i 每一格都一樣，畫面才不會閃）
    static func rnd(_ i: Int, _ salt: Int = 0) -> Double {
        var x = UInt64(truncatingIfNeeded: i &* 374_761_393 &+ salt &* 668_265_263)
        x = (x ^ (x >> 13)) &* 1_274_126_177
        x = x ^ (x >> 16)
        return Double(x % 10_000) / 10_000
    }

    static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255, opacity: a)
    }

    static func vertical(_ colors: [Color], _ rect: CGRect) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: rect.midX, y: rect.minY),
                        endPoint: CGPoint(x: rect.midX, y: rect.maxY))
    }

    static func glow(_ ctx: inout GraphicsContext, at p: CGPoint, radius: Double, color: Color) {
        let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
        ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: [color, color.opacity(0)]), center: p, startRadius: 0, endRadius: radius))
    }

    /// 一條地平線輪廓（多個正弦疊起來），往左捲 `offset` 點
    static func ridge(_ size: CGSize, base: Double, amp: Double, offset: Double, freq: Double, seed: Double) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: size.height))
        var x = 0.0
        while x <= size.width + 4 {
            let u = x + offset
            let y = base - amp * (0.6 * sin(u * freq + seed) + 0.3 * sin(u * freq * 2.3 + seed * 2)
                                  + 0.1 * sin(u * freq * 5.1))
            p.addLine(to: CGPoint(x: x, y: y))
            x += 4
        }
        p.addLine(to: CGPoint(x: size.width, y: size.height))
        p.closeSubpath()
        return p
    }

    static func line(_ a: CGPoint, _ b: CGPoint) -> Path {
        var p = Path()
        p.move(to: a)
        p.addLine(to: b)
        return p
    }

    // MARK: 黃昏散步：一個人一直往右走，山和樹往後退

    static func walker(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let W = size.width, H = size.height
        let all = CGRect(origin: .zero, size: size)
        ctx.fill(Path(all), with: vertical([hex(0x2B2D5C), hex(0x8A4F7D), hex(0xF08A5D), hex(0xF9C784)], all))

        // 太陽與光暈
        let sun = CGPoint(x: W * 0.72, y: H * 0.5)
        glow(&ctx, at: sun, radius: W * 0.35, color: hex(0xFFD29D, 0.55))
        ctx.fill(Path(ellipseIn: CGRect(x: sun.x - W * 0.09, y: sun.y - W * 0.09, width: W * 0.18, height: W * 0.18)),
                 with: .color(hex(0xFFE3B5)))

        // 雲（很慢）
        for i in 0..<3 {
            let speed = 6 + rnd(i, 3) * 6
            let x = (rnd(i, 1) * (W + 160) - t * speed).truncatingRemainder(dividingBy: W + 160)
            let cx = x < -80 ? x + W + 160 : x
            let cy = H * (0.12 + rnd(i, 2) * 0.2)
            for k in 0..<3 {
                let r = W * (0.05 + 0.02 * Double(k % 2))
                ctx.fill(Path(ellipseIn: CGRect(x: cx + Double(k) * r * 0.9, y: cy - r * 0.5, width: r * 2, height: r)),
                         with: .color(.white.opacity(0.18)))
            }
        }

        // 鳥
        for i in 0..<3 {
            let period = 18.0 + Double(i) * 5
            let u = ((t + Double(i) * 7) / period).truncatingRemainder(dividingBy: 1)
            let bx = W * (1.1 - u * 1.3), by = H * (0.2 + 0.08 * Double(i)) + sin(t * 1.5 + Double(i)) * 4
            let flap = sin(t * 8 + Double(i)) * 3
            var b = Path()
            b.move(to: CGPoint(x: bx - 6, y: by - flap))
            b.addLine(to: CGPoint(x: bx, y: by))
            b.addLine(to: CGPoint(x: bx + 6, y: by - flap))
            ctx.stroke(b, with: .color(hex(0x3A2340, 0.7)), lineWidth: 1.4)
        }

        ctx.fill(ridge(size, base: H * 0.6, amp: H * 0.07, offset: t * 6, freq: 0.012, seed: 1), with: .color(hex(0x9B5E7E)))
        ctx.fill(ridge(size, base: H * 0.7, amp: H * 0.05, offset: t * 18, freq: 0.02, seed: 4), with: .color(hex(0x5A3A5E)))

        // 地面
        let groundY = H * 0.8
        ctx.fill(Path(CGRect(x: 0, y: groundY, width: W, height: H - groundY)), with: .color(hex(0x2A1D33)))

        // 樹（走的速度）
        let speed = 42.0
        let spacing = 120.0
        let count = Int(W / spacing) + 3
        for i in 0..<count {
            let shift = (t * speed).truncatingRemainder(dividingBy: spacing)
            let idx = Int(t * speed / spacing) + i
            let x = Double(i) * spacing - shift + rnd(idx, 5) * 40
            let h = H * (0.16 + rnd(idx, 6) * 0.12)
            let trunk = CGRect(x: x - 2.5, y: groundY - h * 0.25, width: 5, height: h * 0.25)
            ctx.fill(Path(trunk), with: .color(hex(0x1A1124)))
            var crown = Path()
            crown.move(to: CGPoint(x: x, y: groundY - h))
            crown.addLine(to: CGPoint(x: x - h * 0.28, y: groundY - h * 0.2))
            crown.addLine(to: CGPoint(x: x + h * 0.28, y: groundY - h * 0.2))
            crown.closeSubpath()
            ctx.fill(crown, with: .color(hex(0x1A1124)))
        }

        // 路上的虛線
        let dash = 34.0
        let dShift = (t * speed).truncatingRemainder(dividingBy: dash)
        var x = -dShift
        while x < W {
            ctx.fill(Path(CGRect(x: x, y: H * 0.9, width: dash * 0.45, height: 2)), with: .color(hex(0xF9C784, 0.35)))
            x += dash
        }

        // 人（剪影）
        let s = H * 0.22
        let cx = W * 0.42
        let p = t * 4.2
        let bob = abs(sin(p)) * s * 0.025
        let feetY = H * 0.86
        let hip = CGPoint(x: cx, y: feetY - s * 0.46 - bob)
        let shoulder = CGPoint(x: cx + s * 0.04, y: feetY - s * 0.8 - bob)
        let ink = GraphicsContext.Shading.color(hex(0x120B18))
        let style = StrokeStyle(lineWidth: s * 0.075, lineCap: .round, lineJoin: .round)

        func limb(from a: CGPoint, length: Double, angle: Double, bend: Double) -> Path {
            let knee = CGPoint(x: a.x + sin(angle) * length * 0.5, y: a.y + cos(angle) * length * 0.5)
            let foot = CGPoint(x: knee.x + sin(angle - bend) * length * 0.5, y: knee.y + cos(angle - bend) * length * 0.5)
            var path = Path()
            path.move(to: a)
            path.addLine(to: knee)
            path.addLine(to: foot)
            return path
        }
        // 後面那隻腳、手先畫（淡一點）
        let swing = sin(p) * 0.5
        ctx.stroke(limb(from: hip, length: s * 0.48, angle: -swing, bend: max(0, sin(p + .pi)) * 0.6),
                   with: .color(hex(0x2A1D33)), style: style)
        ctx.stroke(limb(from: shoulder, length: s * 0.36, angle: swing * 0.8, bend: -0.3),
                   with: .color(hex(0x2A1D33)), style: style)
        // 背包
        ctx.fill(Path(roundedRect: CGRect(x: shoulder.x - s * 0.2, y: shoulder.y + s * 0.02, width: s * 0.14, height: s * 0.24),
                      cornerRadius: s * 0.04), with: ink)
        ctx.stroke(line(hip, shoulder), with: ink, style: StrokeStyle(lineWidth: s * 0.12, lineCap: .round))
        ctx.stroke(limb(from: hip, length: s * 0.48, angle: swing, bend: max(0, sin(p)) * 0.6), with: ink, style: style)
        ctx.stroke(limb(from: shoulder, length: s * 0.36, angle: -swing * 0.8, bend: -0.3), with: ink, style: style)
        let headR = s * 0.1
        ctx.fill(Path(ellipseIn: CGRect(x: shoulder.x - headR + s * 0.02, y: shoulder.y - headR * 2.3,
                                        width: headR * 2, height: headR * 2)), with: ink)
    }

    // MARK: Lofi 讀書：窗外夜景、檯燈、戴耳機看書的人、冒煙的馬克杯、窗台上的貓

    static func lofi(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let W = size.width, H = size.height
        let all = CGRect(origin: .zero, size: size)
        ctx.fill(Path(all), with: vertical([hex(0x2A2340), hex(0x3A2E52)], all))

        // 窗
        let win = CGRect(x: W * 0.07, y: H * 0.07, width: W * 0.6, height: H * 0.5)
        ctx.fill(Path(win), with: vertical([hex(0x14204A), hex(0x3B3F7A), hex(0x7A5C8F)], win))
        ctx.drawLayer { layer in
            layer.clip(to: Path(win))
            // 月亮與星星
            let moon = CGPoint(x: win.minX + win.width * 0.78, y: win.minY + win.height * 0.22)
            glow(&layer, at: moon, radius: win.width * 0.22, color: hex(0xFFF2C9, 0.35))
            layer.fill(Path(ellipseIn: CGRect(x: moon.x - 13, y: moon.y - 13, width: 26, height: 26)),
                       with: .color(hex(0xFFF4D6)))
            for i in 0..<26 {
                let p = CGPoint(x: win.minX + rnd(i, 11) * win.width, y: win.minY + rnd(i, 12) * win.height * 0.55)
                let a = 0.35 + 0.5 * (0.5 + 0.5 * sin(t * (0.8 + rnd(i, 13) * 2) + Double(i)))
                layer.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: 1.8, height: 1.8)), with: .color(.white.opacity(a)))
            }
            // 天際線＋亮著的窗戶（偶爾換一盞）
            var x = win.minX - 4
            var b = 0
            while x < win.maxX {
                let w = 18 + rnd(b, 21) * 22
                let h = win.height * (0.18 + rnd(b, 22) * 0.3)
                let r = CGRect(x: x, y: win.maxY - h, width: w, height: h)
                layer.fill(Path(r), with: .color(hex(0x151229)))
                let epoch = Int(t / 9)
                for wy in stride(from: r.minY + 6, to: r.maxY - 4, by: 9) {
                    for wx in stride(from: r.minX + 4, to: r.maxX - 4, by: 7) {
                        let k = Int(wx * 3 + wy * 7)
                        if rnd(k, epoch + b) > 0.72 {
                            layer.fill(Path(CGRect(x: wx, y: wy, width: 3, height: 4)), with: .color(hex(0xFFD58A, 0.8)))
                        }
                    }
                }
                x += w + 2
                b += 1
            }
        }
        // 窗框
        let frame = GraphicsContext.Shading.color(hex(0x4A3F63))
        ctx.stroke(Path(win), with: frame, lineWidth: 5)
        ctx.stroke(line(CGPoint(x: win.midX, y: win.minY), CGPoint(x: win.midX, y: win.maxY)), with: frame, lineWidth: 4)
        ctx.stroke(line(CGPoint(x: win.minX, y: win.midY), CGPoint(x: win.maxX, y: win.midY)), with: frame, lineWidth: 4)
        // 窗台
        ctx.fill(Path(CGRect(x: win.minX - 8, y: win.maxY, width: win.width + 16, height: 8)), with: .color(hex(0x55476F)))

        // 窗台上的貓（呼吸）
        let breathe = 1 + 0.04 * sin(t * 1.4)
        let catC = CGPoint(x: win.minX + win.width * 0.2, y: win.maxY - 9)
        ctx.fill(Path(ellipseIn: CGRect(x: catC.x - 20, y: catC.y - 11 * breathe, width: 40, height: 20 * breathe)),
                 with: .color(hex(0x1A1626)))
        ctx.fill(Path(ellipseIn: CGRect(x: catC.x + 12, y: catC.y - 15, width: 16, height: 14)), with: .color(hex(0x1A1626)))
        for dx in [14.0, 22.0] {
            var ear = Path()
            ear.move(to: CGPoint(x: catC.x + dx, y: catC.y - 12))
            ear.addLine(to: CGPoint(x: catC.x + dx + 2, y: catC.y - 20))
            ear.addLine(to: CGPoint(x: catC.x + dx + 5, y: catC.y - 12))
            ctx.fill(ear, with: .color(hex(0x1A1626)))
        }
        var tail = Path()
        tail.move(to: CGPoint(x: catC.x - 18, y: catC.y + 4))
        tail.addQuadCurve(to: CGPoint(x: catC.x - 30 + sin(t * 1.1) * 4, y: catC.y + 8),
                          control: CGPoint(x: catC.x - 28, y: catC.y + 10))
        ctx.stroke(tail, with: .color(hex(0x1A1626)), style: StrokeStyle(lineWidth: 4, lineCap: .round))

        // 檯燈的光（微微閃）
        let lampHead = CGPoint(x: W * 0.86, y: H * 0.5)
        let flicker = 0.92 + 0.08 * sin(t * 7) * sin(t * 3.3)
        glow(&ctx, at: CGPoint(x: lampHead.x - W * 0.1, y: H * 0.72), radius: W * 0.55, color: hex(0xFFC77A, 0.32 * flicker))

        // 桌子
        let deskY = H * 0.74
        ctx.fill(Path(CGRect(x: 0, y: deskY, width: W, height: H - deskY)), with: .color(hex(0x4A3030)))
        ctx.fill(Path(CGRect(x: 0, y: deskY, width: W, height: 6)), with: .color(hex(0x6B4440)))

        // 檯燈
        let lampBase = CGPoint(x: W * 0.92, y: deskY)
        ctx.fill(Path(ellipseIn: CGRect(x: lampBase.x - 16, y: lampBase.y - 5, width: 32, height: 8)), with: .color(hex(0x22202E)))
        ctx.stroke(line(lampBase, CGPoint(x: lampBase.x - 4, y: H * 0.56)), with: .color(hex(0x22202E)), lineWidth: 3)
        ctx.stroke(line(CGPoint(x: lampBase.x - 4, y: H * 0.56), lampHead), with: .color(hex(0x22202E)), lineWidth: 3)
        var shade = Path()
        shade.move(to: CGPoint(x: lampHead.x - 4, y: lampHead.y - 10))
        shade.addLine(to: CGPoint(x: lampHead.x - 26, y: lampHead.y + 12))
        shade.addLine(to: CGPoint(x: lampHead.x + 4, y: lampHead.y + 16))
        shade.closeSubpath()
        ctx.fill(shade, with: .color(hex(0x22202E)))
        glow(&ctx, at: CGPoint(x: lampHead.x - 12, y: lampHead.y + 16), radius: 14, color: hex(0xFFE0A3, 0.9 * flicker))

        // 馬克杯＋熱氣
        let mug = CGRect(x: W * 0.13, y: deskY - 26, width: 22, height: 24)
        ctx.fill(Path(roundedRect: mug, cornerRadius: 4), with: .color(hex(0xD9A066)))
        ctx.stroke(Path(ellipseIn: CGRect(x: mug.maxX - 4, y: mug.minY + 6, width: 11, height: 11)),
                   with: .color(hex(0xD9A066)), lineWidth: 3)
        for i in 0..<3 {
            let phase = ((t * 0.35 + Double(i) / 3).truncatingRemainder(dividingBy: 1))
            var steam = Path()
            let sx = mug.midX - 6 + Double(i) * 6
            steam.move(to: CGPoint(x: sx, y: mug.minY - 4))
            for k in 1...8 {
                let yy = mug.minY - 4 - Double(k) * 4 - phase * 10
                steam.addLine(to: CGPoint(x: sx + sin(Double(k) * 0.9 + t * 2 + Double(i)) * 3, y: yy))
            }
            ctx.stroke(steam, with: .color(.white.opacity(0.28 * (1 - phase))),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }

        // 人（從背後看，戴耳機，跟著音樂點頭）
        let nod = sin(t * 2.3) * 2.2
        let body = CGRect(x: W * 0.44, y: H * 0.56, width: W * 0.3, height: deskY - H * 0.56 + 10)
        ctx.fill(Path(roundedRect: body, cornerSize: CGSize(width: W * 0.12, height: W * 0.1)), with: .color(hex(0xC96F6F)))
        // 左手伸向書
        var arm = Path()
        arm.move(to: CGPoint(x: body.minX + 10, y: body.minY + 22))
        arm.addQuadCurve(to: CGPoint(x: W * 0.36, y: deskY - 4), control: CGPoint(x: body.minX - 14, y: body.midY))
        ctx.stroke(arm, with: .color(hex(0xB65F60)), style: StrokeStyle(lineWidth: 11, lineCap: .round))
        let headC = CGPoint(x: body.midX - 2, y: body.minY - W * 0.07 + nod)
        let headR = W * 0.085
        // 頭髮＋丸子頭
        ctx.fill(Path(ellipseIn: CGRect(x: headC.x - headR, y: headC.y - headR, width: headR * 2, height: headR * 2.05)),
                 with: .color(hex(0x1C1626)))
        ctx.fill(Path(ellipseIn: CGRect(x: headC.x - headR * 0.45, y: headC.y - headR * 1.55, width: headR * 0.9, height: headR * 0.8)),
                 with: .color(hex(0x1C1626)))
        // 耳機
        var band = Path()
        band.addArc(center: headC, radius: headR * 1.08, startAngle: .degrees(195), endAngle: .degrees(345), clockwise: false)
        ctx.stroke(band, with: .color(hex(0xE8E2F0)), lineWidth: 4)
        ctx.fill(Path(roundedRect: CGRect(x: headC.x - headR * 1.2, y: headC.y - 4, width: 10, height: 18), cornerRadius: 4),
                 with: .color(hex(0xE8E2F0)))
        ctx.fill(Path(roundedRect: CGRect(x: headC.x + headR * 1.2 - 10, y: headC.y - 4, width: 10, height: 18), cornerRadius: 4),
                 with: .color(hex(0xE8E2F0)))

        // 書（每 10 秒翻一頁）
        let book = CGRect(x: W * 0.22, y: deskY - 6, width: W * 0.2, height: 10)
        var left = Path()
        left.move(to: CGPoint(x: book.minX, y: book.maxY))
        left.addLine(to: CGPoint(x: book.minX + 4, y: book.minY))
        left.addLine(to: CGPoint(x: book.midX, y: book.minY + 2))
        left.addLine(to: CGPoint(x: book.midX, y: book.maxY))
        left.closeSubpath()
        ctx.fill(left, with: .color(hex(0xEFE6D2)))
        var right = Path()
        right.move(to: CGPoint(x: book.midX, y: book.maxY))
        right.addLine(to: CGPoint(x: book.midX, y: book.minY + 2))
        right.addLine(to: CGPoint(x: book.maxX - 4, y: book.minY))
        right.addLine(to: CGPoint(x: book.maxX, y: book.maxY))
        right.closeSubpath()
        ctx.fill(right, with: .color(hex(0xE3D8C0)))
        let flip = (t / 10).truncatingRemainder(dividingBy: 1)
        if flip < 0.08 {
            let k = flip / 0.08                    // 0 → 1：從右頁翻到左頁
            let tipX = book.maxX - (book.maxX - book.minX) * k
            var page = Path()
            page.move(to: CGPoint(x: book.midX, y: book.maxY))
            page.addLine(to: CGPoint(x: book.midX, y: book.minY + 2))
            page.addLine(to: CGPoint(x: tipX, y: book.minY - sin(k * .pi) * 14))
            page.addLine(to: CGPoint(x: tipX, y: book.maxY - sin(k * .pi) * 10))
            page.closeSubpath()
            ctx.fill(page, with: .color(hex(0xFFF8E8)))
        }
    }

    // MARK: 雨夜窗邊：模糊的城市光點、雨絲、玻璃上滑落的水珠

    static func rain(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let W = size.width, H = size.height
        let all = CGRect(origin: .zero, size: size)
        ctx.fill(Path(all), with: vertical([hex(0x0E1530), hex(0x1E2B4A), hex(0x2B2440)], all))

        // 遠方的大樓
        var x = -6.0
        var b = 0
        while x < W {
            let w = 26 + rnd(b, 31) * 30
            let h = H * (0.25 + rnd(b, 32) * 0.3)
            ctx.fill(Path(CGRect(x: x, y: H * 0.86 - h, width: w, height: h)), with: .color(hex(0x0A0F22, 0.85)))
            x += w + 3
            b += 1
        }

        // 失焦的光點
        let palette: [UInt32] = [0xFFB86B, 0xFF6B8B, 0x6BD3FF, 0xFFE66B, 0xB38BFF]
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 6))
            for i in 0..<20 {
                let p = CGPoint(x: rnd(i, 41) * W, y: H * (0.35 + rnd(i, 42) * 0.55))
                let r = 8 + rnd(i, 43) * 26
                let a = 0.16 + 0.14 * (0.5 + 0.5 * sin(t * (0.3 + rnd(i, 44)) + Double(i)))
                layer.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                           with: .color(hex(palette[i % palette.count], a)))
            }
        }

        // 窗外的雨絲
        for i in 0..<90 {
            let speed = 260 + rnd(i, 51) * 200
            let len = 10 + rnd(i, 52) * 16
            let y = (rnd(i, 53) * (H + 40) + t * speed).truncatingRemainder(dividingBy: H + 40) - 20
            let xx = rnd(i, 54) * (W + 30) - 15 + y * 0.08
            ctx.stroke(line(CGPoint(x: xx, y: y), CGPoint(x: xx + len * 0.08, y: y + len)),
                       with: .color(.white.opacity(0.12 + rnd(i, 55) * 0.18)), lineWidth: 1)
        }

        // 玻璃上的水珠：大部分不動，偶爾一顆滑下來
        for i in 0..<30 {
            let base = CGPoint(x: rnd(i, 61) * W, y: rnd(i, 62) * H * 0.85)
            let r = 1.5 + rnd(i, 63) * 3
            let period = 9 + rnd(i, 64) * 14
            let phase = (t + rnd(i, 65) * period).truncatingRemainder(dividingBy: period)
            let slide = phase < 3 && rnd(i, 66) > 0.5 ? phase / 3 : 0
            let y = base.y + slide * H * 0.5
            if slide > 0 {
                ctx.stroke(line(CGPoint(x: base.x, y: base.y), CGPoint(x: base.x, y: y)),
                           with: .color(.white.opacity(0.12)), lineWidth: r * 0.6)
            }
            ctx.fill(Path(ellipseIn: CGRect(x: base.x - r, y: y - r, width: r * 2, height: r * 2.2)),
                     with: .color(.white.opacity(0.35)))
            ctx.fill(Path(ellipseIn: CGRect(x: base.x - r * 0.4, y: y - r * 0.6, width: r * 0.6, height: r * 0.6)),
                     with: .color(.white.opacity(0.6)))
        }

        // 窗框、窗台上的蠟燭
        let frame = GraphicsContext.Shading.color(hex(0x0A0C18))
        ctx.stroke(Path(all.insetBy(dx: 4, dy: 4)), with: frame, lineWidth: 10)
        ctx.stroke(line(CGPoint(x: W / 2, y: 0), CGPoint(x: W / 2, y: H)), with: frame, lineWidth: 6)
        ctx.fill(Path(CGRect(x: 0, y: H - 18, width: W, height: 18)), with: .color(hex(0x151020)))
        let candle = CGRect(x: W * 0.78, y: H - 46, width: 14, height: 28)
        ctx.fill(Path(roundedRect: candle, cornerRadius: 3), with: .color(hex(0xEDE3CF)))
        let wobble = sin(t * 9) * 1.2 + sin(t * 13) * 0.6
        glow(&ctx, at: CGPoint(x: candle.midX, y: candle.minY - 8), radius: 40, color: hex(0xFFB65C, 0.35))
        ctx.fill(Path(ellipseIn: CGRect(x: candle.midX - 3.5 + wobble, y: candle.minY - 16, width: 7, height: 13)),
                 with: .color(hex(0xFFD27A)))
    }

    // MARK: 營火：星空、樹影、跳動的火焰與往上飄的火星

    static func campfire(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let W = size.width, H = size.height
        let all = CGRect(origin: .zero, size: size)
        ctx.fill(Path(all), with: vertical([hex(0x070B1E), hex(0x141A3A), hex(0x2A2045)], all))

        for i in 0..<45 {
            let p = CGPoint(x: rnd(i, 71) * W, y: rnd(i, 72) * H * 0.55)
            let a = 0.3 + 0.6 * (0.5 + 0.5 * sin(t * (0.5 + rnd(i, 73) * 2.5) + Double(i)))
            let r = 0.8 + rnd(i, 74) * 1.2
            ctx.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: r, height: r)), with: .color(.white.opacity(a)))
        }
        // 流星（約 12 秒一顆）
        let shoot = (t / 12).truncatingRemainder(dividingBy: 1)
        if shoot < 0.06 {
            let k = shoot / 0.06
            let s0 = CGPoint(x: W * 0.15 + W * 0.5 * k, y: H * 0.08 + H * 0.15 * k)
            ctx.stroke(line(s0, CGPoint(x: s0.x - 30, y: s0.y - 9)), with: .color(.white.opacity(0.7 * (1 - k))), lineWidth: 1.5)
        }

        // 樹影
        let horizon = H * 0.66
        for i in 0..<14 {
            let x = Double(i) / 13 * W + (rnd(i, 75) - 0.5) * 20
            let h = H * (0.14 + rnd(i, 76) * 0.14)
            var tree = Path()
            tree.move(to: CGPoint(x: x, y: horizon - h))
            tree.addLine(to: CGPoint(x: x - h * 0.25, y: horizon + 2))
            tree.addLine(to: CGPoint(x: x + h * 0.25, y: horizon + 2))
            tree.closeSubpath()
            ctx.fill(tree, with: .color(hex(0x05070F)))
        }
        ctx.fill(Path(CGRect(x: 0, y: horizon, width: W, height: H - horizon)), with: .color(hex(0x100C16)))

        // 帳篷
        var tent = Path()
        tent.move(to: CGPoint(x: W * 0.8, y: horizon + H * 0.02))
        tent.addLine(to: CGPoint(x: W * 0.66, y: horizon + H * 0.2))
        tent.addLine(to: CGPoint(x: W * 0.96, y: horizon + H * 0.2))
        tent.closeSubpath()
        ctx.fill(tent, with: .color(hex(0x3A2A3E)))

        let fire = CGPoint(x: W * 0.4, y: H * 0.84)
        let flick = 0.85 + 0.15 * sin(t * 11) * sin(t * 4.7)
        glow(&ctx, at: fire, radius: W * 0.55 * flick, color: hex(0xFF7A2E, 0.32))

        // 柴
        for angle in [-0.35, 0.35] {
            var log = ctx
            log.translateBy(x: fire.x, y: fire.y + 6)
            log.rotate(by: .radians(angle))
            log.fill(Path(roundedRect: CGRect(x: -34, y: -5, width: 68, height: 10), cornerRadius: 5), with: .color(hex(0x5A3A22)))
        }

        // 火焰：三層，每層幾片葉形，高度與尖端跟著雜訊晃
        func flame(width: Double, height: Double, sway: Double, dx: Double) -> Path {
            var p = Path()
            let base = CGPoint(x: fire.x + dx, y: fire.y)
            let tip = CGPoint(x: base.x + sway, y: base.y - height)
            p.move(to: CGPoint(x: base.x - width / 2, y: base.y))
            p.addQuadCurve(to: tip, control: CGPoint(x: base.x - width * 0.6, y: base.y - height * 0.6))
            p.addQuadCurve(to: CGPoint(x: base.x + width / 2, y: base.y),
                           control: CGPoint(x: base.x + width * 0.6, y: base.y - height * 0.55))
            p.closeSubpath()
            return p
        }
        let layers: [(UInt32, Double, Double)] = [(0xFF4B1F, 1.0, 0.95), (0xFF9A1F, 0.72, 0.95), (0xFFE27A, 0.42, 1)]
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 1.5))
            for (li, (color, scale, alpha)) in layers.enumerated() {
                for k in 0..<3 {
                    let n = sin(t * (7 + Double(k)) + Double(li) * 2) * 0.5 + sin(t * 13.3 + Double(k)) * 0.3
                    let h = H * 0.3 * scale * (0.85 + 0.15 * n) * (k == 1 ? 1 : 0.75)
                    let w = W * 0.13 * scale
                    let dx = Double(k - 1) * W * 0.045 * scale
                    layer.fill(flame(width: w, height: h, sway: n * 8, dx: dx), with: .color(hex(color, alpha)))
                }
            }
        }

        // 火星
        for i in 0..<22 {
            let period = 1.8 + rnd(i, 81) * 2.2
            let u = ((t + rnd(i, 82) * period) / period).truncatingRemainder(dividingBy: 1)
            let p = CGPoint(x: fire.x + (rnd(i, 83) - 0.5) * 30 + sin(u * 6 + Double(i)) * 10,
                            y: fire.y - H * 0.08 - u * H * 0.42)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: 2, height: 2)), with: .color(hex(0xFFC46B, 1 - u)))
        }
    }

    // MARK: 午睡的貓：陽光從窗戶斜進來、灰塵在光裡飄、貓在毯子上呼吸，Zzz 往上飄

    static func cat(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let W = size.width, H = size.height
        let all = CGRect(origin: .zero, size: size)
        ctx.fill(Path(all), with: vertical([hex(0xF4E4C8), hex(0xEBCFA5)], all))
        // 牆與地板交界
        ctx.fill(Path(CGRect(x: 0, y: H * 0.62, width: W, height: H * 0.38)), with: .color(hex(0xC99A6B)))
        ctx.fill(Path(CGRect(x: 0, y: H * 0.62, width: W, height: 3)), with: .color(hex(0xB3875C)))

        // 窗戶與斜射的光
        let win = CGRect(x: W * 0.62, y: H * 0.1, width: W * 0.28, height: H * 0.3)
        ctx.fill(Path(win), with: vertical([hex(0xBFE3F5), hex(0xE9F6FB)], win))
        ctx.stroke(Path(win), with: .color(hex(0xFFFFFF)), lineWidth: 5)
        ctx.stroke(line(CGPoint(x: win.midX, y: win.minY), CGPoint(x: win.midX, y: win.maxY)), with: .color(.white), lineWidth: 4)
        let sway = sin(t * 0.25) * 6
        var beam = Path()
        beam.move(to: CGPoint(x: win.minX, y: win.minY))
        beam.addLine(to: CGPoint(x: win.maxX, y: win.minY))
        beam.addLine(to: CGPoint(x: W * 0.55 + sway, y: H * 0.95))
        beam.addLine(to: CGPoint(x: W * 0.05 + sway, y: H * 0.95))
        beam.closeSubpath()
        ctx.fill(beam, with: .linearGradient(Gradient(colors: [hex(0xFFF6D8, 0.55), hex(0xFFF6D8, 0.1)]),
                                             startPoint: CGPoint(x: win.midX, y: win.minY),
                                             endPoint: CGPoint(x: W * 0.3, y: H * 0.95)))
        // 灰塵
        for i in 0..<24 {
            let u = (t * (0.02 + rnd(i, 91) * 0.03) + rnd(i, 92)).truncatingRemainder(dividingBy: 1)
            let y = H * (0.2 + 0.7 * u)
            let k = (y - win.minY) / (H * 0.95 - win.minY)
            let left = win.minX + (W * 0.05 - win.minX) * k, right = win.maxX + (W * 0.55 - win.maxX) * k
            let x = left + (right - left) * rnd(i, 93) + sin(t * 0.7 + Double(i)) * 6
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2.2, height: 2.2)),
                     with: .color(.white.opacity(0.5 * sin(u * .pi))))
        }

        // 毯子
        let rug = CGRect(x: W * 0.12, y: H * 0.7, width: W * 0.62, height: H * 0.2)
        ctx.fill(Path(ellipseIn: rug), with: .color(hex(0x8C6BB1)))
        ctx.stroke(Path(ellipseIn: rug.insetBy(dx: 10, dy: 6)), with: .color(hex(0xA88BCB)),
                   style: StrokeStyle(lineWidth: 2, dash: [6, 5]))

        // 貓（灰色、捲成一團，身體隨呼吸起伏）
        let breathe = 1 + 0.045 * sin(t * 1.5)
        let c = CGPoint(x: rug.midX, y: rug.midY - 6)
        let fur = GraphicsContext.Shading.color(hex(0x6E6A7C))
        let bodyR = CGSize(width: W * 0.2, height: H * 0.085 * breathe)
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - bodyR.width, y: c.y - bodyR.height * 1.6, width: bodyR.width * 2,
                                        height: bodyR.height * 2)), with: fur)
        // 尾巴繞到前面，尾巴尖偶爾動一下
        let twitch = max(0, sin(t * 0.9)) * sin(t * 6) * 5
        var tail = Path()
        tail.move(to: CGPoint(x: c.x + bodyR.width * 0.9, y: c.y - bodyR.height * 0.4))
        tail.addQuadCurve(to: CGPoint(x: c.x - bodyR.width * 0.5 + twitch, y: c.y + bodyR.height * 0.25),
                          control: CGPoint(x: c.x + bodyR.width * 0.4, y: c.y + bodyR.height * 0.7))
        ctx.stroke(tail, with: fur, style: StrokeStyle(lineWidth: 9, lineCap: .round))
        // 頭
        let head = CGPoint(x: c.x - bodyR.width * 0.78, y: c.y - bodyR.height * 0.75)
        let hr = W * 0.075
        ctx.fill(Path(ellipseIn: CGRect(x: head.x - hr, y: head.y - hr * 0.85, width: hr * 2, height: hr * 1.7)), with: fur)
        for dx in [-0.75, 0.15] {
            var ear = Path()
            ear.move(to: CGPoint(x: head.x + hr * dx, y: head.y - hr * 0.5))
            ear.addLine(to: CGPoint(x: head.x + hr * (dx + 0.25), y: head.y - hr * 1.25))
            ear.addLine(to: CGPoint(x: head.x + hr * (dx + 0.6), y: head.y - hr * 0.6))
            ear.closeSubpath()
            ctx.fill(ear, with: fur)
        }
        // 閉著的眼睛
        for dx in [-0.45, 0.25] {
            var eye = Path()
            eye.addArc(center: CGPoint(x: head.x + hr * dx, y: head.y), radius: hr * 0.16,
                       startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
            ctx.stroke(eye, with: .color(hex(0x2E2A38)), lineWidth: 1.6)
        }
        ctx.fill(Path(ellipseIn: CGRect(x: head.x - hr * 0.13, y: head.y + hr * 0.22, width: hr * 0.22, height: hr * 0.15)),
                 with: .color(hex(0xE79AA6)))

        // Zzz
        for i in 0..<3 {
            let u = ((t / 3.6) + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            let p = CGPoint(x: head.x + hr * 0.6 + u * 26 + sin(u * 5) * 4, y: head.y - hr - u * H * 0.22)
            let size = 10 + u * 9
            ctx.draw(Text("z").font(.system(size: size, weight: .bold, design: .rounded))
                .foregroundStyle(hex(0x6E6A7C, 1 - u)), at: p)
        }
    }
}
#endif
