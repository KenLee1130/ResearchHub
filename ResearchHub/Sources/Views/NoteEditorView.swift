import SwiftUI

/// 筆記編輯器：標題列（返回、檔名、模式切換）+ 共用編輯器核心。
struct NoteEditorView: View {
    let noteURL: URL
    var onClose: () -> Void

    @State private var mode: EditorMode = .split
    @State private var showCitePicker = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)

                Text(noteURL.deletingPathExtension().lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                // 從 Zotero 插入 \cite{...} 到游標處
                Button {
                    showCitePicker = true
                } label: {
                    Image(systemName: "text.quote")
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("插入 Zotero 引用 \\cite{}")
                .keyboardShortcut("y", modifiers: .command)

                Button {
                    PDFExporter.shared.export(noteURL: noteURL)
                } label: {
                    Image(systemName: "arrow.down.doc")
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("輸出 PDF（快速，KaTeX）")
                .keyboardShortcut("e", modifiers: .command)

                // 用本機 LaTeX 工具鏈（pandoc + xelatex）輸出道地排版 PDF
                Button {
                    LaTeXPDFExporter.shared.export(noteURL: noteURL)
                } label: {
                    Image(systemName: "function")
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("用本機 LaTeX 輸出 PDF（pandoc + xelatex；需安裝 MacTeX）")
                .keyboardShortcut("e", modifiers: [.command, .shift])

                EditorModePicker(mode: $mode)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            EditorCore(fileURL: noteURL, mode: $mode)
        }
        .sheet(isPresented: $showCitePicker) {
            CitationPickerView()
        }
    }
}
