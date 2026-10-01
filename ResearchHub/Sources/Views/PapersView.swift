#if os(macOS)
import SwiftUI
import PDFKit
import CoreImage
import Combine
import UniformTypeIdentifiers

/// 論文分頁：左 Zotero library 清單（可搜尋），右內建 PDF 閱讀器。
struct PapersView: View {
    @Environment(FileSystemStore.self) private var store
    private var zotero = ZoteroStore.shared

    @State private var search = ""
    @State private var selected: ZoteroItem?
    @State private var attachment: ZoteroStore.Attachment?
    @State private var pdfData: Data?
    @State private var loadingPDF = false
    @StateObject private var viewer = PDFViewerController()
    /// 中文版（沈浸式翻譯輸出的 PDF）的檢視器
    @StateObject private var transViewer = PDFViewerController()
    @State private var translationData: Data?
    @State private var viewMode: ViewMode = .original
    @State private var importingTranslation = false
    @State private var chatSession: PaperChatSession?
    @AppStorage("papers.showChat") private var showChat = true
    /// 最左邊的論文清單可以收起（拖分隔線到底、或按標題列的側欄按鈕）
    @AppStorage("papers.showList") private var showList = true
    @State private var downloadWatch = TranslationDownloadWatcher()
    @State private var translator = PaperTranslator()
    /// 段落對照（BabelDOC 翻的才有）
    @State private var alignment: PaperAlignment?
    @State private var syncTask: Task<Void, Never>?
    @State private var showTranslateSheet = false
    /// 掃描書的 OCR 版（Papers/<key>/ocr.pdf）：只在背後用，畫面顯示原檔
    @State private var ocrData: Data?

    enum ViewMode: String, CaseIterable, Identifiable {
        case original, translation, sideBySide
        var id: String { rawValue }
        var label: String {
            switch self {
            case .original: return "原文"
            case .translation: return "中文"
            case .sideBySide: return "對照"
            }
        }
    }

    var body: some View {
        // 分隔線跟筆記／LaTeX 一樣用 PersistentSplitView：記得位置、好抓、滑上去變藍
        PersistentSplitView(autosaveName: "PapersPanes", panes: [
            .init(id: "list", minWidth: 180, initialWidth: 300,
                  holdingPriority: .init(260), isVisible: showList,
                  content: hosted(listPane),
                  onVisibilityChange: { showList = $0 }),
            .init(id: "detail", minWidth: 320, content: hosted(detailPane)),
        ])
        .navigationTitle("論文")
        .fileImporter(isPresented: $importingTranslation, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { importTranslation(from: url) }
        }
        .sheet(isPresented: $showTranslateSheet) {
            let doc = viewer.pdfView?.document
            TranslateRangeSheet(
                pageCount: doc?.pageCount ?? 0,
                currentPage: viewer.currentPageIndex ?? 0,
                chapters: TranslateRangeSheet.chapters(of: doc),
                translatedPages: translationData == nil ? [] : (alignment?.translatedPageSet ?? []),
                // 第 1 步：檢查這些頁有沒有文字層（有 OCR 版就看 OCR 版，做過的頁不用再做）
                textDocument: viewer.textDocument ?? doc,
                onStart: { startBabelDOC(pages: $0, needsOCR: $1) })
        }
        .task {
            zotero.restoreZoteroDir()
            await zotero.refresh()
        }
    }

    private func hosted<V: View>(_ view: V) -> AnyView {
        AnyView(view
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(store))
    }

