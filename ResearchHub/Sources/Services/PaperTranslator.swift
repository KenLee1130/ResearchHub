#if os(macOS)
import Foundation
import Observation
import PDFKit

// MARK: - 段落對照（align.json）

/// BabelDOC 把每一段譯文排進原文那一段的同一個方框（同一頁、同座標）。
/// 小幫手翻譯時把每頁的段落方框存成 align.json，對照模式靠它做「反白一邊、另一邊標出同一段」。
/// 座標是 PDF 頁面座標（左下角為原點），跟 PDFKit 的 page 座標一致。
nonisolated struct PaperAlignment: Codable, Sendable {
    var version: Int = 1
    var source: String?
    /// 每頁的段落方框 [x, y, x2, y2]
    var pages: [[[Double]]]
    /// v2：總頁數、翻過的頁（0 起算；書可以只翻一部分）、每段的句子對照
    var pageCount: Int?
    var translatedPages: [Int]?
    var paragraphs: [Paragraph]?

    /// 一段的句子對照：src[i] 對 dst[i]（dst 可能是空字串＝那句在譯文裡被併進鄰句）
    struct Paragraph: Codable, Sendable {
        var page: Int
        var box: [Double]
        var src: [String]
        var dst: [String]
        var method: String?
        var rect: CGRect {
            box.count == 4 ? CGRect(x: box[0], y: box[1], width: box[2] - box[0], height: box[3] - box[1]) : .zero
        }
    }

    /// 這一頁、包住這一點的段落（句子對照用）
    func sentenceParagraph(onPage index: Int, at point: CGPoint) -> Paragraph? {
        (paragraphs ?? [])
            .filter { $0.page == index && $0.rect.insetBy(dx: -2, dy: -2).contains(point) }
            .min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
    }

    /// 已經翻好的頁（舊版 v1 沒記：當成全部都翻了）
    var translatedPageSet: Set<Int> {
        if let translatedPages { return Set(translatedPages) }
        return Set(pages.indices)
    }

    /// 這次只翻了一部分頁：把新翻的頁蓋進舊的對照（其他頁保留）
    func merging(_ newer: PaperAlignment) -> PaperAlignment {
        let fresh = newer.translatedPageSet
        let count = max(pageCount ?? pages.count, newer.pageCount ?? newer.pages.count)
        var mergedPages: [[[Double]]] = []
        for i in 0..<count {
            let mine = pages.indices.contains(i) ? pages[i] : []
            let theirs = newer.pages.indices.contains(i) ? newer.pages[i] : []
            mergedPages.append(fresh.contains(i) ? theirs : mine)
        }
        let kept = (paragraphs ?? []).filter { !fresh.contains($0.page) }
        return PaperAlignment(
            version: 2, source: "babeldoc", pages: mergedPages, pageCount: count,
            translatedPages: Array(translatedPageSet.union(fresh)).sorted(),
            paragraphs: kept + (newer.paragraphs ?? []))
    }

    func boxes(onPage index: Int) -> [CGRect] {
        guard pages.indices.contains(index) else { return [] }
        return pages[index].compactMap { b in
            b.count == 4 ? CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1]) : nil
        }
    }

    /// 包住這一點的段落（有好幾個就取最小的；都沒包住就取同一欄、上下最近的一段）
    func paragraph(onPage index: Int, at point: CGPoint) -> CGRect? {
        let all = boxes(onPage: index)
        if let hit = all.filter({ $0.insetBy(dx: -2, dy: -2).contains(point) })
            .min(by: { $0.width * $0.height < $1.width * $1.height }) {
            return hit
        }
        return all
            .filter { $0.minX - 4 <= point.x && point.x <= $0.maxX + 4 }
            .map { ($0, min(abs($0.minY - point.y), abs($0.maxY - point.y))) }
            .filter { $0.1 < 16 }
            .min { $0.1 < $1.1 }?.0
    }
}

// MARK: - 用 BabelDOC 翻譯一篇

