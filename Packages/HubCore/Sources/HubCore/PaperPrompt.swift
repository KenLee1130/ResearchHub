import Foundation

/// 論文問答的提示詞：防幻覺的規則，以及每一輪送給 AI 的內容。
public nonisolated enum PaperPrompt {
    /// 防幻覺的規則。重點是「每個關於論文的說法都要附逐字引文」，app 會核對。
    public static let systemPrompt = """
    你是研究論文的閱讀助理。使用者正在讀一篇論文，論文全文（每頁前面標了 [p.N]）在第一則訊息裡。
    規則：
    1. 用繁體中文回答；術語第一次出現時附英文原文。數學用 LaTeX（行內 $...$，獨立式 $$...$$）。
    2. 關於「這篇論文說了什麼」的每個重點，都要附上引文，格式必須是 [p.頁碼「英文原文逐字片段」]。
       引文必須從論文一字不改地複製（可用 … 省略中間），長度 5 到 30 個英文字；不要翻譯引文。
    3. 論文裡找不到根據的，直接說「論文中沒有提到」，不要猜。
    4. 需要用到論文以外的背景知識時，可以講，但必須在那段開頭標「（背景知識，非論文內容）」，且不要附引文。
    5. 不確定的地方要說不確定。回答精簡，先給結論再解釋。
    """

    /// 一輪提問的內容。第一輪附論文全文（與換 AI 接手時的先前問答）；之後只送問題。
    /// - priorMessages: 這一題之前的對話（不含剛加進去的這一題）
    public static func build(question: String, quote: String?, quotePage: Int?,
                             provider: PaperProvider, firstTurn: Bool,
                             title: String, pages: [String],
                             priorMessages: [PaperChatMessage]) -> String {
        var parts: [String] = []
        if firstTurn {
            if provider == .chatgpt { parts.append(systemPrompt) }   // Codex 沒有 system prompt 參數
            parts.append("論文標題：\(title)\n\n=== 論文全文開始 ===\(PaperText.promptText(pages))\n=== 論文全文結束 ===")
            // 換一個 AI 接手時，讓它知道之前問過什麼（例如請它給第二意見）
            let history = priorMessages.suffix(8).filter { $0.role != .error }
            if !history.isEmpty {
                let lines = history.map { m in
                    (m.role == .user ? "使用者：" : "助理（\(m.provider ?? "AI")）：") + m.text
                }
                parts.append("=== 先前的問答（供參考，可能有錯，請以論文為準） ===\n" + lines.joined(separator: "\n\n"))
            }
        }
        if let quote, !quote.isEmpty {
            parts.append("我選取的段落（第 \(quotePage.map(String.init) ?? "?") 頁）：\n「\(quote)」")
        }
        parts.append("問題：\(question)")
        return parts.joined(separator: "\n\n")
    }
}
