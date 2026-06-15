import Foundation

/// 預覽/PDF 用的前端資源（KaTeX、marked）載入策略。
///
/// 預設行為：**優先用打包進 App 的本地檔案（離線可用、更快、不外連）**；
/// 若 App bundle 裡找不到（尚未執行 fetch 腳本），則**退回原本的 CDN**，
/// 確保在資源還沒放進來時行為與舊版完全相同、不會壞掉。
///
/// 要變成離線版：在專案根目錄執行
///     scripts/fetch-web-assets.sh
/// 它會把 katex.min.js / katex.min.css / KaTeX 字型 / marked.min.js 下載到
///     ResearchHub/Sources/WebAssets/
/// 重新 build 後（檔案會被 Xcode 自動納入 bundle 資源）即自動改用本地資源。
///
/// 註：區塊（TipTap）編輯器另從 esm.sh 載入整套模組，要離線需額外的 JS 打包步驟，
/// 不在此處理；見 scripts/README.md。
enum WebAssets {

    /// 打包資源所在目錄（以 katex.min.js 是否存在判斷）。
    /// 同步資料夾下的資源會平鋪到 bundle 資源根目錄，所以用 Bundle 查找該檔再取其目錄。
    static let localDir: URL? = {
        Bundle.main.url(forResource: "katex.min", withExtension: "js")?
            .deletingLastPathComponent()
    }()

    /// 是否已備妥本地資源。
    static var hasLocal: Bool { localDir != nil }

    /// 載入 HTML 時要用的 baseURL：有本地資源就指到該目錄，讓相對路徑（含 KaTeX
    /// CSS 內的 fonts/*.woff2）能解析；沒有則回傳 nil（搭配 CDN 絕對網址）。
    static var baseURL: URL? { localDir }

    private static let katexCDN = "https://cdnjs.cloudflare.com/ajax/libs/KaTeX/0.16.9"
    private static let markedCDN = "https://cdnjs.cloudflare.com/ajax/libs/marked/12.0.2/marked.min.js"

    /// KaTeX 樣式表 <link>（本地或 CDN）。
    static var katexCSSTag: String {
        hasLocal
            ? #"<link rel="stylesheet" href="katex.min.css">"#
            : #"<link rel="stylesheet" href="\#(katexCDN)/katex.min.css">"#
    }

    /// KaTeX 程式 <script>（本地或 CDN）。
    static var katexJSTag: String {
        hasLocal
            ? #"<script src="katex.min.js"></script>"#
            : #"<script src="\#(katexCDN)/katex.min.js"></script>"#
    }

    /// marked 程式 <script>（本地或 CDN）。
    static var markedJSTag: String {
        hasLocal
            ? #"<script src="marked.min.js"></script>"#
            : #"<script src="\#(markedCDN)"></script>"#
    }
}
