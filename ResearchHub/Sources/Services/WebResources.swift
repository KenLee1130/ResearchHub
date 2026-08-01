import Foundation

/// 內嵌網頁（block 編輯器 / markdown 預覽）的本地資源：
/// EditorWeb/ 內含 tiptap bundle、KaTeX、marked 與字型，完全離線可用。
/// macOS 與 iOS 共用（兩個 target 都打包同一份資源）。
enum WebResources {
    /// 當 loadHTMLString 的 baseURL 用：優先指向 EditorWeb/ 子目錄；
    /// 若打包時被攤平（synchronized group 的行為差異）則退回 Resources 根目錄。
    static var baseURL: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let dir = res.appendingPathComponent("EditorWeb", isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : res
    }
}

import CoreGraphics

/// 預覽端雙擊段落 → 源碼編輯區跳轉的對應資訊。以「標題 + 顯示型公式」為錨點分段、
/// 段內線性內插，避免長公式(原始碼很多行、渲染很短)造成左右對不上。
struct ScrollSync: Equatable {
    var anchor: Int = -1     // 目標位置上方最近的錨點索引(-1 = 在第一個錨點之前)
    var local: CGFloat = 0   // 在「該錨點→下一個錨點」這一段內的比例(0...1)
    var global: CGFloat = 0  // 後備:整份的比例(錨點數對不上時用)
    var count: Int = 0       // 來源端錨點總數
    var word: String = ""    // 雙擊選到的字(空 = 只做位置跳轉,不選字)
    var occ: Int = 0         // 該字在錨點段落內是第幾次出現(0-based,選字時用)
    var fn: Int = 0          // >0 = 雙擊的是第 n 條註腳 → 跳到源碼第 n 個 \footnote{...}
}