    private var listToggle: some View {
        Button { showList.toggle() } label: {
            Image(systemName: "sidebar.leading")
        }
        .buttonStyle(.borderless)
        .help(showList ? "收起論文清單" : "展開論文清單")
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
                    listToggle
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
                    if pdfData != nil {
                        if translationData != nil {
                            Picker("", selection: $viewMode) {
                                ForEach(ViewMode.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            .help("原文／中文版／左右對照（兩邊同步翻頁）")
                        }
                        Menu {
                            Button("用 BabelDOC 翻譯…") { showTranslateSheet = true }
                                .disabled(selected.map { translator.isRunning($0.key) } ?? true
                                          || translator.runningKey != nil)
                            Button("用沈浸式翻譯產生中文版…") { startImmersiveTranslate() }
                            Button("匯入中文版 PDF…") { importingTranslation = true }
                            if translationData != nil {
                                Divider()
                                Button("移除中文版", role: .destructive) { removeTranslation() }
                            }
                        } label: {
                            Label("中文版", systemImage: "character.book.closed")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("中英對照：用沈浸式翻譯產生中文版 PDF，或匯入已有的（也可以直接把 PDF 拖進閱讀區）")
                        Button {
                            showChat.toggle()
                        } label: {
                            Image(systemName: showChat ? "bubble.left.and.text.bubble.right.fill"
                                                       : "bubble.left.and.text.bubble.right")
                        }
                        .help("問 AI（Claude／ChatGPT）")
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

                if let item = selected, translator.isRunning(item.key) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let secs = Int(ctx.date.timeIntervalSince(translator.startedAt ?? ctx.date))
                            Text(translatorStatus(secs))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.08))
                }
                if let err = translator.lastError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text("翻譯失敗：\(err)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                        Button("關閉") { translator.dismissError() }
                            .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.08))
                }

