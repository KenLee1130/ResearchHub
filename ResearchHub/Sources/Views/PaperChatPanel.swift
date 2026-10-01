#if os(macOS)
import SwiftUI

/// 論文右側的問答欄（像 alphaXiv）：選取 PDF 文字 →「引用」→ 問 Claude 或 ChatGPT。
/// 回答裡的引文 [p.3「…」] 會逐字核對論文原文：✓ 找得到、⚠︎ 找不到（可能是幻覺）。
/// 點引文就跳到 PDF 那一頁並選起那段原文。
struct PaperChatPanel: View {
    let session: PaperChatSession
    /// 取得 PDF 目前選取的文字與頁碼
    var takeSelection: () -> (text: String, page: Int)?
    /// 點了引文：(頁碼, 原文)
    var onCite: (Int, String) -> Void

    @AppStorage("paperChat.provider") private var providerRaw = PaperProvider.claude.rawValue
    @AppStorage("paperChat.claudeModel") private var claudeModelID = "claude-sonnet-5-5"
    @AppStorage("paperChat.claudeEffort") private var claudeEffort = "high"
    @AppStorage("paperChat.codexModel") private var codexModelID = ""
    @AppStorage("paperChat.codexEffort") private var codexEffort = ""
    private var catalog = PaperModelCatalog.shared
    @State private var draft = ""
    @State private var quote: String?
    @State private var quotePage: Int?
    @State private var confirmClear = false
    @FocusState private var composerFocused: Bool

    private var provider: PaperProvider { PaperProvider(rawValue: providerRaw) ?? .claude }
    private var models: [PaperModel] { provider == .claude ? PaperModel.claude : catalog.chatgpt }
    private var model: PaperModel {
        let id = provider == .claude ? claudeModelID : codexModelID
        return models.first { $0.id == id } ?? models[0]
    }
    private var effort: String {
        let e = provider == .claude ? claudeEffort : codexEffort
        return model.efforts.contains(e) ? e : model.defaultEffort
    }
    private var ai: PaperAIChoice { PaperAIChoice(provider: provider, model: model, effort: effort) }

