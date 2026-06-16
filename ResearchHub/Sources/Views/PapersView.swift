import SwiftUI
import PDFKit
import CoreImage
import Combine

/// 論文分頁：左 Zotero library 清單（可搜尋），右內建 PDF 閱讀器。
struct PapersView: View {
    @EnvironmentObject private var store: FileSystemStore
    @StateObject private var zotero = ZoteroStore.shared

    @State private var search = ""
    @State private var selected: ZoteroItem?
    @State private var attachment: ZoteroStore.Attachment?
    @State private var pdfData: Data?
    @State private var loadingPDF = false
    @StateObject private var viewer = PDFViewerController()

    var body: some View {
        HSplitView {
            listPane
                // minWidth 壓低:讓內容區在窄視窗時仍能縮進可用寬度,
                // 避免 NavigationSplitView 因塞不下而擠壓側欄、害選單位置跳動。
                .frame(minWidth: 160, idealWidth: 320, maxWidth: 460)
            detailPane
                .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("論文")
        .task {
            zotero.restoreZoteroDir()
            await zotero.refresh()
        }
    }

    // MARK: - List

    private var filtered: [ZoteroItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return zotero.items }
        return zotero.items.filter {
            $0.title.lowercased().contains(q)
            || $0.authors.lowercased().contains(q)
            || ($0.data.tags ?? []).contains { $0.tag.lowercased().contains(q) }
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜尋標題、作者、標籤…", text: $search)
                    .textFieldStyle(.plain)
                Button {
                    Task { await zotero.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("重新整理")
            }
            .padding(10)

            Divider()

            if zotero.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = zotero.errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "wifi.slash")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重試") { Task { await zotero.refresh() } }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(filtered) { item in
                            paperRow(item)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    private func paperRow(_ item: ZoteroItem) -> some View {
        Button {
            select(item)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(item.authors)
                        .lineLimit(1)
                    if !item.year.isEmpty {
                        Text(item.year)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let tags = item.data.tags, !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags.prefix(4), id: \.tag) { tag in
                            Text(tag.tag)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                .foregroundStyle(Color.accentColor)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected?.key == item.key
                          ? Color.accentColor.opacity(0.18)
                          : Color.primary.opacity(0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail

    private var detailPane: some View {
        VStack(spacing: 0) {
            if let item = selected {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.headline)
                            .lineLimit(2)
                        Text([item.authors, item.year, item.data.publicationTitle ?? ""]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if pdfData != nil {
                        Button {
                            viewer.toggleDark()
                        } label: {
                            Image(systemName: viewer.isDark ? "moon.fill" : "moon")
                        }
                        .help("PDF 暗色模式")
                        Button {
                            viewer.highlightSelection()
                        } label: {
                            Image(systemName: "highlighter")
                        }
                        .help("選取文字後按此加上螢光標記；選取已標記的文字再按一次 = 取消")
                        .disabled(viewer.fileURL == nil)
                    }
                    Button("建立筆記") { createNote(for: item) }
                    Button {
                        if let url = URL(string: "zotero://select/library/items/\(item.key)") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .help("在 Zotero 開啟")
                }
                .padding(12)

                Divider()

                if loadingPDF {
                    ProgressView("載入 PDF…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let pdfData {
                    PDFKitView(data: pdfData, controller: viewer)
                } else if attachment != nil && !zotero.hasZoteroDir {
                    // 有附件但讀不到 → 引導授權 Zotero 資料夾
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("這篇有 PDF，但需要授權讀取 Zotero 資料夾\n（通常在 ~/Zotero）")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("選擇 Zotero 資料夾…") { pickZoteroDir() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if attachment != nil {
                    Text("讀不到 PDF 檔案——確認該篇附件已下載到本機（Zotero 中可開啟）")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("這筆文獻沒有 PDF 附件")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("選擇一篇論文")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.thickMaterial)
    }

    private func select(_ item: ZoteroItem) {
        selected = item
        pdfData = nil
        attachment = nil
        viewer.fileURL = nil
        loadingPDF = true
        Task {
            defer { loadingPDF = false }
            guard let found = await zotero.pdfAttachment(for: item) else { return }
            attachment = found
            if let result = await zotero.pdfData(attachment: found) {
                pdfData = result.data
                viewer.fileURL = result.fileURL
            }
        }
    }

    /// 一次性授權 Zotero 資料夾（之後用 bookmark 記住）
    private func pickZoteroDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "選擇 Zotero 資料夾（預設位置是家目錄下的 Zotero）")
        panel.prompt = String(localized: "授權")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            zotero.setZoteroDir(url)
            if let item = selected {
                select(item) // 重試載入
            }
        }
    }

    /// 在 Notes/Papers/ 建立關聯筆記並開啟
    private func createNote(for item: ZoteroItem) {
        guard let notes = store.notesURL else { return }
        let dir = notes.appendingPathComponent("Papers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = item.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "—")
            .prefix(80)
        let url = dir.appendingPathComponent("\(safeName).md")

        if !FileManager.default.fileExists(atPath: url.path) {
            var lines = ["# \(item.title)", ""]
            if !item.authors.isEmpty { lines.append("\(String(localized: "**作者**"))：\(item.authors)") }
            if !item.year.isEmpty { lines.append("\(String(localized: "**年份**"))：\(item.year)") }
            if let venue = item.data.publicationTitle, !venue.isEmpty {
                lines.append("\(String(localized: "**期刊**"))：\(venue)")
            }
            if let doi = item.data.DOI, !doi.isEmpty { lines.append("**DOI**：\(doi)") }
            lines.append("**Zotero**：zotero://select/library/items/\(item.key)")
            lines.append("")
            lines.append("## \(String(localized: "筆記"))")
            lines.append("")
            try? lines.joined(separator: "\n")
                .write(to: url, atomically: true, encoding: .utf8)
        }
        store.openNote(url)
    }
}

// MARK: - PDFKit wrapper

/// PDF 檢視控制：暗色模式（反色 + 色相旋轉，顏色大致保留）與螢光筆。
@MainActor
final class PDFViewerController: ObservableObject {
    weak var pdfView: PDFView?
    @Published var isDark = false
    /// 本地檔案路徑（有才能把註記寫回）
    var fileURL: URL?

    func toggleDark() {
        isDark.toggle()
        applyAppearance()
    }

    func applyAppearance() {
        guard let view = pdfView else { return }
        view.wantsLayer = true
        if isDark {
            // 仿 Zotero：反轉 + 色相還原後，把純黑底抬成深石板色、略降對比
            guard let invert = CIFilter(name: "CIColorInvert"),
                  let hue = CIFilter(name: "CIHueAdjust"),
                  let tone = CIFilter(name: "CIColorMatrix") else { return }
            hue.setValue(Double.pi, forKey: kCIInputAngleKey)
            tone.setValue(CIVector(x: 0.82, y: 0, z: 0, w: 0), forKey: "inputRVector")
            tone.setValue(CIVector(x: 0, y: 0.82, z: 0, w: 0), forKey: "inputGVector")
            tone.setValue(CIVector(x: 0, y: 0, z: 0.82, w: 0), forKey: "inputBVector")
            tone.setValue(CIVector(x: 0.11, y: 0.13, z: 0.17, w: 0), forKey: "inputBiasVector")
            view.layer?.filters = [invert, hue, tone]
            view.backgroundColor = NSColor(
                calibratedRed: 0.07, green: 0.09, blue: 0.12, alpha: 1)
            view.pageShadowsEnabled = false
        } else {
            view.layer?.filters = nil
            view.backgroundColor = .windowBackgroundColor
            view.pageShadowsEnabled = true
        }
    }

    /// 螢光筆 toggle：選取處已有標記 → 移除；沒有 → 加上。存回 PDF 檔。
    func highlightSelection() {
        guard let view = pdfView, let selection = view.currentSelection else { return }
        let lines = selection.selectionsByLine()

        // 1. 先檢查選取範圍是否壓到既有標記 → 是就移除（= 取消螢光筆）
        var removedAny = false
        for line in lines {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                for annotation in page.annotations
                where annotation.type == "Highlight"
                    && annotation.bounds.intersects(bounds) {
                    page.removeAnnotation(annotation)
                    removedAny = true
                }
            }
        }
        if removedAny {
            view.clearSelection()
            save()
            return
        }

        // 2. 否則新增標記
        for line in lines {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                let annotation = PDFAnnotation(
                    bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = NSColor.systemYellow.withAlphaComponent(0.6)
                page.addAnnotation(annotation)
            }
        }
        view.clearSelection()
        save()
    }

    private func save() {
        guard let url = fileURL else { return }
        pdfView?.document?.write(to: url)
    }
}

struct PDFKitView: NSViewRepresentable {
    let data: Data
    let controller: PDFViewerController

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        controller.pdfView = view
        controller.applyAppearance()
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        controller.pdfView = view
        if context.coordinator.lastData != data {
            context.coordinator.lastData = data
            view.document = PDFDocument(data: data)
        }
        controller.applyAppearance()
    }

    func makeCoordinator() -> Coordinator { Coordinator(data: data) }

    final class Coordinator {
        var lastData: Data
        init(data: Data) { lastData = data }
    }
}