/// 翻譯走沙盒外的小幫手（researchhub-helper.sh translate）：它讀得到使用者放在
/// ~/.config/researchhub/deepseek.key 的金鑰、跑得了 BabelDOC。
/// 原文 PDF 先由 app 寫進容器的工作資料夾，成品（譯文 PDF＋align.json）再由 app 搬回
/// <資料夾>/Papers/<Zotero key>/（小幫手不能碰 iCloud）。
@Observable
@MainActor
final class PaperTranslator {
    /// 正在翻的論文（Zotero key）與開始時間；nil＝沒在翻
    private(set) var runningKey: String?
    private(set) var startedAt: Date?
    private(set) var lastError: String?
    /// 目前在第幾步：掃描書先 OCR（第 1 步），再翻譯（第 2 步）
    enum Phase: Equatable { case ocr, translate }
    private(set) var phase: Phase?
    /// 這次有沒有 OCR 這一步（banner 顯示「第幾步／共幾步」用）
    private(set) var withOCR = false

    func isRunning(_ key: String) -> Bool { runningKey == key }

    /// 兩步：(1) needsOCR 時先用 OCRmyPDF 幫沒有文字層的頁加上文字（存成 Papers/<key>/ocr.pdf，
    /// 只在背後給翻譯、AI、對照用，畫面上原文仍顯示原檔）；(2) BabelDOC 翻譯。
    /// pages：頁碼範圍（1 起算，例如 "12-30"）；nil＝整份。
    /// 只翻一部分時，會把新翻的頁合併進原本已經翻好的譯文（existing），不會蓋掉前面翻好的頁。
    func translate(key: String, pdfData: Data, ocrData: Data?, root: URL, pages: String? = nil,
                   needsOCR: Bool,
                   existing: (data: Data, alignment: PaperAlignment)? = nil,
                   onOCR: @escaping @MainActor (Data) -> Void,
                   onDone: @escaping @MainActor (Data, PaperAlignment?) -> Void) {
        guard runningKey == nil else { return }
        runningKey = key
        startedAt = Date()
        lastError = nil
        withOCR = needsOCR
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let work = caches.appendingPathComponent("papers/\(key)/translate", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        guard needsOCR else {
            runTranslate(key: key, input: ocrData ?? pdfData, scanned: ocrData != nil, work: work,
                         root: root, pages: pages, existing: existing, onDone: onDone)
            return
        }
        // 第 1 步：OCR（疊在已經辨識過的版本上，前面做過的頁不會重做）
        phase = .ocr
        do {
            try (ocrData ?? pdfData).write(to: work.appendingPathComponent("input.pdf"), options: .atomic)
        } catch {
            fail("無法準備 OCR 暫存檔：\(error.localizedDescription)")
            return
        }
        var args = ["ocr", work.path]
        if let pages, !pages.isEmpty { args.append(pages) }
        LatexCompiler.runHelper(args) { [weak self] output, error in
            guard let self else { return }
            let fields = LatexCompiler.parseFields(output)
            if let error {
                self.fail("無法執行 OCR 小幫手：\(error.localizedDescription)")
                return
            }
            guard let path = fields["OCR"],
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  PDFDocument(data: data) != nil else {
                let detail = fields["ERR"]
                    ?? (fields["TIMEOUT"] == "1" ? "OCR 超過 60 分鐘沒有完成" : "OCR 沒有產生結果（結束碼 \(fields["RC"] ?? "?")）")
                self.fail(detail)
                return
            }
            let dir = PaperChatSession.paperDir(root: root, key: key)
            Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: dir.appendingPathComponent("ocr.pdf"), options: .atomic)
            }
            onOCR(data)
            // 第 2 步：翻譯 OCR 版
            self.runTranslate(key: key, input: data, scanned: true, work: work,
                              root: root, pages: pages, existing: existing, onDone: onDone)
        }
    }

    private func runTranslate(key: String, input: Data, scanned: Bool, work: URL, root: URL,
                              pages: String?, existing: (data: Data, alignment: PaperAlignment)?,
                              onDone: @escaping @MainActor (Data, PaperAlignment?) -> Void) {
        phase = .translate
        do {
            try input.write(to: work.appendingPathComponent("input.pdf"), options: .atomic)
        } catch {
            fail("無法準備翻譯暫存檔：\(error.localizedDescription)")
            return
        }
        // translate <dir> zh-TW <頁碼或空字串> <scan>
        var args = ["translate", work.path, "zh-TW", pages ?? ""]
        if scanned { args.append("scan") }
        LatexCompiler.runHelper(args) { [weak self] output, error in
            guard let self else { return }
            let fields = LatexCompiler.parseFields(output)
            if let error {
                self.fail("無法執行翻譯小幫手：\(error.localizedDescription)")
                return
            }
            guard let mono = fields["MONO"],
                  let data = try? Data(contentsOf: URL(fileURLWithPath: mono)),
                  PDFDocument(data: data) != nil else {
                let detail = fields["ERR"]
                    ?? (fields["TIMEOUT"] == "1" ? "超過 20 分鐘沒有完成" : "BabelDOC 沒有產生譯文（結束碼 \(fields["RC"] ?? "?")）")
                self.fail(detail)
                return
            }
            let alignData = fields["ALIGN"].flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            let fresh = alignData.flatMap { try? JSONDecoder().decode(PaperAlignment.self, from: $0) }
            let dir = PaperChatSession.paperDir(root: root, key: key)
            Task { [weak self] in
                // 合併（書只翻部分頁時）與存檔都在背景做：一本書幾百頁，搬頁很花時間
                let result = await Task.detached(priority: .userInitiated) { () -> (Data, PaperAlignment?) in
                    var outData = data
                    var outAlign = fresh
                    if let existing, let fresh, fresh.translatedPages != nil {
                        outData = Self.mergePages(base: existing.data, newer: data,
                                                  pages: fresh.translatedPageSet) ?? data
                        outAlign = existing.alignment.merging(fresh)
                    }
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try? outData.write(to: dir.appendingPathComponent("translation.pdf"), options: .atomic)
                    let alignURL = dir.appendingPathComponent("align.json")
                    if let outAlign, let encoded = try? JSONEncoder().encode(outAlign) {
                        try? encoded.write(to: alignURL, options: .atomic)
                    } else {
                        try? FileManager.default.removeItem(at: alignURL)
                    }
                    return (outData, outAlign)
                }.value
                guard let self else { return }
                self.runningKey = nil
                self.startedAt = nil
                self.phase = nil
                onDone(result.0, result.1)
            }
        }
    }

    /// 這些頁裡，哪些沒有文字層（掃描頁）——翻譯前的「第 1 步：檢查要不要 OCR」
    nonisolated static func pagesWithoutText(_ doc: PDFDocument?, in pages: Set<Int>) -> Set<Int> {
        guard let doc else { return [] }
        return Set(pages.filter { i in
            guard i < doc.pageCount, let page = doc.page(at: i) else { return false }
            let text = (page.string ?? "").filter { !$0.isWhitespace }
            return text.count < 20
        })
    }

    /// 把 newer 裡 pages 這幾頁搬進 base（同一份原文翻出來的，兩邊頁數一樣）
    nonisolated static func mergePages(base: Data, newer: Data, pages: Set<Int>) -> Data? {
        guard let baseDoc = PDFDocument(data: base), let newDoc = PDFDocument(data: newer),
              baseDoc.pageCount == newDoc.pageCount else { return nil }
        for i in pages.sorted() where i < newDoc.pageCount {
            guard let page = newDoc.page(at: i)?.copy() as? PDFPage else { continue }
            baseDoc.removePage(at: i)
            baseDoc.insert(page, at: i)
        }
        return baseDoc.dataRepresentation()
    }

    private func fail(_ message: String) {
        lastError = message
        runningKey = nil
        startedAt = nil
        phase = nil
    }

    func dismissError() { lastError = nil }

    /// 讀論文資料夾裡的段落對照（沒有就 nil：例如手動匯入的譯文）
    static func loadAlignment(root: URL?, key: String) -> PaperAlignment? {
        guard let root else { return nil }
        let url = PaperChatSession.paperDir(root: root, key: key).appendingPathComponent("align.json")
        guard case .data(let data) = LibraryFileRead.read(url) else { return nil }
        return try? JSONDecoder().decode(PaperAlignment.self, from: data)
    }
}
#endif
