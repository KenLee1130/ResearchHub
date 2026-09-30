import Foundation

nonisolated struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let isFolder: Bool
    let modified: Date
    /// 這個資料夾是不是 LaTeX 專案（裡面有含 \documentclass 的 .tex）
    var isProject: Bool = false

    var id: URL { url }

    var name: String {
        isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }
}
