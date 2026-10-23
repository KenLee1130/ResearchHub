import Foundation
#if os(macOS)
import AppKit
#endif

/// 套件裡要用的本地化字串：app 啟動時把自己的 `L()` 掛上來（跟隨 app 的語言設定，不是系統語言）。
public enum EditorLocalization {
    nonisolated(unsafe) public static var L: (String.LocalizationValue) -> String = { String(localized: $0) }
}

#if os(macOS)
/// 原始碼編輯器的底色與文字色，由 app 依主題算好傳進來（墨黑主題用最深的那一層，系統預設就用系統色）。
public struct EditorPalette: Equatable {
    public var background: NSColor
    public var text: NSColor
    public var insertionPoint: NSColor

    public init(background: NSColor, text: NSColor, insertionPoint: NSColor) {
        self.background = background
        self.text = text
        self.insertionPoint = insertionPoint
    }

    public static let system = EditorPalette(background: .textBackgroundColor, text: .labelColor, insertionPoint: .textColor)
}
#endif
