import Foundation

struct FileItem: Identifiable, Hashable {
    let url: URL
    let isFolder: Bool
    let modified: Date

    var id: URL { url }

    var name: String {
        isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }
}
