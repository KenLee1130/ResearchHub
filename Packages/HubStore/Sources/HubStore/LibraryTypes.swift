import Foundation
import HubCore

/// 側欄筆記樹的一個節點（原本是 FileSystemStore.TreeNode）
public nonisolated struct LibraryTreeNode: Identifiable, Hashable, Sendable {
    public let url: URL
    public let isFolder: Bool
    /// LaTeX 專案：本身是資料夾，但當成一篇筆記看待（不展開內容）
    public var isProject: Bool = false
    public var children: [LibraryTreeNode]?

    public init(url: URL, isFolder: Bool, isProject: Bool = false, children: [LibraryTreeNode]? = nil) {
        self.url = url; self.isFolder = isFolder; self.isProject = isProject; self.children = children
    }

    public var id: URL { url }
    public var name: String {
        (isFolder || isProject) ? url.lastPathComponent
                                : url.deletingPathExtension().lastPathComponent
    }
}

/// 筆記或日記裡的一條待辦（原本是 FileSystemStore.TodoItem）
public nonisolated struct LibraryTodoItem: Identifiable, Hashable, Sendable {
    public let noteURL: URL
    public let lineIndex: Int
    /// 原始文字（含 !high / @due 標記）
    public let text: String
    public let done: Bool
    /// 解析後的標記（顯示用 cleanText、priority、due）
    public let meta: TodoMeta

    public init(noteURL: URL, lineIndex: Int, text: String, done: Bool, meta: TodoMeta) {
        self.noteURL = noteURL; self.lineIndex = lineIndex; self.text = text; self.done = done; self.meta = meta
    }

    public var id: String { "\(noteURL.path)#\(lineIndex)" }
    public var noteName: String { noteURL.deletingPathExtension().lastPathComponent }
}

/// 在多天日記重複出現的未完成待辦（原本是 FileSystemStore.RepeatedTodo）
public nonisolated struct RepeatedTodo: Identifiable, Hashable, Sendable {
    public let text: String
    /// 出現且未完成的日記日期（由舊到新）
    public let dates: [Date]

    public init(text: String, dates: [Date]) { self.text = text; self.dates = dates }

    public var count: Int { dates.count }
    public var id: String { text }
}
