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
