#if os(macOS)
import Foundation
import HubCore
import Observation
import PDFKit

/// ChatGPT 帳號能選的模型（跟 Codex 要一次，記在 UserDefaults，下次開 app 先用舊的）
@Observable
@MainActor
final class PaperModelCatalog {
    static let shared = PaperModelCatalog()
    private(set) var chatgpt: [PaperModel]
    @ObservationIgnored private var loaded = false
    private static let cacheKey = "paperChat.codexModels"

    private init() {
        let cached = UserDefaults.standard.string(forKey: Self.cacheKey).map(PaperModel.parseCodex) ?? []
        chatgpt = cached.isEmpty ? PaperModel.chatgptFallback : cached
    }

    func refresh() {
        guard !loaded else { return }
        loaded = true
        LatexCompiler.runHelper(["models"]) { [weak self] output, _ in
            let models = PaperModel.parseCodex(output)
            guard let self, !models.isEmpty else { return }
            self.chatgpt = models
            UserDefaults.standard.set(output, forKey: Self.cacheKey)
        }
    }
}

// MARK: - 論文文字（PDF 抽字用 PDFKit，所以留在 app；其餘純邏輯在 HubCore 的 PaperText）

extension PaperText {
    /// 從 PDF 抽出每一頁的文字。提問時整篇（附頁碼）交給 AI，核對引文也靠它。
    static func pages(from data: Data) -> [String] {
        guard let doc = PDFDocument(data: data) else { return [] }
        return (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
    }
}

// MARK: - 一篇論文的問答

@Observable
@MainActor
final class PaperChatSession {
    let zoteroKey: String
    let title: String
    private(set) var chat: PaperChatFile
    /// 正在產生中的回答（串流）
    private(set) var streamingText = ""
    private(set) var isAsking = false
    private(set) var pagesReady = false

    @ObservationIgnored private var pages: [String] = []
    @ObservationIgnored private var normalizedPages: [String] = []
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(item: ZoteroItem, root: URL?) {
        zoteroKey = item.key
        title = item.title
        let dir = root.map { Self.paperDir(root: $0, key: item.key) }
        fileURL = dir?.appendingPathComponent("chat.json")
        if let fileURL, let text = FileSystemStore.safeRead(fileURL),
           let loaded = try? JSONDecoder.iso.decode(PaperChatFile.self, from: Data(text.utf8)) {
            chat = loaded
        } else {
            chat = PaperChatFile(zoteroKey: item.key, title: item.title)
        }
    }

    /// <資料夾>/Papers/<Zotero key>/：問答紀錄、中文版 PDF 都放這裡（跟著 iCloud 走）
    static func paperDir(root: URL, key: String) -> URL {
        root.appendingPathComponent("Papers", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    /// PDF 載入後在背景抽文字
    func loadPaper(_ data: Data) {
        Task {
            let extracted = await Task.detached(priority: .userInitiated) { () -> ([String], [String]) in
                let p = PaperText.pages(from: data)
                return (p, p.map(PaperText.normalize))
            }.value
            pages = extracted.0
            normalizedPages = extracted.1
            pagesReady = !pages.isEmpty
        }
    }

    func clear() {
        chat.messages = []
        chat.sessions = [:]
        save()
    }

    // MARK: 提問

    func ask(_ question: String, quote: String?, quotePage: Int?, ai: PaperAIChoice) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAsking else { return }
        chat.messages.append(PaperChatMessage(role: .user, text: q, quote: quote, quotePage: quotePage))
        save()

        let session = chat.sessions[ai.provider.rawValue]
        let prompt = PaperPrompt.build(question: q, quote: quote, quotePage: quotePage,
                                       provider: ai.provider, firstTurn: session == nil,
                                       title: title, pages: pages,
                                       priorMessages: Array(chat.messages.dropLast()))
        let work = workDir
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try? PaperPrompt.systemPrompt.write(to: work.appendingPathComponent("system.txt"),
                                     atomically: true, encoding: .utf8)
        try? prompt.write(to: work.appendingPathComponent("prompt.txt"),
                          atomically: true, encoding: .utf8)
        let out = work.appendingPathComponent("out.jsonl")
        try? FileManager.default.removeItem(at: out)

        isAsking = true
        streamingText = ""
        startPolling(out, ai: ai)
        LatexCompiler.runHelper(["ask", ai.provider.cli, work.path, ai.model.id, session ?? "-", ai.effort]) { [weak self] output, error in
            guard let self else { return }
            self.pollTask?.cancel()
            let fields = LatexCompiler.parseFields(output)
            let parsed = Self.parse(out: out, provider: ai.provider)
            if let sid = parsed.session { self.chat.sessions[ai.provider.rawValue] = sid }
            if let answer = parsed.answer, !answer.isEmpty {
                let cites = PaperText.citations(in: answer, pages: self.pages,
                                                normalized: self.normalizedPages)
                self.chat.messages.append(PaperChatMessage(
                    role: .assistant, text: answer, provider: ai.label, citations: cites))
            } else {
                // 接續的 session 失效（例如被清掉了）→ 下次重開新對話
                if session != nil { self.chat.sessions[ai.provider.rawValue] = nil }
                let detail = error?.localizedDescription ?? fields["ERR"]
                    ?? parsed.error ?? (fields["TIMEOUT"] == "1" ? "超過 5 分鐘沒有回應" : "沒有收到回答")
                self.chat.messages.append(PaperChatMessage(
                    role: .error, text: "\(ai.label) 沒有回答：\(detail)", provider: ai.label))
            }
            self.streamingText = ""
            self.isAsking = false
            self.save()
        }
    }

    /// 容器裡的工作資料夾（小幫手不能碰 iCloud，題目和回覆都在這裡交換）
    private var workDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("papers/\(zoteroKey)", isDirectory: true)
    }

    // MARK: 串流

    private func startPolling(_ out: URL, ai: PaperAIChoice) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let provider = ai.provider
                let partial = await Task.detached { Self.parse(out: out, provider: provider).partial }.value
                guard let self, !Task.isCancelled else { return }
                if partial != self.streamingText { self.streamingText = partial }
            }
        }
    }

    /// 讀小幫手寫出的 JSON lines（解析本體在 HubCore 的 PaperChatStream）。
    nonisolated private static func parse(out: URL, provider: PaperProvider) -> PaperChatStream.Parsed {
        guard let text = try? String(contentsOf: out, encoding: .utf8) else { return .init() }
        return PaperChatStream.parse(text, provider: provider)
    }

    private func save() {
        guard let fileURL else { return }
        let snapshot = chat
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder.isoPretty.encode(snapshot) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}

#endif
