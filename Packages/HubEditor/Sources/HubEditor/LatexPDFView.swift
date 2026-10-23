#if os(macOS)
import SwiftUI
import HubCore
import PDFKit

/// 編譯結果的 PDF 預覽。重新編譯後會換成新的 PDF，但保留原本看到的頁數與位置。
public struct LatexPDFView: NSViewRepresentable {
    public let url: URL
    /// 編譯器每次產出新 PDF 就 +1
    public let version: Int
    /// true＝連續捲動，false＝一次一頁
    public let continuous: Bool
    /// 雙擊 PDF：(頁碼從 0 算, 點座標〔原點在頁面左上，SyncTeX 的慣例〕, 雙擊選到的字)
    public var onDoubleClick: ((Int, CGPoint, String?) -> Void)? = nil
    /// 建好 PDFView 時回報（頁面的 EditorHandle 靠它決定 ⌘F 找哪裡）
    public var onPDFViewReady: ((PDFView) -> Void)? = nil

    public init(url: URL, version: Int, continuous: Bool,
                onDoubleClick: ((Int, CGPoint, String?) -> Void)? = nil,
                onPDFViewReady: ((PDFView) -> Void)? = nil) {
        self.url = url; self.version = version; self.continuous = continuous
        self.onDoubleClick = onDoubleClick; self.onPDFViewReady = onPDFViewReady
    }

    /// 欄寬規則見 AdaptiveSizing.swift。PDFView 不寫這個的話會回報 A4 頁面的寬度，
    /// 那一欄就縮不下去，把整排三欄撐得比視窗還寬。
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: PDFView, context: Context) -> CGSize? {
        proposal.adaptive
    }

    public func makeNSView(context: Context) -> PDFView {
        let view = InverseSearchPDFView()
        view.onDoubleClick = onDoubleClick
        onPDFViewReady?(view)
        view.autoScales = true
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = .underPageBackgroundColor
        view.displayMode = continuous ? .singlePageContinuous : .singlePage
        load(into: view, coordinator: context.coordinator)
        return view
    }

    public func updateNSView(_ view: PDFView, context: Context) {
        (view as? InverseSearchPDFView)?.onDoubleClick = onDoubleClick
        let mode: PDFDisplayMode = continuous ? .singlePageContinuous : .singlePage
        if view.displayMode != mode { view.displayMode = mode }
        if context.coordinator.version != version {
            load(into: view, coordinator: context.coordinator)
        }
    }

    /// 換成新編好的 PDF，但畫面留在原本看的地方（縮放＋捲動位置）。
    ///
    /// 以前用「目前頁碼＋PDFDestination」還原：頁碼取的是「佔畫面最多的那頁」、位置取的是
    /// 「畫面頂端那頁」，兩者不同頁時會往下錯一頁，連續編譯就一路滑到最後一頁
    /// （2026-10-17 使用者回報）。重編譯頁面大小不變，直接記捲動位移最準。
    /// 位置另外按檔案記在 Coordinator 外面：SwiftUI 重建這個 view 時也接得回來。
    private func load(into view: PDFView, coordinator: Coordinator) {
        coordinator.version = version
        // 直接讀 Data 再建 PDFDocument：用 URL 會拿到快取的舊內容
        guard let data = try? Data(contentsOf: url),
              let doc = PDFDocument(data: data), doc.pageCount > 0 else { return }
        let saved: Position? = view.document != nil
            ? Position(of: view) : Self.lastPosition[url.standardizedFileURL.path]
        view.document = doc
        coordinator.observeScrolling(of: view, url: url)
        guard let saved, let clip = view.documentView?.enclosingScrollView?.contentView else { return }
        // 自動縮放要還原成「之前那個 view」的狀態：view 被重建時新的預設是開著的，
        // 照新 view 的值開回去就會把使用者手動放大的比例又縮回欄寬（2026-10-22 回報）
        let autoScales = saved.autoScales
        view.autoScales = false
        view.scaleFactor = saved.scale
        view.layoutDocumentView()
        clip.scroll(to: saved.origin)
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        // 自動縮放等版面穩定後再開回來（同一輪開會把位置重算掉）
        DispatchQueue.main.async { view.autoScales = autoScales }
    }

    public struct Position {
        public let origin: CGPoint
        public let scale: CGFloat
        public let autoScales: Bool
        public init?(of view: PDFView) {
            guard let clip = view.documentView?.enclosingScrollView?.contentView else { return nil }
            origin = clip.bounds.origin
            scale = view.scaleFactor
            autoScales = view.autoScales
        }
    }

    /// 每個 PDF 最後看到的位置（view 被重建時用）
    @MainActor public static var lastPosition: [String: Position] = [:]

    public func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    public final class Coordinator {
        public var version = -1
        private var observer: NSObjectProtocol?

        /// 捲動時記下位置（給 view 被重建時用）
        public func observeScrolling(of view: PDFView, url: URL) {
            guard observer == nil, let clip = view.documentView?.enclosingScrollView?.contentView
            else { return }
            clip.postsBoundsChangedNotifications = true
            let key = url.standardizedFileURL.path
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak view] _ in
                MainActor.assumeIsolated {
                    guard let view, view.document != nil, let p = Position(of: view) else { return }
                    LatexPDFView.lastPosition[key] = p
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

/// 雙擊照常選字，選完再回報雙擊的位置與那個字（給 SyncTeX 反向搜尋用）
public final class InverseSearchPDFView: PDFView {
    public var onDoubleClick: ((Int, CGPoint, String?) -> Void)?

    public override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2, let onDoubleClick, let document else { return }
        let inView = convert(event.locationInWindow, from: nil)
        guard let page = page(for: inView, nearest: true) else { return }
        let onPage = convert(inView, to: page)
        // PDFKit 的頁面座標原點在左下；SyncTeX 要左上
        let box = page.bounds(for: .mediaBox)
        let point = CGPoint(x: onPage.x - box.minX, y: box.maxY - onPage.y)
        let word = currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        onDoubleClick(document.index(for: page), point, word?.isEmpty == false ? word : nil)
    }
}
#endif
