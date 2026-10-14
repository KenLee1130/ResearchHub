#if os(macOS)
import SwiftUI
import PDFKit

/// 編譯結果的 PDF 預覽。重新編譯後會換成新的 PDF，但保留原本看到的頁數與位置。
struct LatexPDFView: NSViewRepresentable {
    let url: URL
    /// 編譯器每次產出新 PDF 就 +1
    let version: Int
    /// true＝連續捲動，false＝一次一頁
    let continuous: Bool
    /// 雙擊 PDF：(頁碼從 0 算, 點座標〔原點在頁面左上，SyncTeX 的慣例〕, 雙擊選到的字)
    var onDoubleClick: ((Int, CGPoint, String?) -> Void)? = nil

    /// 欄寬規則見 AdaptiveSizing.swift。PDFView 不寫這個的話會回報 A4 頁面的寬度，
    /// 那一欄就縮不下去，把整排三欄撐得比視窗還寬。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PDFView, context: Context) -> CGSize? {
        proposal.adaptive
    }

    func makeNSView(context: Context) -> PDFView {
        let view = InverseSearchPDFView()
        view.onDoubleClick = onDoubleClick
        PageFinder.shared.register(view)   // ⌘F 在 PDF 裡找
        view.autoScales = true
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = .underPageBackgroundColor
        view.displayMode = continuous ? .singlePageContinuous : .singlePage
        load(into: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        (view as? InverseSearchPDFView)?.onDoubleClick = onDoubleClick
        let mode: PDFDisplayMode = continuous ? .singlePageContinuous : .singlePage
        if view.displayMode != mode { view.displayMode = mode }
        if context.coordinator.version != version {
            load(into: view, coordinator: context.coordinator)
        }
    }

    private func load(into view: PDFView, coordinator: Coordinator) {
        coordinator.version = version
        // 直接讀 Data 再建 PDFDocument：用 URL 會拿到快取的舊內容
        guard let data = try? Data(contentsOf: url),
              let doc = PDFDocument(data: data), doc.pageCount > 0 else { return }
        let pageIndex = view.currentPage.flatMap { view.document?.index(for: $0) } ?? 0
        let point = view.currentDestination?.point
        view.document = doc
        let target = min(max(0, pageIndex), doc.pageCount - 1)
        DispatchQueue.main.async {
            guard let page = doc.page(at: target) else { return }
            if let point {
                view.go(to: PDFDestination(page: page, at: point))
            } else {
                view.go(to: page)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var version = -1
    }
}

/// 雙擊照常選字，選完再回報雙擊的位置與那個字（給 SyncTeX 反向搜尋用）
final class InverseSearchPDFView: PDFView {
    var onDoubleClick: ((Int, CGPoint, String?) -> Void)?

    override func mouseDown(with event: NSEvent) {
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