                if downloadWatch.isWatching {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("在瀏覽器用沈浸式翻譯翻好、下載後，會自動從「下載」資料夾匯入（原文 PDF 已在 Finder 選好，拖進網頁即可）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("取消") { downloadWatch.stop() }
                            .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.08))
                }

                if loadingPDF {
                    ProgressView("載入 PDF…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let pdfData {
                    readerArea(pdfData)
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
                HStack { listToggle; Spacer() }.padding(12)
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
        .surface(.panel, ambient: .thickMaterial)
    }

    // MARK: - 閱讀區：原文／中文／對照 ＋ 問答欄

    private func readerArea(_ data: Data) -> some View {
        PersistentSplitView(autosaveName: "PaperReaderPanes", panes: [
            .init(id: "pdf", minWidth: 280,
                  content: hosted(pdfArea(data)
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        dropTranslation(providers)
                    })),
            .init(id: "chat", minWidth: 280, initialWidth: 380,
                  holdingPriority: .init(260), isVisible: showChat && chatSession != nil,
                  content: hosted(chatPane),
                  onVisibilityChange: { showChat = $0 }),
        ])
    }

    @ViewBuilder
    private var chatPane: some View {
        if let chatSession {
            PaperChatPanel(
                session: chatSession,
                takeSelection: { viewer.selectionInfo() ?? transViewer.selectionInfo() },
                onCite: { page, quote in
                    if viewMode == .translation { viewMode = .sideBySide }
                    viewer.reveal(quote: quote, page: page)
                })
        }
    }

    @ViewBuilder
    private func pdfArea(_ data: Data) -> some View {
        switch (viewMode, translationData) {
        case (.translation, let trans?):
            PDFKitView(data: trans, controller: transViewer)
        case (.sideBySide, let trans?):
            PersistentSplitView(autosaveName: "PaperComparePanes", panes: [
                .init(id: "original", minWidth: 200,
                      content: AnyView(PDFKitView(data: data, controller: viewer))),
                .init(id: "translation", minWidth: 200,
                      content: AnyView(PDFKitView(data: trans, controller: transViewer))),
            ])
            .onAppear(perform: linkPages)
        default:
            PDFKitView(data: data, controller: viewer)
        }
    }

    /// 對照模式：翻一邊、另一邊跟著翻到同一頁；反白一邊、另一邊標出同一段
    private func linkPages() {
        viewer.onPageChange = { [weak transViewer] i in transViewer?.go(toPage: i) }
        transViewer.onPageChange = { [weak viewer] i in viewer?.go(toPage: i) }
        viewer.onSelectionChange = { scheduleSync(from: viewer, to: transViewer) }
        viewer.onClick = { page, point in clickSync(page: page, point: point) }
        transViewer.onSelectionChange = { scheduleSync(from: transViewer, to: viewer) }
    }

    /// 拖曳選取時選取一直在變：停手 0.15 秒再對照
    private func scheduleSync(from source: PDFViewerController, to target: PDFViewerController) {
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, viewMode == .sideBySide else { return }
            guard let anchor = source.selectionAnchor() else {
                // 使用者取消反白 → 另一邊的對應標記也一起拿掉。
                // 但如果是下面那行「清掉另一邊舊選取」造成的空選取，要留著剛標好的段落。
                if !source.selectionWasClearedByApp {
                    target.clearSync()
                    source.clearSync()
                }
                return
            }
            source.clearSync()
            target.clearSelection()   // 另一邊上一次的選取留著會讓人以為那才是對應處
            let center = CGPoint(x: anchor.rect.midX, y: anchor.rect.midY)
            // 1. 句子等級：找出選到的是這段的第幾句，另一邊只標對應的那一句
            if let para = alignment?.sentenceParagraph(onPage: anchor.page, at: center),
               let indices = sentenceTargets(para, page: anchor.page, from: source, to: target,
                                             sourceIsOriginal: source === viewer) {
                target.showSync(page: anchor.page, indices: indices)
                return
            }
            // 2. 段落等級：BabelDOC 的段落方框兩邊一樣；沒有對照資料就從選取的那幾行推出整段
            let box = alignment?.paragraph(onPage: anchor.page, at: center)
                ?? source.paragraphRect(page: anchor.page, around: anchor.rect)
            guard let box else { target.clearSync(); return }
            target.showSync(page: anchor.page, rect: box)
        }
    }

    /// 選取落在段落的哪幾句 → 另一邊對應句子的字元索引
    private func sentenceTargets(_ para: PaperAlignment.Paragraph, page: Int,
                                 from source: PDFViewerController, to target: PDFViewerController,
                                 sourceIsOriginal: Bool) -> [Int]? {
        let mine = sourceIsOriginal ? para.src : para.dst
        let theirs = sourceIsOriginal ? para.dst : para.src
        guard mine.count == theirs.count, mine.count > 1 else { return nil }
        var hits: [Int] = []
        for (i, sentence) in mine.enumerated() where !sentence.isEmpty {
            if let found = source.locate(sentence, page: page, within: para.rect),
               source.selectionTouches(found, page: page) {
                hits.append(i)
            }
        }
        guard !hits.isEmpty else { return nil }
        var out: [Int] = []
        for i in hits {
            // 對面是空字串＝那句被併進鄰句：往前找、找不到再往後找有字的那句
            let j = stride(from: i, through: 0, by: -1).first { !theirs[$0].isEmpty }
                ?? (i..<theirs.count).first { !theirs[$0].isEmpty }
            if let j, let found = target.locate(theirs[j], page: page, within: para.rect) {
                out += found
            }
        }
        return out.isEmpty ? nil : out
    }

    private func translatorStatus(_ secs: Int) -> String {
        switch (translator.phase, translator.withOCR) {
        case (.ocr, _):
            return "第 1 步／共 2 步：OCR 文字辨識中（在本機、免費）…已 \(secs) 秒"
        case (_, true):
            return "第 2 步／共 2 步：BabelDOC 翻譯中…已 \(secs) 秒"
        default:
            return "BabelDOC 翻譯中…（已 \(secs) 秒，通常 1–2 分鐘；可以先讀原文）"
        }
    }

    /// 掃描原檔不能反白：點一下某句，兩邊都標出那一句（找不到句子就標整段）
    private func clickSync(page: Int, point: CGPoint) {
        guard viewMode == .sideBySide, viewer.textDocument != nil, let alignment else { return }
        if let para = alignment.sentenceParagraph(onPage: page, at: point),
           para.src.count == para.dst.count {
            for (i, sentence) in para.src.enumerated() where !sentence.isEmpty {
                guard let mine = viewer.locate(sentence, page: page, within: para.rect),
                      viewer.charsContain(mine, page: page, point: point) else { continue }
                let j = stride(from: i, through: 0, by: -1).first { !para.dst[$0].isEmpty }
                if let j, let theirs = transViewer.locate(para.dst[j], page: page, within: para.rect) {
                    viewer.showSync(page: page, indices: mine)
                    transViewer.clearSelection()
                    transViewer.showSync(page: page, indices: theirs)
                    return
                }
            }
        }
        if let box = alignment.paragraph(onPage: page, at: point) {
            viewer.showSync(page: page, rect: box)
            transViewer.clearSelection()
            transViewer.showSync(page: page, rect: box)
        } else {
            viewer.clearSync()
            transViewer.clearSync()
        }
    }

    private func startBabelDOC(pages: String?, needsOCR: Bool) {
        guard let item = selected, let data = pdfData, let root = store.rootURL else { return }
        // 只翻一部分時，合併進已經翻好的頁（要有段落對照才知道哪些頁翻過；手動匯入的譯文就直接取代）
        let existing: (data: Data, alignment: PaperAlignment)? =
            (pages != nil) ? translationData.flatMap { d in alignment.map { (d, $0) } } : nil
        translator.translate(key: item.key, pdfData: data, ocrData: ocrData, root: root,
                             pages: pages, needsOCR: needsOCR, existing: existing,
                             onOCR: { ocr in
                                 guard selected?.key == item.key else { return }
                                 ocrData = ocr
                                 viewer.textDocument = PDFDocument(data: ocr)
                                 chatSession?.loadPaper(ocr)   // AI 讀 OCR 出來的文字
                             }) { trans, align in
            guard selected?.key == item.key else { return }   // 翻譯期間換了別篇
            translationData = trans
            alignment = align
            viewMode = .sideBySide
        }
    }

    private func translationURL(for item: ZoteroItem) -> URL? {
        store.rootURL.map {
            PaperChatSession.paperDir(root: $0, key: item.key).appendingPathComponent("translation.pdf")
        }
    }

    private func importTranslation(from source: URL) {
        guard let item = selected, let dest = translationURL(for: item) else { return }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: source), PDFDocument(data: data) != nil else { return }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: dest, options: .atomic)
        // 手動匯入的譯文不一定跟 BabelDOC 的段落方框對得上：丟掉舊的對照，改用逐行推段落
        try? FileManager.default.removeItem(at: dest.deletingLastPathComponent().appendingPathComponent("align.json"))
        alignment = nil
        translationData = data
        viewMode = .sideBySide
    }

    /// 沈浸式翻譯沒有給其他 app 用的介面（它是瀏覽器擴充＋網頁版 PDF Pro），
    /// 所以這裡把能自動的都自動：開 PDF Pro 網頁、在 Finder 選好原文 PDF（拖進網頁就好）、
    /// 然後盯著「下載」資料夾，譯好的 PDF 一下載完就自動匯入成這篇的中文版。
    private func startImmersiveTranslate() {
        guard let item = selected else { return }
        if let url = URL(string: "https://app.immersivetranslate.com/pdf-pro/") {
            NSWorkspace.shared.open(url)
        }
        if let file = viewer.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
        let hint = viewer.fileURL?.deletingPathExtension().lastPathComponent
        downloadWatch.start(nameHint: hint) { url in
            guard selected?.key == item.key else { return }
            importTranslation(from: url)
        }
    }

    private func removeTranslation() {
        guard let item = selected, let url = translationURL(for: item) else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent("align.json"))
        translationData = nil
        alignment = nil
        viewMode = .original
    }

    private func dropTranslation(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension.lowercased() == "pdf" else { return }
            Task { @MainActor in importTranslation(from: url) }
        }
        return true
    }

    private func select(_ item: ZoteroItem) {
        selected = item
        pdfData = nil
        attachment = nil
        viewer.fileURL = nil
        loadingPDF = true
        chatSession = PaperChatSession(item: item, root: store.rootURL)
        translationData = nil
        viewer.onPageChange = nil
        transViewer.onPageChange = nil
        viewer.onSelectionChange = nil
        transViewer.onSelectionChange = nil
        viewer.clearSync()
        transViewer.clearSync()
        alignment = nil
        ocrData = nil
        viewer.textDocument = nil
        if let root = store.rootURL,
           case .data(let ocr) = LibraryFileRead.read(
               PaperChatSession.paperDir(root: root, key: item.key).appendingPathComponent("ocr.pdf")) {
            ocrData = ocr
            viewer.textDocument = PDFDocument(data: ocr)
        }
        if let url = translationURL(for: item), case .data(let data) = LibraryFileRead.read(url) {
            translationData = data
            alignment = PaperTranslator.loadAlignment(root: store.rootURL, key: item.key)
        }
        if translationData == nil, viewMode != .original { viewMode = .original }
        Task {
            defer { loadingPDF = false }
            guard let found = await zotero.pdfAttachment(for: item) else { return }
            attachment = found
            if let result = await zotero.pdfData(attachment: found) {
                guard selected?.key == item.key else { return }   // 載入期間換了別篇
                pdfData = result.data
                viewer.fileURL = result.fileURL
                chatSession?.loadPaper(ocrData ?? result.data)   // 掃描書：AI 讀 OCR 版的文字
            }
        }
    }

    /// 一次性授權 Zotero 資料夾（之後用 bookmark 記住）
    private func pickZoteroDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = L("選擇 Zotero 資料夾（預設位置是家目錄下的 Zotero）")
        panel.prompt = L("授權")
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
            if !item.authors.isEmpty { lines.append("\(L("**作者**"))：\(item.authors)") }
            if !item.year.isEmpty { lines.append("\(L("**年份**"))：\(item.year)") }
            if let venue = item.data.publicationTitle, !venue.isEmpty {
                lines.append("\(L("**期刊**"))：\(venue)")
            }
            if let doi = item.data.DOI, !doi.isEmpty { lines.append("**DOI**：\(doi)") }
            lines.append("**Zotero**：zotero://select/library/items/\(item.key)")
            lines.append("")
            lines.append("## \(L("筆記"))")
            lines.append("")
            try? lines.joined(separator: "\n")
                .write(to: url, atomically: true, encoding: .utf8)
        }
        store.openNote(url)
    }
}

