#if os(macOS)
import SwiftUI
import HubEditor
import HubStore
import HubCore
import PDFKit
import CoreImage
import Combine
import UniformTypeIdentifiers

/// 論文分頁：左 Zotero library 清單（可搜尋），右內建 PDF 閱讀器。
struct PapersView: View {
    @Environment(FileSystemStore.self) private var store
    private var zotero = AppContainer.shared.zotero

    @State private var search = ""
    @State private var selected: ZoteroItem?
    @State private var attachment: ZoteroStore.Attachment?
    @State private var pdfData: Data?
    @State private var loadingPDF = false
    @StateObject private var viewer = PDFViewerController()
    /// 中文版（沈浸式翻譯輸出的 PDF）的檢視器
    @StateObject private var transViewer = PDFViewerController()
    @State private var commands = ClosureCommandHandler()
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
        .pageCommands(commands) { cmd in
            // ⌘F：焦點所在的那份 PDF；都沒焦點就看得到的那份（原文優先）
            guard cmd == .find else { return false }
            let visible = [viewer.pdfView, transViewer.pdfView].compactMap { $0 }.filter(EditorHandle.isShowing)
            let target = visible.first { v in
                (v.window?.firstResponder as? NSView)?.isDescendant(of: v) ?? false
            } ?? visible.first
            guard let target else { return false }
            AppContainer.shared.pageFinder.show(in: target)
            return true
        }
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
            consumeRequestedPaper()
        }
        // 全 app 搜尋點了論文 → 選它（論文頁已經開著時也要接得到）
        .onChange(of: store.requestedPaperKey) { consumeRequestedPaper() }
        .onAppear { consumeRequestedPaper() }
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

    private func consumeRequestedPaper() {
        guard let key = store.requestedPaperKey,
              let item = zotero.items.first(where: { $0.key == key }) else { return }
        store.requestedPaperKey = nil
        if selected?.key != key { select(item) }
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
#endif
