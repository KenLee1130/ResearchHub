import SwiftUI

/// App 外觀主題。
///
/// `.ambient` 是原本的流光紫（材質模糊 + 漸層背景）；
/// `.ink` 是黑底白字，用「深度階梯」分層：每一層之間差 4–6% 亮度，再加一條 hairline。
///
/// 黑色主題最容易踩的兩個雷，這裡都避開了：
///   1. 不用純黑 #000 當底、也不用純白當字——純白壓在純黑上會有光暈（halation），久看很累。
///   2. 編輯區跟周圍的面板不能同色。這裡讓**編輯區最深**（像一口井），
///      周圍的側邊欄、工具列、卡片一層層往上變亮，所以邊界看得出來。
enum AppTheme: String, CaseIterable, Identifiable {
    case ambient
    case ink

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ambient: "流光紫"
        case .ink: "墨黑"
        }
    }

    var summary: String {
        switch self {
        case .ambient: "半透明材質配紫色流光背景"
        case .ink: "黑底白字，分層靠亮度階梯"
        }
    }

    /// 目前選的主題（存在偏好設定，Mac 與 iPhone 各自記各自的）
    static let storageKey = "settings.theme"

    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .ambient
    }

    /// 墨黑主題強制深色（淺色的語意色壓在黑底上會看不見）
    var forcedColorScheme: ColorScheme? { self == .ink ? .dark : nil }
}

// MARK: - 面板層級

/// 由深到淺的五層。數字越大離使用者越「近」，顏色就越亮。
enum SurfaceLevel {
    /// 寫字的地方：整個 app 最深的一層
    case editor
    /// 視窗底色
    case canvas
    /// 側邊欄、工具列
    case chrome
    /// 卡片、清單區塊
    case panel
    /// popover、sheet
    case overlay
}

/// 墨黑主題的色票。
enum InkPalette {
    static let editor = Color(hex: 0x08080A)
    static let canvas = Color(hex: 0x0B0B0E)
    static let chrome = Color(hex: 0x121216)
    static let panel = Color(hex: 0x17171C)
    static let overlay = Color(hex: 0x1E1E24)

    /// 分層之間的細線。單靠亮度差在大面積上會看不清楚，補一條 8% 白。
    static let hairline = Color.white.opacity(0.08)
    static let hairlineStrong = Color(hex: 0x2A2A31)

    static let textPrimary = Color(hex: 0xECECF0)
    static let textSecondary = Color(hex: 0xA0A0AA)
    static let textTertiary = Color(hex: 0x6E6E78)

    /// 沿用 app 的紫色識別，但降彩度，免得在黑底上刺眼
    static let accent = Color(hex: 0x8B7CF6)
    static let accentSoft = Color(hex: 0x8B7CF6).opacity(0.18)

    static func color(_ level: SurfaceLevel) -> Color {
        switch level {
        case .editor: editor
        case .canvas: canvas
        case .chrome: chrome
        case .panel: panel
        case .overlay: overlay
        }
    }

    /// 給 WKWebView 預覽與 NSTextView 用的十六進位字串
    static func hexString(_ level: SurfaceLevel) -> String {
        switch level {
        case .editor: "#08080A"
        case .canvas: "#0B0B0E"
        case .chrome: "#121216"
        case .panel: "#17171C"
        case .overlay: "#1E1E24"
        }
    }
}

// MARK: - 套用

private struct SurfaceModifier: ViewModifier {
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.ambient.rawValue
    let level: SurfaceLevel
    /// 流光紫主題要用的材質（保持原本的外觀不動）
    let material: Material

    func body(content: Content) -> some View {
        let theme = AppTheme(rawValue: themeRaw) ?? .ambient
        if theme == .ink {
            content.background(InkPalette.color(level))
        } else {
            content.background(material)
        }
    }
}

private struct InkOnlyModifier: ViewModifier {
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.ambient.rawValue
    let level: SurfaceLevel

    func body(content: Content) -> some View {
        if AppTheme(rawValue: themeRaw) == .ink {
            content.background(InkPalette.color(level))
        } else {
            content
        }
    }
}

extension View {
    /// 依主題上背景：流光紫走材質、墨黑走實色階梯。
    func surface(_ level: SurfaceLevel, ambient material: Material = .regularMaterial) -> some View {
        modifier(SurfaceModifier(level: level, material: material))
    }

    /// 只有墨黑主題才上色，流光紫維持原本的系統外觀（例如側邊欄的原生材質）。
    func inkSurface(_ level: SurfaceLevel) -> some View {
        modifier(InkOnlyModifier(level: level))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}