// MARK: - 等沈浸式翻譯的下載

/// 盯著「下載」資料夾：開始之後新出現的 PDF（下載完、大小不再變）就交給 onFound。
/// 檔名有原文 PDF 的前幾個字的優先（沈浸式翻譯的輸出檔名會沿用原檔名）。最多等 30 分鐘。
@Observable
@MainActor
final class TranslationDownloadWatcher {
    private(set) var isWatching = false
    @ObservationIgnored private var task: Task<Void, Never>?

    static var downloadsURL: URL {
        URL(fileURLWithPath: "/Users/\(NSUserName())/Downloads", isDirectory: true)
    }

    func start(nameHint: String?, onFound: @escaping @MainActor (URL) -> Void) {
        stop()
        isWatching = true
        let dir = Self.downloadsURL
        let before = Set(Self.pdfs(in: dir).map(\.path))
        let hint = nameHint.map { String($0.prefix(20)).lowercased() }
        task = Task { [weak self] in
            var lastSizes: [String: Int] = [:]
            for _ in 0..<600 {   // 3 秒一次，30 分鐘
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                let fresh = Self.pdfs(in: dir).filter { !before.contains($0.path) }
                let ranked = fresh.sorted { a, b in
                    let ma = hint.map { a.lastPathComponent.lowercased().contains($0) } ?? false
                    let mb = hint.map { b.lastPathComponent.lowercased().contains($0) } ?? false
                    return ma && !mb
                }
                for url in ranked {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    defer { lastSizes[url.path] = size }
                    // 大小連續兩次一樣才算下載完
                    if size > 0, lastSizes[url.path] == size {
                        self?.isWatching = false
                        onFound(url)
                        return
                    }
                }
            }
            self?.isWatching = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isWatching = false
    }

    private static func pdfs(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "pdf" }
    }
}

