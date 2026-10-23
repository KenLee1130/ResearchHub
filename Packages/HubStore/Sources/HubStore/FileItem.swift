import Foundation
import HubCore

public nonisolated struct FileItem: Identifiable, Hashable, Sendable {
    public let url: URL
    public let isFolder: Bool
    public let modified: Date
    /// 這個資料夾是不是 LaTeX 專案（裡面有含 \documentclass 的 .tex）
    public var isProject: Bool = false

    public init(url: URL, isFolder: Bool, modified: Date, isProject: Bool = false) {
        self.url = url; self.isFolder = isFolder; self.modified = modified; self.isProject = isProject
    }

    public var id: URL { url }

    public var name: String {
        isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }
}
