#if os(macOS)
import SwiftUI

/// 從目前 Notes/ 裡挑一份筆記，插入 `[[筆記]]` 引用到作用中的編輯器游標處。
/// 名稱不唯一時插入含資料夾的相對路徑，避免引用對象有歧義。
struct NoteLinkPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var links: [NoteLink] = []

    private var filtered: [NoteLink] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return links }
        return links.filter {
            $0.name.lowercased().contains(q) || $0.displayPath.lowercased().contains(q)
        }
    }

    private var nameCount: [String: Int] {
        var c: [String: Int] = [:]
        for e in links { c[e.name.lowercased(), default: 0] += 1 }
        return c
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜尋筆記名稱或路徑…", text: $search)
                    .textFieldStyle(.plain)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()

            if links.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title).foregroundStyle(.secondary)
                    Text("找不到其他筆記")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered, id: \.self) { link in
                            Button { insert(link) } label: { row(link) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(width: 470, height: 470)
        .onAppear { links = NoteLinkIndex.shared.entries() }
    }

    private func row(_ link: NoteLink) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(link.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            if link.name != link.displayPath {
                Text(link.displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func insert(_ link: NoteLink) {
        let target = (nameCount[link.name.lowercased()] ?? 0) > 1 ? link.displayPath : link.name
        ActiveEditorRegistry.shared.insert("[[\(target)]]")
        dismiss()
    }
}
#endif