    private func setModel(_ id: String) {
        if provider == .claude { claudeModelID = id } else { codexModelID = id }
    }
    private func setEffort(_ e: String) {
        if provider == .claude { claudeEffort = e } else { codexEffort = e }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if session.chat.messages.isEmpty && !session.isAsking {
                emptyState
            } else {
                MarkdownPreviewView(text: transcript, onLink: handleLink)
            }
            Divider()
            composer
        }
        .confirmationDialog("清除這篇論文的所有問答？", isPresented: $confirmClear) {
            Button("清除", role: .destructive) { session.clear() }
        }
    }

    // MARK: 頂列

    private var header: some View {
        // 兩行：上面選服務（＋清除），下面選模型與思考強度。
        // 擠成一行的話欄寬一窄，整排的理想寬度會撐破欄位、左右被裁掉。
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Picker("", selection: $providerRaw) {
                ForEach(PaperProvider.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("換一個 AI 時，它會收到整篇論文和先前的問答，可以請它給第二意見")
            Spacer(minLength: 0)
            if !session.chat.messages.isEmpty {
                Button { confirmClear = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("清除問答")
            }
          }
          HStack(spacing: 10) {
            Menu {
                ForEach(models) { m in
                    Button { setModel(m.id) } label: {
                        if m.id == model.id { Label(m.label, systemImage: "checkmark") } else { Text(m.label) }
                    }
                }
            } label: {
                Text(model.label)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("模型")
            Menu {
                ForEach(model.efforts, id: \.self) { e in
                    Button { setEffort(e) } label: {
                        let name = Self.effortLabel(e) + (e == model.defaultEffort ? "（預設）" : "")
                        if e == effort { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            } label: {
                Text(Self.effortLabel(effort))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("思考強度（effort）：越高越慢、越用額度，但推理更仔細")
            Spacer(minLength: 0)
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onAppear { catalog.refresh() }
    }

    static func effortLabel(_ e: String) -> String {
        switch e {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra high"
        case "max": return "Max"
        case "ultra": return "Ultra"
        default: return e
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("問這篇論文")
                .font(.headline)
            Text("回答會附上論文原文引用，app 會逐字核對：✓ 找得到原文，⚠︎ 找不到（可能是 AI 編的）。點引用會跳到 PDF 那一頁。")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Self.suggestions, id: \.self) { s in
                Button {
                    send(s)
                } label: {
                    Text(s)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .disabled(!session.pagesReady)
            }
            if !session.pagesReady {
                Label("正在讀取論文文字…", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 舊版存的 provider 代號 → 顯示名稱
    private static let legacyNames = ["claude-sonnet": "Claude Sonnet", "claude-opus": "Claude Opus",
                                      "chatgpt": "ChatGPT"]

    private static let suggestions = [
        "這篇論文的主要貢獻是什麼？",
        "用直覺的方式解釋核心方法",
        "這篇的關鍵假設與限制有哪些？",
    ]

    // MARK: 輸入列

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let quote {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.quote").foregroundStyle(.secondary)
                    Text("p.\(quotePage ?? 0)「\(quote)」")
                        .font(.caption)
                        .lineLimit(3)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button { self.quote = nil; quotePage = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08)))
            }
            HStack(alignment: .bottom, spacing: 6) {
                Button {
                    if let sel = takeSelection() {
                        quote = sel.text
                        quotePage = sel.page
                        composerFocused = true
                    }
                } label: {
                    Image(systemName: "text.quote")
                }
                .buttonStyle(.borderless)
                .help("把 PDF 裡選取的文字帶進提問")
                TextField("問這篇論文…（⌘↩ 送出）", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .onSubmit { send(draft) }
                if session.isAsking {
                    ProgressView().controlSize(.small)
                } else {
                    Button { send(draft) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || !session.pagesReady)
                }
            }
            Text("用你的 \(provider.label) 訂閱 · 引用會逐字核對原文")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
    }

    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, session.pagesReady, !session.isAsking else { return }
        session.ask(t, quote: quote, quotePage: quotePage, ai: ai)
        draft = ""
        quote = nil
        quotePage = nil
    }

    // MARK: 對話內容（整段交給 Markdown＋KaTeX 預覽畫）

    private var transcript: String {
        var blocks: [String] = []
        for m in session.chat.messages {
            switch m.role {
            case .user:
                var b = "**你**"
                if let q = m.quote, !q.isEmpty {
                    b += "\n\n> p.\(m.quotePage ?? 0)「\(q.replacingOccurrences(of: "\n", with: " "))」"
                }
                b += "\n\n" + m.text
                blocks.append(b)
            case .assistant:
                let name = Self.legacyNames[m.provider ?? ""] ?? m.provider ?? "AI"
                let cites = m.citations ?? []
                var head = "**\(name)**"
                if !cites.isEmpty {
                    let ok = cites.filter(\.verified).count
                    head += ok == cites.count
                        ? "　<small>引用 \(ok)/\(cites.count) 已在原文找到 ✓</small>"
                        : "　<small>⚠︎ \(cites.count - ok) 則引用在論文中找不到，請小心</small>"
                } else {
                    head += "　<small>（這則回答沒有附論文引用）</small>"
                }
                blocks.append(head + "\n\n" + linkify(m.text, cites))
            case .error:
                blocks.append("<small>⚠︎ \(m.text)</small>")
            }
        }
        if session.isAsking {
            blocks.append("**\(ai.label)**\n\n" + (session.streamingText.isEmpty ? "思考中…" : session.streamingText))
        }
        return blocks.joined(separator: "\n\n---\n\n")
    }

    /// 把 [p.3「…」] 換成可點的連結；找不到原文的把引文露出來讓人自己判斷。
    private func linkify(_ text: String, _ cites: [PaperCitation]) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\[p\.?\s*(\d+)\s*[「"“](.+?)[」"”]\s*\]"#,
                                                options: [.dotMatchesLineSeparators]) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for (i, m) in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).enumerated() {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let c = i < cites.count ? cites[i]
                : PaperCitation(page: Int(ns.substring(with: m.range(at: 1))) ?? 0,
                                quote: ns.substring(with: m.range(at: 2)), verified: false)
            let page = c.foundPage ?? c.page
            var comps = URLComponents()
            comps.scheme = "researchhub"
            comps.host = "cite"
            comps.queryItems = [URLQueryItem(name: "page", value: String(page)),
                                URLQueryItem(name: "q", value: c.quote)]
            let url = comps.url?.absoluteString ?? ""
            out += c.verified
                ? " [p.\(page) ✓](\(url))"
                : " [p.\(c.page) ⚠︎ 原文找不到：「\(c.quote)」](\(url))"
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private func handleLink(_ url: URL) -> Bool {
        guard url.scheme == "researchhub", url.host == "cite",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let page = Int(comps.queryItems?.first { $0.name == "page" }?.value ?? "") ?? 1
        let q = comps.queryItems?.first { $0.name == "q" }?.value ?? ""
        onCite(page, q)
        return true
    }
}
#endif
