#if os(iOS)
import SwiftUI
import PDFKit

/// 手機上看 LaTeX 專案：唯讀，直接翻 Mac 版編譯好的 .researchhub/output.pdf。
///
/// 手機不編譯（iOS 沒有 TeX），所以這裡只負責把 iCloud 上那份 PDF 抓下來顯示；
/// 檔案還沒下載完或還沒編譯過的情況都要講清楚，不要給一片白。
struct MobileProjectView: View {
    let projectURL: URL

    @State private var data: Data?
    @State private var message = "載入中…"
    @State private var compiledAt: Date?

    private var pdfURL: URL { LatexProject.outputPDF(of: projectURL) }

    var body: some View {
        Group {
            if let data {
                MobilePDFView(data: data)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView {
                    Label("還沒有 PDF", systemImage: "doc.richtext")
                } description: {
                    Text(message)
                }
            }
        }
        .navigationTitle(projectURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let compiledAt {
                ToolbarItem(placement: .topBarTrailing) {
                    Text(compiledAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { load(retriesLeft: 6) }
        .refreshable { load(retriesLeft: 2) }
    }

    private func load(retriesLeft: Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pdfURL.path) else {
            message = "這個專案還沒在 Mac 上編譯過。在 Mac 版按一下「編譯」，這裡就會出現。"
            return
        }
        if let v = try? pdfURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           let status = v.ubiquitousItemDownloadingStatus, status == .notDownloaded {
            try? fm.startDownloadingUbiquitousItem(at: pdfURL)
            message = "從 iCloud 下載中…"
            guard retriesLeft > 0 else { return }
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                load(retriesLeft: retriesLeft - 1)
            }
            return
        }
        // 讀到一半的檔案會是壞的 PDF，所以先驗證再換上去
        guard let bytes = try? Data(contentsOf: pdfURL), PDFDocument(data: bytes) != nil else {
            message = "PDF 讀不起來（可能正在同步）。下拉可以重試。"
            return
        }
        data = bytes
        compiledAt = (try? pdfURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }
}

private struct MobilePDFView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemBackground
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        // 只在內容真的換了才重建 document，否則會一直跳回第一頁
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        let page = view.currentPage.map { view.document?.index(for: $0) ?? 0 } ?? 0
        view.document = PDFDocument(data: data)
        if let target = view.document?.page(at: min(page, (view.document?.pageCount ?? 1) - 1)) {
            view.go(to: target)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(data: data) }

    final class Coordinator {
        var data: Data
        init(data: Data) { self.data = data }
    }
}
#endif
