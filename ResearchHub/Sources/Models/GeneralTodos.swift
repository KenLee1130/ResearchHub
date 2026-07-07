import SwiftUI
import Combine

// MARK: - Models

/// 首頁的一般待辦：還沒決定哪天做的任務。
struct GeneralTodo: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var createdAt: Date = .now
    var done: Bool = false
    var completedAt: Date?
}

/// 垃圾桶：放棄的待辦（含重複加入多次都沒做的日記待辦）。
struct TrashedTodo: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    /// 曾被加入待辦的次數（日記重複待辦會 ≥ 2）
    var occurrences: Int = 1
    var trashedAt: Date = .now
    /// 進垃圾桶的原因，例如「加入 3 次都沒完成」
    var reason: String = ""
}

/// Claude 寫給使用者的觀察與鼓勵，存於 .hub/claude/insights.json。
/// App 只負責讀取顯示；由 Claude（或其他工具）直接編輯該檔。
struct ClaudeInsights: Codable {
    var updatedAt: Date?
    /// 顯示在首頁的觀察 / 鼓勵訊息
    var message: String = ""
    /// 今日排程建議：Claude 依日記待辦 + 蕃茄鐘習慣排的時段（多行文字，可為 nil）
    var schedule: String?
}

// 這些 JSON 之後會由 Claude 直接手動編輯 → 解碼一律容忍缺欄位。

extension GeneralTodo {
    private enum CodingKeys: String, CodingKey { case id, text, createdAt, done, completedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}

extension TrashedTodo {
    private enum CodingKeys: String, CodingKey { case id, text, occurrences, trashedAt, reason }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        occurrences = try c.decodeIfPresent(Int.self, forKey: .occurrences) ?? 1
        trashedAt = try c.decodeIfPresent(Date.self, forKey: .trashedAt) ?? .now
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

extension ClaudeInsights {
    private enum CodingKeys: String, CodingKey { case updatedAt, message, schedule }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        schedule = try c.decodeIfPresent(String.self, forKey: .schedule)
    }
}

/// 週檢討的每週數字（.hub/weekly.json，由 Claude 週日檢討時 append；app 唯讀顯示）。
struct WeeklyRecord: Codable, Hashable {
    /// ISO 週，如 "2026-W28"
    var week: String
    var executed: Int = 0
    var planned: Int = 0
    var artifacts: Int = 0
    var refereeOpen: Int?
    var idleWeeks: Int = 0
}

extension WeeklyRecord {
    private enum CodingKeys: String, CodingKey {
        case week, executed, planned, artifacts, refereeOpen, idleWeeks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        week = try c.decode(String.self, forKey: .week)
        executed = try c.decodeIfPresent(Int.self, forKey: .executed) ?? 0
        planned = try c.decodeIfPresent(Int.self, forKey: .planned) ?? 0
        artifacts = try c.decodeIfPresent(Int.self, forKey: .artifacts) ?? 0
        refereeOpen = try c.decodeIfPresent(Int.self, forKey: .refereeOpen)
        idleWeeks = try c.decodeIfPresent(Int.self, forKey: .idleWeeks) ?? 0
    }
}

// MARK: - Store

/// 一般待辦與垃圾桶，落地於根資料夾的 .hub/todos.json；
/// Claude 觀察讀自 .hub/claude/insights.json。
@MainActor
final class GeneralTodoStore: ObservableObject {

    @Published private(set) var todos: [GeneralTodo] = []
    @Published private(set) var trash: [TrashedTodo] = []
    @Published private(set) var insights: ClaudeInsights?
    /// 週檢討歷史（新到舊排在後面；由 Claude 寫入）
    @Published private(set) var weekly: [WeeklyRecord] = []

    private var fileURL: URL?
    private var insightsURL: URL?
    private var weeklyURL: URL?

    private struct Payload: Codable {
        var todos: [GeneralTodo]
        var trash: [TrashedTodo]

        init(todos: [GeneralTodo], trash: [TrashedTodo]) {
            self.todos = todos
            self.trash = trash
        }

        private enum CodingKeys: String, CodingKey { case todos, trash }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            todos = try c.decodeIfPresent([GeneralTodo].self, forKey: .todos) ?? []
            trash = try c.decodeIfPresent([TrashedTodo].self, forKey: .trash) ?? []
        }
    }

    // MARK: - Setup

    func configure(rootURL: URL?) {
        guard let rootURL else {
            fileURL = nil
            insightsURL = nil
            weeklyURL = nil
            todos = []
            trash = []
            insights = nil
            weekly = []
            return
        }
        let hub = rootURL.appendingPathComponent(".hub", isDirectory: true)
        let claudeDir = hub.appendingPathComponent("claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        fileURL = hub.appendingPathComponent("todos.json")
        insightsURL = claudeDir.appendingPathComponent("insights.json")
        weeklyURL = hub.appendingPathComponent("weekly.json")
        reload()
    }

    /// 重新從磁碟載入（Claude 或其他工具可能直接改了檔案）。
    func reload() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let payload = try? decoder.decode(Payload.self, from: data) {
            todos = payload.todos
            trash = payload.trash
        } else {
            todos = []
            trash = []
        }

        if let insightsURL,
           let data = try? Data(contentsOf: insightsURL),
           let loaded = try? decoder.decode(ClaudeInsights.self, from: data),
           !loaded.message.isEmpty || !(loaded.schedule ?? "").isEmpty {
            insights = loaded
        } else {
            insights = nil
        }

        if let weeklyURL,
           let data = try? Data(contentsOf: weeklyURL),
           let loaded = try? decoder.decode([WeeklyRecord].self, from: data) {
            weekly = loaded
        } else {
            weekly = []
        }
    }

    private func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Payload(todos: todos, trash: trash)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Todos

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // 同文字的未完成待辦已存在就不重複加
        guard !todos.contains(where: { !$0.done && $0.text == trimmed }) else { return }
        todos.append(GeneralTodo(text: trimmed))
        save()
    }

    func toggle(_ todo: GeneralTodo) {
        guard let i = todos.firstIndex(where: { $0.id == todo.id }) else { return }
        todos[i].done.toggle()
        todos[i].completedAt = todos[i].done ? .now : nil
        save()
    }

    /// 把一般待辦丟進垃圾桶。
    func moveToTrash(_ todo: GeneralTodo, reason: String = "") {
        todos.removeAll { $0.id == todo.id }
        trash.insert(TrashedTodo(text: todo.text, occurrences: 1, reason: reason), at: 0)
        save()
    }

    /// 把（日記裡重複出現的）待辦記進垃圾桶。
    func trashItem(text: String, occurrences: Int, reason: String) {
        trash.insert(TrashedTodo(text: text, occurrences: occurrences, reason: reason), at: 0)
        save()
    }

    /// 帶 @due 的待辦搬進日記後移除（不進垃圾桶——它以 live 副本活在日記裡）。
    func removeMigrated(text: String) {
        todos.removeAll { !$0.done && $0.text == text }
        save()
    }

    /// 從垃圾桶救回 → 變成一般待辦。
    func restore(_ item: TrashedTodo) {
        trash.removeAll { $0.id == item.id }
        if !todos.contains(where: { !$0.done && $0.text == item.text }) {
            todos.append(GeneralTodo(text: item.text))
        }
        save()
    }

    func deleteFromTrash(_ item: TrashedTodo) {
        trash.removeAll { $0.id == item.id }
        save()
    }

    func clearTrash() {
        trash.removeAll()
        save()
    }
}
