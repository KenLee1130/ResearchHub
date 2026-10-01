#if os(macOS)
import SwiftUI
import PDFKit

/// 「用 BabelDOC 翻譯」的範圍選擇：整份／一章／自訂頁碼。
/// 書不一定要一次翻完：先翻正在讀的那一章，之後再翻別章會合併進同一份中文版。
struct TranslateRangeSheet: View {
    let pageCount: Int
    /// 目前看到第幾頁（0 起算）
    let currentPage: Int
    let chapters: [Chapter]
    /// 已經翻好的頁（0 起算）
    let translatedPages: Set<Int>
    var onStart: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    struct Chapter: Identifiable, Hashable {
        let id: Int
        let title: String
        let start: Int   // 0 起算
        let end: Int     // 含
        var label: String { "\(title)（p.\(start + 1)–\(end + 1)）" }
    }

    enum Mode: Hashable { case all, chapter, custom }
    @State private var mode: Mode = .all
    @State private var chapterID = 0
    @State private var custom = ""

    /// 每頁大約多少台幣（Das 2018：6 頁約 0.04 美元）
    private static let ntdPerPage = 0.2

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("用 BabelDOC 翻譯").font(.headline)
            Picker("", selection: $mode) {
                Text("整份（\(pageCount) 頁）").tag(Mode.all)
                if !chapters.isEmpty { Text("一章").tag(Mode.chapter) }
                Text("自訂頁碼").tag(Mode.custom)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if mode == .chapter {
                Picker("章節", selection: $chapterID) {
                    ForEach(chapters) { Text($0.label).tag($0.id) }
                }
                .frame(maxWidth: 420)
            }
            if mode == .custom {
                TextField("例如 12-30 或 5, 8-10", text: $custom)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let pages = selectedPages {
                    let again = pages.intersection(translatedPages).count
                    Text("這次翻 \(pages.count) 頁，約 NT$ \(Self.cost(pages.count))"
                         + (again > 0 ? "（其中 \(again) 頁已翻過，會重翻）" : ""))
                } else {
                    Text("頁碼格式不對（1 到 \(pageCount)，例如 12-30）").foregroundStyle(.orange)
                }
                if !translatedPages.isEmpty {
                    Text("已翻譯：\(Self.describe(translatedPages))")
                        .foregroundStyle(.secondary)
                }
                Text("沒翻的頁在對照時顯示原文；之後翻的會合併進同一份中文版。")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("開始翻譯") {
                    onStart(spec)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedPages?.isEmpty ?? true)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: chooseDefault)
    }

    /// 短的（論文）預設整份；長的（書）預設正在讀的那一章，沒有目錄就從目前這頁起 10 頁
    private func chooseDefault() {
        if let current = chapters.last(where: { $0.start <= currentPage }) ?? chapters.first {
            chapterID = current.id
        }
        if pageCount <= 40 {
            mode = .all
        } else if !chapters.isEmpty {
            mode = .chapter
        } else {
            mode = .custom
            custom = "\(currentPage + 1)-\(min(pageCount, currentPage + 10))"
        }
    }

    private var selectedPages: Set<Int>? {
        switch mode {
        case .all:
            return Set(0..<pageCount)
        case .chapter:
            guard let c = chapters.first(where: { $0.id == chapterID }) else { return nil }
            return Set(c.start...c.end)
        case .custom:
            return Self.parse(custom, pageCount: pageCount)
        }
    }

    /// 給 BabelDOC 的頁碼字串（1 起算）；整份傳 nil
    private var spec: String? {
        guard mode != .all, let pages = selectedPages else { return nil }
        return Self.ranges(pages).map { $0.lowerBound == $0.upperBound
            ? "\($0.lowerBound + 1)" : "\($0.lowerBound + 1)-\($0.upperBound + 1)" }
            .joined(separator: ",")
    }

    static func parse(_ text: String, pageCount: Int) -> Set<Int>? {
        var out = Set<Int>()
        for part in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false)
                .map { Int($0.trimmingCharacters(in: .whitespaces)) }
            if ends.count == 1, let a = ends[0], (1...pageCount).contains(a) {
                out.insert(a - 1)
            } else if ends.count == 2, let a = ends[0], let b = ends[1],
                      1 <= a, a <= b, b <= pageCount {
                out.formUnion((a - 1)...(b - 1))
            } else {
                return nil
            }
        }
        return out.isEmpty ? nil : out
    }

    static func ranges(_ pages: Set<Int>) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        for p in pages.sorted() {
            if let last = out.last, last.upperBound + 1 == p {
                out[out.count - 1] = last.lowerBound...p
            } else {
                out.append(p...p)
            }
        }
        return out
    }

    static func describe(_ pages: Set<Int>) -> String {
        ranges(pages).map { $0.lowerBound == $0.upperBound
            ? "p.\($0.lowerBound + 1)" : "p.\($0.lowerBound + 1)–\($0.upperBound + 1)" }
            .joined(separator: "、")
    }

    static func cost(_ pages: Int) -> String {
        let v = Double(pages) * ntdPerPage
        return v < 1 ? "不到 1 元" : String(format: "%.0f", v.rounded(.up))
    }

    /// PDF 自帶目錄的第一層當「章」（只有一個最上層項目時，例如書名，就往下一層）
    static func chapters(of doc: PDFDocument?) -> [Chapter] {
        guard let doc, var root = doc.outlineRoot else { return [] }
        if root.numberOfChildren == 1, let only = root.child(at: 0), only.numberOfChildren > 1 {
            root = only
        }
        var starts: [(String, Int)] = []
        for i in 0..<root.numberOfChildren {
            guard let item = root.child(at: i), let page = item.destination?.page else { continue }
            starts.append((item.label ?? "第 \(i + 1) 章", doc.index(for: page)))
        }
        starts.sort { $0.1 < $1.1 }
        return starts.enumerated().map { k, s in
            let next = k + 1 < starts.count ? starts[k + 1].1 - 1 : doc.pageCount - 1
            return Chapter(id: k, title: s.0, start: s.1, end: max(s.1, next))
        }
    }
}
#endif
