#if os(macOS)
import SwiftUI
import HubCore
import PDFKit
import CoreImage
import Combine
import UniformTypeIdentifiers

struct PDFKitView: NSViewRepresentable {
    let data: Data
    let controller: PDFViewerController

    /// 欄寬規則見 AdaptiveSizing.swift：給多少就用多少，不用內容的寬度撐大欄位
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PDFView, context: Context) -> CGSize? {
        proposal.adaptive
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        controller.pdfView = view
        controller.resetTextCache()
        controller.applyAppearance()
        let controller = self.controller
        context.coordinator.pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: view, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let i = controller.currentPageIndex { controller.onPageChange?(i) }
            }
        }
        context.coordinator.selectionObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewSelectionChanged, object: view, queue: .main) { _ in
            MainActor.assumeIsolated { controller.onSelectionChange?() }
        }
        // 點一下（掃描原檔沒有文字可以反白，對照改用點的）；不攔原本的選取、捲動
        let click = NSClickGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.clicked(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(click)
        context.coordinator.controller = controller
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        controller.pdfView = view
        if context.coordinator.lastData != data {
            context.coordinator.lastData = data
            view.document = PDFDocument(data: data)
            controller.resetTextCache()
        }
        controller.applyAppearance()
    }

    func makeCoordinator() -> Coordinator { Coordinator(data: data) }

    final class Coordinator: NSObject {
        var lastData: Data
        weak var controller: PDFViewerController?
        var pageObserver: NSObjectProtocol?
        var selectionObserver: NSObjectProtocol?
        init(data: Data) { lastData = data }

        @MainActor @objc func clicked(_ g: NSClickGestureRecognizer) {
            guard let view = g.view as? PDFView, let doc = view.document else { return }
            let p = g.location(in: view)
            guard let page = view.page(for: p, nearest: false) else { return }
            controller?.onClick?(doc.index(for: page), view.convert(p, to: page))
        }
        deinit {
            if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
            if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        }
    }
}
#endif
