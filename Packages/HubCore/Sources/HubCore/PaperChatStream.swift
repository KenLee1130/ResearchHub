import Foundation

/// 讀小幫手寫出的 JSON lines（Claude 的 stream-json／Codex 的 exec --json），
/// 拿出串流中的部分文字、最後的回答、session id 與錯誤。
public nonisolated enum PaperChatStream {
    public struct Parsed: Sendable {
        public var partial = ""
        public var answer: String?
        public var session: String?
        public var error: String?
        public init() {}
    }

    public static func parse(_ text: String, provider: PaperProvider) -> Parsed {
        var r = Parsed()
        for line in text.split(separator: "\n") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            let type = d["type"] as? String
            if provider == .chatgpt {
                if type == "thread.started" { r.session = d["thread_id"] as? String }
                if type == "item.completed", let item = d["item"] as? [String: Any],
                   item["type"] as? String == "agent_message", let t = item["text"] as? String {
                    r.answer = (r.answer.map { $0 + "\n\n" } ?? "") + t
                    r.partial = r.answer ?? ""
                }
                if type == "error" || type == "turn.failed" {
                    r.error = (d["message"] as? String)
                        ?? ((d["error"] as? [String: Any])?["message"] as? String) ?? "Codex 回報錯誤"
                }
            } else {
                if type == "stream_event", let ev = d["event"] as? [String: Any],
                   ev["type"] as? String == "content_block_delta",
                   let delta = ev["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta", let t = delta["text"] as? String {
                    r.partial += t
                }
                if type == "result" {
                    r.session = d["session_id"] as? String
                    if d["is_error"] as? Bool == true {
                        r.error = (d["result"] as? String) ?? "Claude 回報錯誤"
                    } else {
                        r.answer = d["result"] as? String
                    }
                }
            }
        }
        return r
    }
}
