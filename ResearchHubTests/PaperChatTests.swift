// 守論文問答的純邏輯（HubCore 的 PaperText／PaperChatStream／PaperPrompt／PaperModel）：
// 引文核對、串流 JSONL 解析、提示詞組合、Codex 模型清單解析。
import XCTest
@testable import ResearchHub
@testable import HubCore

final class PaperChatTests: XCTestCase {
    private let pages = [
        "Introduction. We study the conformal bootstrap in three dimensions.",
        "The crossing equation reads ∆ = 1/2. We bound the OPE coefﬁcients and\nthe spec-\ntrum carefully using semideﬁnite programming.",
        "Conclusions. Future work.",
    ]
    private var normalized: [String] { pages.map(PaperText.normalize) }

    func testNormalizeFlattensLigaturesHyphenationAndWhitespace() {
        XCTAssertEqual(PaperText.normalize("OPE coefﬁcients\nspec-\ntrum “q”"), "opecoefficientsspectrum\"q\"")
        XCTAssertEqual(PaperText.loose("∆ = 1/2!"), "12")
    }

    func testLocateFindsQuoteOnClaimedOrNeighbouringPage() {
        XCTAssertEqual(PaperText.locate(quote: "We bound the OPE coefficients", claimedPage: 2, in: pages, normalized: normalized), 2)
        XCTAssertEqual(PaperText.locate(quote: "We bound the OPE coefficients", claimedPage: 3, in: pages, normalized: normalized), 2,
                       "模型說錯一頁也要找得到")
        XCTAssertEqual(PaperText.locate(quote: "crossing equation … semidefinite programming", claimedPage: 2, in: pages, normalized: normalized), 2,
                       "用 … 省略中間的引文各段都要找到")
        XCTAssertNil(PaperText.locate(quote: "this sentence is not in the paper at all", claimedPage: 1, in: pages, normalized: normalized))
        XCTAssertNil(PaperText.locate(quote: "OPE coefficients", claimedPage: 2, in: pages, normalized: normalized), "太短的引文不算數")
    }

    func testCitationsAreParsedAndVerified() {
        let answer = "結論 [p.2「We bound the OPE coefficients and the spectrum」]，另外 [p.1 “made up claim that is not there”]。"
        let cites = PaperText.citations(in: answer, pages: pages, normalized: normalized)
        XCTAssertEqual(cites.count, 2)
        XCTAssertEqual(cites[0].page, 2); XCTAssertTrue(cites[0].verified); XCTAssertEqual(cites[0].foundPage, 2)
        XCTAssertEqual(cites[1].page, 1); XCTAssertFalse(cites[1].verified); XCTAssertNil(cites[1].foundPage)
    }

    func testPromptTextLabelsPagesAndTruncates() {
        let text = PaperText.promptText(pages)
        XCTAssertTrue(text.hasPrefix("\n\n[p.1]\n"))
        XCTAssertTrue(text.contains("[p.3]"))
        let short = PaperText.promptText(pages, limit: 80)
        XCTAssertTrue(short.contains("已省略"))
        XCTAssertFalse(short.contains("[p.3]"))
    }

