import SwiftUI

/// 全 app 的欄寬規則：嵌在 SwiftUI 裡的 AppKit／UIKit 元件一律「給多少就用多少」。
///
/// 沒寫 sizeThatFits 的話，SwiftUI 會去問元件自己的 intrinsicContentSize——
/// PDFView 會回答「A4 頁面那麼寬」、WKWebView 會回答網頁內容的寬度，
/// 於是那一欄拒絕縮小，把整排撐得比視窗還寬。SwiftUI 對塞不下的內容是「置中溢出」，
/// 多出來的一半往左推：側邊欄被擠出視窗、檔案樹的檔名被切掉、PDF 右邊少一截，
/// 全都是這一個機制。
///
/// 所以每個 NSViewRepresentable／UIViewRepresentable 的 sizeThatFits 都回傳 `proposal.adaptive`：
///   • 問最小（0）→ 0，交給外層的 .frame(minWidth:) 決定下限
///   • 問最大（∞）→ ∞，有多少空間就佔多少
///   • 問理想（nil）→ 一個小的預設值，絕不回報內容的寬度
/// 新增任何 representable 時都要照做。
extension ProposedViewSize {
    var adaptive: CGSize {
        replacingUnspecifiedDimensions(by: CGSize(width: 100, height: 100))
    }
}
