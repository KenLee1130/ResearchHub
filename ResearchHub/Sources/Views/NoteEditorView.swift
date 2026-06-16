import SwiftUI

/// 筆記編輯器：標題列（返回、檔名、模式切換）+ 共用編輯器核心。
struct NoteEditorView: View {
    let noteURL: URL
    /// true 代表這個編輯器自己就在一個獨立視窗裡（不顯示返回／另開視窗按鈕）。
    var isStandaloneWindow: Bool = false
    var onClose: () -> Void

    @Environment(\.openWindow) private var openWindow
    @State private var mode: EditorMode = .split
    @State private var showCitePicker = false
    @State private var showNoteLinkPicker = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if !isStandaloneWindow {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("[", modifiers: .command)
                }

                Text(noteURL.deletingPathExtension().lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                // 把這份筆記變成獨立視窗，方便同時編輯兩份筆記
                if !isStandaloneWindow {
                    Button {
                        openWindow(id: "note", value: noteURL)
                        onClose()   // 已彈出到新視窗，關掉這裡的內嵌編輯器避免同檔兩開
                    } label: {
                        Image(systemName: "macwindow.on.rectangle")
                            .padding(5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("在新視窗開啟（可同時編輯兩份筆記）")
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                }

                // 插入 [[筆記]] 引用到游標處
                Button {
                    showNoteLinkPicker = true
                } label: {
                    Image(systemName: "link")
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("引用其他筆記 [[…]]")
                .keyboardShortcut("l", modifiers: [.command, .shift])

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
                .help("輸出 PDF")
                .keyboardShortcut("e", modifiers: .command)

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
        .sheet(isPresented: $showNoteLinkPicker) {
            NoteLinkPickerView()
        }
    }
}

/// 獨立筆記視窗的內容容器：由 ResearchHubApp 的 WindowGroup(for: URL.self) 驅動。
/// 讓使用者把一份筆記彈到自己的視窗，方便同時打兩份筆記。
struct NoteWindowView: View {
    let noteURL: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AmbientBackground()
            if let noteURL {
                NoteEditorView(noteURL: noteURL, isStandaloneWindow: true) {
                    dismiss()
                }
                .navigationTitle(noteURL.deletingPathExtension().lastPathComponent)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("找不到這份筆記")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .background(WindowMinSizeSetter(minWidth: 460, minHeight: 380))
    }
}
