#if os(macOS)
import SwiftUI

/// 從 Zotero 文獻庫挑一篇，插入 \cite{key} 到目前作用中的編輯器游標處。
struct CitationPickerView: View {
    @ObservedObject private var zotero = ZoteroStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [ZoteroItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return zotero.items }
        return zotero.items.filter {
            $0.title.lowercased().contains(q)
                || $0.authors.lowercased().contains(q)
                || $0.year.contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜尋標題、作者、年份…", text: $search)
                    .textFieldStyle(.plain)
                if zotero.isLoading { ProgressView().controlSize(.small) }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()

            if let err = zotero.errorMessage, zotero.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "wifi.slash").font(.title).foregroundStyle(.secondary)
                    Text(err)
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重試") { Task { await zotero.refresh() } }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { item in
                            Button { insert(item) } label: { row(item) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(width: 470, height: 470)
        .task { if zotero.items.isEmpty { await zotero.refresh() } }
    }

    private func row(_ item: ZoteroItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                Text(item.authors).lineLimit(1)
                if !item.year.isEmpty { Text(item.year) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func insert(_ item: ZoteroItem) {
        ActiveEditorRegistry.shared.insert("\\cite{\(item.key)}")
        dismiss()
    }
}
#endif