    func testClaudeStreamParsing() {
        let jsonl = """
        {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"你好"}}}
        {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"，世界"}}}
        not json
        {"type":"result","is_error":false,"result":"你好，世界","session_id":"sess-1"}
        """
        let r = PaperChatStream.parse(jsonl, provider: .claude)
        XCTAssertEqual(r.partial, "你好，世界")
        XCTAssertEqual(r.answer, "你好，世界")
        XCTAssertEqual(r.session, "sess-1")
        XCTAssertNil(r.error)

        let err = PaperChatStream.parse(#"{"type":"result","is_error":true,"result":"rate limited"}"#, provider: .claude)
        XCTAssertEqual(err.error, "rate limited"); XCTAssertNil(err.answer)
    }

    func testCodexStreamParsing() {
        let jsonl = """
        {"type":"thread.started","thread_id":"t-9"}
        {"type":"item.completed","item":{"type":"reasoning","text":"thinking"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"第一段"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"第二段"}}
        """
        let r = PaperChatStream.parse(jsonl, provider: .chatgpt)
        XCTAssertEqual(r.session, "t-9")
        XCTAssertEqual(r.answer, "第一段\n\n第二段")
        XCTAssertEqual(r.partial, r.answer)
        let err = PaperChatStream.parse(#"{"type":"turn.failed","error":{"message":"quota"}}"#, provider: .chatgpt)
        XCTAssertEqual(err.error, "quota")
    }

    func testPromptIncludesPaperOnlyOnFirstTurn() {
        let history = [PaperChatMessage(role: .user, text: "舊問題"),
                       PaperChatMessage(role: .error, text: "失敗"),
                       PaperChatMessage(role: .assistant, text: "舊回答", provider: "Claude")]
        let first = PaperPrompt.build(question: "Q?", quote: "selected", quotePage: 2, provider: .chatgpt,
                                      firstTurn: true, title: "T", pages: pages, priorMessages: history)
        XCTAssertTrue(first.hasPrefix(PaperPrompt.systemPrompt), "Codex 沒有 system prompt 參數，要放進第一則")
        XCTAssertTrue(first.contains("論文標題：T"))
        XCTAssertTrue(first.contains("[p.2]"))
        XCTAssertTrue(first.contains("使用者：舊問題") && first.contains("助理（Claude）：舊回答"))
        XCTAssertFalse(first.contains("失敗"), "錯誤訊息不進先前問答")
        XCTAssertTrue(first.contains("第 2 頁）：\n「selected」"))
        XCTAssertTrue(first.hasSuffix("問題：Q?"))

        let later = PaperPrompt.build(question: "Q2", quote: nil, quotePage: nil, provider: .claude,
                                      firstTurn: false, title: "T", pages: pages, priorMessages: history)
        XCTAssertEqual(later, "問題：Q2")
        let claudeFirst = PaperPrompt.build(question: "Q", quote: nil, quotePage: nil, provider: .claude,
                                            firstTurn: true, title: "T", pages: pages, priorMessages: [])
        XCTAssertFalse(claudeFirst.contains(PaperPrompt.systemPrompt), "Claude 的 system prompt 另外用參數傳")
    }

    func testCodexModelListParsing() {
        let out = "gpt-5.5\tGPT-5.5\tlow,medium,high\tmedium\nMODELS=cached\nbad line\ngpt-x\tX\thigh\t\n"
        let models = PaperModel.parseCodex(out)
        XCTAssertEqual(models.map(\.id), ["gpt-5.5", "gpt-x"])
        XCTAssertEqual(models[0].efforts, ["low", "medium", "high"])
        XCTAssertEqual(models[1].defaultEffort, "high", "沒給預設就用第一個 effort")
    }

    func testZoteroClientPortAndLibraryFilter() {
        XCTAssertEqual(ZoteroClient(port: 0).port, 23119)
        XCTAssertEqual(ZoteroClient(port: 23120).base.absoluteString, "http://localhost:23120/api/users/0")
        let paper = ZoteroItem(key: "A", data: .init(itemType: "journalArticle", title: "x"))
        let note = ZoteroItem(key: "B", data: .init(itemType: "note"))
        let pdf = ZoteroItem(key: "C", data: .init(itemType: "attachment", contentType: "application/pdf"))
        let other = ZoteroItem(key: "D", data: .init(itemType: "attachment", filename: "data.csv"))
        XCTAssertEqual([paper, note, pdf, other].filter(ZoteroClient.isLibraryEntry).map(\.key), ["A", "C"])
    }

    func testChatFileRoundTripsThroughISODateCoders() throws {
        var file = PaperChatFile(zoteroKey: "K", title: "T")
        file.messages = [PaperChatMessage(role: .assistant, text: "a", citations: [.init(page: 1, quote: "q", verified: true, foundPage: 1)])]
        let data = try JSONEncoder.isoPretty.encode(file)
        let back = try JSONDecoder.iso.decode(PaperChatFile.self, from: data)
        // ISO8601 沒有毫秒：日期只比到秒
        XCTAssertEqual(back.messages.map(\.id), file.messages.map(\.id))
        XCTAssertEqual(back.messages.map(\.text), file.messages.map(\.text))
        XCTAssertEqual(back.messages.map(\.citations), file.messages.map(\.citations))
        XCTAssertEqual(back.messages[0].createdAt.timeIntervalSince1970,
                       file.messages[0].createdAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"createdAt\" : \"20"), "日期要是 ISO8601 字串")
    }
}
