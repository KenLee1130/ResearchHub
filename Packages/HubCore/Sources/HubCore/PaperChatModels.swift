import Foundation

// MARK: - 資料模型（存在 <資料夾>/Papers/<Zotero key>/chat.json）

/// 回答裡的一則引文：模型宣稱「第 page 頁有這段原文」。
/// app 會拿論文抽出來的文字逐字比對，對得上才算 verified——幻覺最常見的樣子就是
/// 「引用了論文沒寫的話」或「頁碼亂掰」，這一步把它們標出來。
public nonisolated struct PaperCitation: Codable, Hashable, Sendable {
    public var page: Int
    public var quote: String
    /// 原文裡真的找到了（找到的頁碼可能跟模型說的差一頁，以實際找到的為準）
    public var verified: Bool
    public var foundPage: Int?

    public init(page: Int, quote: String, verified: Bool, foundPage: Int? = nil) {
        self.page = page; self.quote = quote; self.verified = verified; self.foundPage = foundPage
    }
}

public nonisolated struct PaperChatMessage: Codable, Identifiable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant, error }
    public var id = UUID()
    public var role: Role
    public var text: String
    /// 提問時引用的 PDF 選取文字與頁碼
    public var quote: String?
    public var quotePage: Int?
    /// 回答的 AI（例如「Claude Opus 5.5 · high」）
    public var provider: String?
    public var createdAt = Date()
    public var citations: [PaperCitation]?

    public init(id: UUID = UUID(), role: Role, text: String, quote: String? = nil, quotePage: Int? = nil,
                provider: String? = nil, createdAt: Date = Date(), citations: [PaperCitation]? = nil) {
        self.id = id; self.role = role; self.text = text; self.quote = quote; self.quotePage = quotePage
        self.provider = provider; self.createdAt = createdAt; self.citations = citations
    }
}

public nonisolated struct PaperChatFile: Codable, Sendable {
    public var zoteroKey: String
    public var title: String
    public var messages: [PaperChatMessage] = []
    /// 各 AI 的對話 session（接續追問時不必重送整篇論文）
    public var sessions: [String: String] = [:]

    public init(zoteroKey: String, title: String, messages: [PaperChatMessage] = [], sessions: [String: String] = [:]) {
        self.zoteroKey = zoteroKey; self.title = title; self.messages = messages; self.sessions = sessions
    }
}

/// 可以問的 AI 服務。都用使用者自己的訂閱：Claude Code CLI、Codex CLI（ChatGPT 帳號登入）。
public nonisolated enum PaperProvider: String, CaseIterable, Identifiable, Sendable {
    case claude, chatgpt
    public var id: String { rawValue }
    public var label: String { self == .claude ? "Claude" : "ChatGPT" }
    public var cli: String { self == .claude ? "claude" : "codex" }
}

/// 一個可選的模型，以及它支援的思考強度（effort）。
public nonisolated struct PaperModel: Hashable, Identifiable, Sendable {
    public let id: String          // 傳給 CLI 的模型名
    public let label: String
    public let efforts: [String]
    public let defaultEffort: String

    public init(id: String, label: String, efforts: [String], defaultEffort: String) {
        self.id = id; self.label = label; self.efforts = efforts; self.defaultEffort = defaultEffort
    }

    public static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    /// Claude Code 支援的模型（舊版 CLI 不認得新模型——2026-10-01 從 2.1.161 更新後才能用 Opus 5.5／Fable 5.1）
    public static let claude: [PaperModel] = [
        .init(id: "claude-opus-5-5", label: "Opus 5.5", efforts: claudeEfforts, defaultEffort: "high"),
        .init(id: "claude-fable-5-1", label: "Fable 5.1", efforts: claudeEfforts, defaultEffort: "high"),
        .init(id: "claude-sonnet-5-5", label: "Sonnet 5.5", efforts: claudeEfforts, defaultEffort: "high"),
        .init(id: "claude-haiku-4-5", label: "Haiku 4.5", efforts: claudeEfforts, defaultEffort: "medium"),
    ]
    /// ChatGPT 帳號能用哪些模型由小幫手讀 Codex 的模型清單（helper models）；讀不到時用這份
    public static let chatgptFallback: [PaperModel] = [
        .init(id: "gpt-5.6-sol", label: "GPT-5.6-Sol",
              efforts: ["low", "medium", "high", "xhigh", "max", "ultra"], defaultEffort: "medium"),
        .init(id: "gpt-5.5", label: "GPT-5.5",
              efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "medium"),
    ]

    /// 解析 helper models 的輸出（slug \t 名稱 \t effort1,effort2 \t 預設）
    public static func parseCodex(_ output: String) -> [PaperModel] {
        output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, !f[0].isEmpty, !f[0].contains("=") else { return nil }
            let efforts = f[2].split(separator: ",").map(String.init)
            return PaperModel(id: f[0], label: f[1], efforts: efforts,
                              defaultEffort: f[3].isEmpty ? (efforts.first ?? "medium") : f[3])
        }
    }
}

/// 一次提問用哪個 AI、哪個模型、多強的思考
public nonisolated struct PaperAIChoice: Sendable {
    public var provider: PaperProvider
    public var model: PaperModel
    public var effort: String

    public init(provider: PaperProvider, model: PaperModel, effort: String) {
        self.provider = provider; self.model = model; self.effort = effort
    }

    public var label: String { "\(provider.label) \(model.label) · \(effort)" }
}

extension JSONDecoder {
    public nonisolated static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension JSONEncoder {
    public nonisolated static var isoPretty: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
