import SwiftUI
import HubStore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// 事件標籤的顏色是字串（hex）存在 events.json；SwiftUI 的 Color 只在 app 這邊換算。
extension EventTag {
    var color: Color { Color(hex: colorHex) }
}

extension EventStore {
    func addTag(name: String, color: Color) { addTag(name: name, colorHex: color.hexString) }
}

// MARK: - Color ↔ hex

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b)
    }

    var hexString: String {
        #if canImport(AppKit)
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return "#888888" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        else { return "#888888" }
        let r = Int(round(red * 255))
        let g = Int(round(green * 255))
        let b = Int(round(blue * 255))
        #endif
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