// MARK: - PDFKit wrapper

/// PDF 檢視控制：暗色模式（反色 + 色相旋轉，顏色大致保留）與螢光筆。
@MainActor
final class PDFViewerController: ObservableObject {
    weak var pdfView: PDFView?
    /// 掃描書：畫面顯示原檔（沒有文字），文字位置改從 OCR 版讀（同一份掃描、頁面幾何一樣）。
    /// 使用者希望看到的永遠是原檔——OCR 有錯也不會出現在眼前。
    var textDocument: PDFDocument? { didSet { resetTextCache() } }

    /// 用來找字的那一頁：有 OCR 版就用它，沒有就用畫面上的文件
    func textPage(_ index: Int) -> PDFPage? {
        let doc = textDocument ?? pdfView?.document
        guard let doc, index >= 0, index < doc.pageCount else { return nil }
        return doc.page(at: index)
    }

    /// 點了頁面上的某一點（掃描原檔沒辦法反白，對照改用點的）
    var onClick: ((Int, CGPoint) -> Void)?
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
        clearSync()   // 對照用的暫時標記不能寫進 Zotero 的 PDF
        pdfView?.document?.write(to: url)
    }

    // MARK: 對照模式：反白一邊、另一邊標出同一段

    /// 選取改變時通知（並排對照用來在另一邊標出對應段落）
    var onSelectionChange: (() -> Void)?
    private static let syncMark = "researchhub-sync"
    private var syncAnnotations: [(PDFPage, PDFAnnotation)] = []

    /// 目前選取在第幾頁（0 起算）、選取範圍的方框
    func selectionAnchor() -> (page: Int, rect: CGRect)? {
        guard let view = pdfView, let doc = view.document, let sel = view.currentSelection,
              let text = sel.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let page = sel.pages.first else { return nil }
        return (doc.index(for: page), sel.bounds(for: page))
    }

    /// 在這一頁的 rect 範圍內，把文字一行一行淡淡標色，並捲到看得到的地方
    func showSync(page index: Int, rect: CGRect) {
        guard let page = textPage(index) else { return }
        let lines = page.selection(for: rect.insetBy(dx: -1, dy: -1))?.selectionsByLine() ?? []
        var rects = lines.map { $0.bounds(for: page) }.filter { $0.width > 1 && $0.height > 1 }
        if rects.isEmpty { rects = [rect] }   // 抓不到文字（例如字是畫成圖形的）就整塊標
        highlight(page: index, lineRects: rects)
    }

    /// 只標這幾段文字（句子等級的對照）
    func showSync(page index: Int, ranges: [NSRange]) {
        guard let page = textPage(index) else { return }
        let rects = ranges.flatMap { range in
            (page.selection(for: range)?.selectionsByLine() ?? []).map { $0.bounds(for: page) }
        }.filter { $0.width > 1 && $0.height > 1 }
        guard !rects.isEmpty else { return }
        highlight(page: index, lineRects: rects)
    }

    private func highlight(page index: Int, lineRects rects: [CGRect]) {
        clearSync()
        guard let view = pdfView, let doc = view.document,
              index >= 0, index < doc.pageCount, let page = doc.page(at: index) else { return }
        let color = NSColor.systemBlue.withAlphaComponent(0.22)
        let rect = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        for r in rects {
            let a = PDFAnnotation(bounds: r.insetBy(dx: -1, dy: -0.5), forType: .highlight, withProperties: nil)
            a.color = color
            a.userName = Self.syncMark
            page.addAnnotation(a)
            syncAnnotations.append((page, a))
        }
        let onScreen = view.convert(rect, from: page)
        if !view.bounds.insetBy(dx: 0, dy: 20).intersects(onScreen) {
            view.go(to: CGRect(x: rect.minX, y: rect.maxY - 1, width: 1, height: 1), on: page)
        }
    }

    /// 由 app 自己清掉選取（不是使用者取消反白）。選取改變的通知是非同步送來的，
    /// 所以記個時間：這之後短時間內收到的「選取變空」是 app 造成的。
    private var appClearedSelectionAt: Date?
    var selectionWasClearedByApp: Bool {
        appClearedSelectionAt.map { Date().timeIntervalSince($0) < 0.6 } ?? false
    }

    func clearSelection() {
        guard pdfView?.currentSelection != nil else { return }
        appClearedSelectionAt = Date()
        pdfView?.clearSelection()
    }

    func clearSync() {
        for (page, a) in syncAnnotations { page.removeAnnotation(a) }
        syncAnnotations = []
    }

    // MARK: 句子定位（句子等級的對照）

    /// 每頁每個字的位置（page.string 的索引、方框、字）。
    /// ⚠️ 不能用 page.characterBounds(at:)：它的索引跟 page.string 對不起來（實測 x 差了 60pt），
    /// 要用 page.selection(for: NSRange) 取方框才準。一頁幾千個字，算一次就快取。
    private var charCache: [Int: [(i: Int, b: CGRect, s: String)]] = [:]
    private var boxCache: [String: (chars: [Character], idx: [Int])] = [:]
    /// 換了文件（例如新的譯文）就要丟掉
    func resetTextCache() { charCache = [:]; boxCache = [:] }

    private func pageChars(_ index: Int) -> [(i: Int, b: CGRect, s: String)] {
        if let hit = charCache[index] { return hit }
        guard let page = textPage(index) else { return [] }
        let text = (page.string ?? "") as NSString
        var out: [(i: Int, b: CGRect, s: String)] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length),
                                 options: .byComposedCharacterSequences) { sub, r, _, _ in
            guard let sub, !sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let sel = page.selection(for: r) else { return }
            let b = sel.bounds(for: page)
            if b.width > 0 { out.append((r.location, b, sub)) }
        }
        charCache[index] = out
        return out
    }

    /// 段落方框裡的字，照畫面位置重排（一行一行、由左到右），只留字母數字。
    /// 譯文 PDF 抽出的文字是左右兩欄一行一行交錯的，照 page.string 的順序找不到跨行的句子。
    private func boxText(_ index: Int, _ box: CGRect) -> (chars: [Character], idx: [Int]) {
        let key = "\(index)|\(box.minX),\(box.minY),\(box.maxX),\(box.maxY)"
        if let hit = boxCache[key] { return hit }
        let area = box.insetBy(dx: -3, dy: -3)
        let items = pageChars(index)
            .filter { area.contains(CGPoint(x: $0.b.midX, y: $0.b.midY)) }
            .sorted { $0.b.midY > $1.b.midY }
        var lines: [[(i: Int, b: CGRect, s: String)]] = []
        for it in items {
            if let first = lines.last?.first,
               abs(first.b.midY - it.b.midY) < max(2, 0.45 * max(first.b.height, it.b.height)) {
                lines[lines.count - 1].append(it)
            } else {
                lines.append([it])
            }
        }
        var chars: [Character] = [], idx: [Int] = []
        for line in lines {
            for it in line.sorted(by: { $0.b.minX < $1.b.minX }) {
                for c in Self.loose(it.s) { chars.append(c); idx.append(it.i) }
            }
        }
        boxCache[key] = (chars, idx)
        return (chars, idx)
    }

    nonisolated static func loose(_ s: String) -> [Character] {
        var t = s.lowercased()
        for (a, b) in [("ﬁ", "fi"), ("ﬂ", "fl"), ("ﬀ", "ff"), ("ﬃ", "ffi"), ("ﬄ", "ffl")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.unicodeScalars
            .filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
            .map(Character.init)
    }

    /// 這句話在段落方框裡的位置（page.string 的字元索引）。
    /// 以空白切成片段依序比對（公式、引用編號在對照資料裡是空白，PDF 裡卻有字），
    /// 片段之間允許夾少量多出來的字。實測 Das 2018：原文 96%、譯文 98% 的句子找得到。
    func locate(_ sentence: String, page index: Int, within box: CGRect) -> [Int]? {
        let pieces = sentence.split(whereSeparator: { $0.isWhitespace })
            .map { Self.loose(String($0)) }.filter { !$0.isEmpty }
        guard let first = pieces.first, pieces.reduce(0, { $0 + $1.count }) >= 2 else { return nil }
        let bt = boxText(index, box)
        let c = bt.chars
        func matches(_ pat: [Character], at k: Int) -> Bool {
            k >= 0 && k + pat.count <= c.count && Array(c[k..<(k + pat.count)]) == pat
        }
        let gap = 24
        for i in 0..<max(0, c.count - first.count + 1) where matches(first, at: i) {
            var pos = i + first.count, skipped = 0, ok = true
            for piece in pieces.dropFirst() {
                if pos < c.count, let q = (pos...min(c.count - 1, pos + gap)).first(where: { matches(piece, at: $0) }) {
                    pos = q + piece.count
                } else if pieces.count > 4 && skipped < 2 {
                    skipped += 1
                } else {
                    ok = false
                    break
                }
            }
            if ok, pos > i { return Array(bt.idx[i..<pos]) }
        }
        return nil
    }

    /// 這些字有沒有包住這一點（掃描原檔用點的對照）
    func charsContain(_ indices: [Int], page index: Int, point: CGPoint) -> Bool {
        let wanted = Set(indices)
        return pageChars(index).contains { wanted.contains($0.i) && $0.b.insetBy(dx: -2, dy: -2).contains(point) }
    }

    /// 這些字有沒有落在目前的選取裡
    func selectionTouches(_ indices: [Int], page index: Int) -> Bool {
        guard let view = pdfView, let doc = view.document, let sel = view.currentSelection,
              let page = sel.pages.first, doc.index(for: page) == index else { return false }
        let lines = sel.selectionsByLine().map { $0.bounds(for: page).insetBy(dx: -0.5, dy: -0.5) }
        let wanted = Set(indices)
        return pageChars(index).contains { ch in
            wanted.contains(ch.i) && lines.contains { $0.contains(CGPoint(x: ch.b.midX, y: ch.b.midY)) }
        }
    }

    /// 把字元索引併成連續範圍（中間隔幾個空白、標點也算連續）再標色
    func showSync(page index: Int, indices: [Int]) {
        let sorted = Array(Set(indices)).sorted()
        guard var start = sorted.first else { return }
        var ranges: [NSRange] = [], last = start
        for i in sorted.dropFirst() {
            if i - last > 3 {
                ranges.append(NSRange(location: start, length: last - start + 1))
                start = i
            }
            last = i
        }
        ranges.append(NSRange(location: start, length: last - start + 1))
        showSync(page: index, ranges: ranges)
    }

    /// 沒有 align.json 時的退路：從選取的那幾行往上下延伸，行距正常就算同一段，
    /// 遇到大空白（段落間距）或換欄就停。
    func paragraphRect(page index: Int, around rect: CGRect) -> CGRect? {
        guard let page = textPage(index),
              let all = page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() else { return nil }
        // 同一欄的行（水平方向跟選取重疊夠多），由上而下
        let column = all.map { $0.bounds(for: page) }
            .filter { b in
                let overlap = min(b.maxX, rect.maxX) - max(b.minX, rect.minX)
                return b.height > 1 && overlap > 0.3 * min(b.width, max(rect.width, 20))
            }
            .sorted { $0.maxY > $1.maxY }
        guard let hit = column.firstIndex(where: { $0.intersects(rect.insetBy(dx: 0, dy: -1)) }) else { return nil }
        let lineHeight = column[hit].height
        var top = hit, bottom = hit
        while top > 0, column[top - 1].minY - column[top].maxY < lineHeight * 0.9 { top -= 1 }
        while bottom < column.count - 1, column[bottom].minY - column[bottom + 1].maxY < lineHeight * 0.9 { bottom += 1 }
        return column[top...bottom].reduce(column[top]) { $0.union($1) }
    }

    // MARK: 翻頁同步、引文跳轉、選取文字

    /// 翻頁時通知（並排對照用來同步另一邊）
    var onPageChange: ((Int) -> Void)?

    var currentPageIndex: Int? {
        guard let view = pdfView, let page = view.currentPage, let doc = view.document else { return nil }
        return doc.index(for: page)
    }

    func go(toPage index: Int) {
        guard let view = pdfView, let doc = view.document,
              index >= 0, index < doc.pageCount, let page = doc.page(at: index),
              view.currentPage != page else { return }
        view.go(to: page)
    }

    /// 選取的文字與它在第幾頁（1 起算），給「引用到提問」用
    func selectionInfo() -> (text: String, page: Int)? {
        guard let view = pdfView, let sel = view.currentSelection,
              let text = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let page = sel.pages.first, let doc = view.document else { return nil }
        return (text, doc.index(for: page) + 1)
    }

    /// 點了回答裡的引文：跳到那頁，並把那段原文選起來（找不到就只跳頁）。
    /// PDF 的文字常有斷行與連字號，整句找不到時改用前幾個字找。
    func reveal(quote: String, page: Int) {
        guard let view = pdfView, let shown = view.document else { return }
        // 掃描原檔沒有文字：在 OCR 版裡找，找到後在原檔同一位置標出來
        let doc = textDocument ?? shown
        let words = quote.replacingOccurrences(of: "…", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let attempts = [words.joined(separator: " "),
                        words.prefix(8).joined(separator: " "),
                        words.prefix(4).joined(separator: " ")].filter { $0.count >= 4 }
        for text in attempts {
            let hits = doc.findString(text, withOptions: [.caseInsensitive])
            guard !hits.isEmpty else { continue }
            let best = hits.min { a, b in
                let pa = a.pages.first.map { doc.index(for: $0) } ?? 0
                let pb = b.pages.first.map { doc.index(for: $0) } ?? 0
                return abs(pa - (page - 1)) < abs(pb - (page - 1))
            }
            if let best {
                if textDocument != nil, let p = best.pages.first {
                    showSync(page: doc.index(for: p), rect: best.bounds(for: p))
                } else {
                    view.setCurrentSelection(best, animate: true)
                    view.go(to: best)
                }
                return
            }
        }
        go(toPage: page - 1)
    }
}

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
