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

    func isRunning(_ key: String) -> Bool { runningKey == key }

    func translate(key: String, pdfData: Data, root: URL,
                   onDone: @escaping @MainActor (Data, PaperAlignment?) -> Void) {
        guard runningKey == nil else { return }
        runningKey = key
        startedAt = Date()
        lastError = nil
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let work = caches.appendingPathComponent("papers/\(key)/translate", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            try pdfData.write(to: work.appendingPathComponent("input.pdf"), options: .atomic)
        } catch {
            fail("無法準備翻譯暫存檔：\(error.localizedDescription)")
            return
        }
        LatexCompiler.runHelper(["translate", work.path, "zh-TW"]) { [weak self] output, error in
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
            let alignment = alignData.flatMap { try? JSONDecoder().decode(PaperAlignment.self, from: $0) }
            // 成品搬回論文資料夾（跟著 iCloud 走，iPhone 也看得到）
            let dir = PaperChatSession.paperDir(root: root, key: key)
            Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: dir.appendingPathComponent("translation.pdf"), options: .atomic)
                let alignURL = dir.appendingPathComponent("align.json")
                if let alignData {
                    try? alignData.write(to: alignURL, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: alignURL)
                }
            }
            self.runningKey = nil
            self.startedAt = nil
            onDone(data, alignment)
        }
    }

    private func fail(_ message: String) {
        lastError = message
        runningKey = nil
        startedAt = nil
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
