#if os(macOS)
import SwiftUI

/// Cmd+K 全域搜尋：搜筆記檔名與內文，點擊或 Enter 開啟。
struct SearchPaletteView: View {
    @EnvironmentObject private var store: FileSystemStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [SearchResult] = []
    @FocusState private var fieldFocused: Bool

    struct SearchResult: Identifiable {
        let url: URL
        let name: String
        let snippet: String?
        var id: URL { url }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜尋筆記（檔名或內文）…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { openFirst() }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("關閉（Esc）")
            }
            .padding(14)

            Divider()

            if results.isEmpty {
                Text(query.isEmpty ? "輸入關鍵字開始搜尋" : "沒有結果")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(results) { result in
                            Button {
                                open(result)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.name)
                                        .font(.callout.weight(.medium))
                                    if let snippet = result.snippet {
                                        Text(snippet)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.primary.opacity(0.04))
                            )
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(width: 560, height: 380)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { runSearch() }
        .onExitCommand { dismiss() }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 1 else {
            results = []
            return
        }
        var found: [SearchResult] = []
        for url in store.allNoteURLs() {
            let name = url.deletingPathExtension().lastPathComponent
            if name.lowercased().contains(q) {
                found.append(SearchResult(url: url, name: name, snippet: nil))
                continue
            }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lower = content.lowercased()
            if let range = lower.range(of: q) {
                // 取符合處前後各 ~40 字當 snippet
                let start = content.index(
                    range.lowerBound, offsetBy: -40,
                    limitedBy: content.startIndex) ?? content.startIndex
                let end = content.index(
                    range.upperBound, offsetBy: 40,
                    limitedBy: content.endIndex) ?? content.endIndex
                let snippet = String(content[start..<end])
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                found.append(SearchResult(url: url, name: name, snippet: "…\(snippet)…"))
            }
            if found.count >= 20 { break }
        }
        results = found
    }

    private func openFirst() {
        if let first = results.first { open(first) }
    }

    private func open(_ result: SearchResult) {
        dismiss()
        store.openNote(result.url)
    }
}
#endif
