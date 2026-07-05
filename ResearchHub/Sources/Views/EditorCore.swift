#if os(macOS)
import SwiftUI
import AppKit

/// 編輯器檢視模式（筆記與日記共用）。
enum EditorMode: String, CaseIterable, Identifiable {
    case blocks, split, source, preview
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .blocks: return "square.text.square"
        case .split: return "rectangle.split.2x1"
        case .source: return "chevron.left.forwardslash.chevron.right"
        case .preview: return "eye"
        }
    }

    var label: String {
        switch self {
        case .blocks: return "區塊"
        case .split: return "雙欄"
        case .source: return "源碼"
        case .preview: return "預覽"
        }
    }
}

/// 模式切換器（放在各自的 header 裡）。
struct EditorModePicker: View {
    @Binding var mode: EditorMode
    var available: [EditorMode] = [.split, .source, .preview]

    var body: some View {
        Picker("檢視模式", selection: $mode) {
            ForEach(available) { m in
                Image(systemName: m.icon)
                    .help(LocalizedStringKey(m.label))
                    .tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: CGFloat(available.count) * 44)
    }
}

/// 共用編輯器核心：源碼 + KaTeX 預覽、自動存檔、貼圖存到檔案旁的 assets/。
/// 檔案不存在時以空白內容開始，首次有內容才寫入磁碟。
struct EditorCore: View {
    let fileURL: URL
    @Binding var mode: EditorMode

    /// 外部（如規劃儀式）要求把文字附加到某檔案的編輯器尾端。
    /// 走通知而不是直接改檔案：檔案正被編輯器持有，直接寫檔會被 autosave 蓋掉。
    static let appendNotification = Notification.Name("EditorCore.append")

    static func requestAppend(to url: URL, text: String) {
        NotificationCenter.default.post(
            name: appendNotification, object: nil,
            userInfo: ["url": url, "text": text])
    }

    @EnvironmentObject private var store: FileSystemStore
    @AppStorage("settings.editorFontSize") private var editorFontSize = 14.0
    @ObservedObject private var zotero = ZoteroStore.shared
    @State private var text = ""
    @State private var initialText = ""
    @State private var fileExisted = false
    @State private var scrollSync = ScrollSync()
    @State private var saveTask: Task<Void, Never>?

    private var fileDir: URL { fileURL.deletingLastPathComponent() }

    var body: some View {
        content
            // 編輯區墊一層厚材質，避免環境色彩場干擾閱讀
            .background(.thickMaterial)
            .onAppear(perform: load)
            .onDisappear { saveNow() }
            .onChange(of: text) { scheduleAutosave() }
            .onReceive(NotificationCenter.default.publisher(for: Self.appendNotification)) { note in
                guard let url = note.userInfo?["url"] as? URL, url == fileURL,
                      let appended = note.userInfo?["text"] as? String else { return }
                if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
                text += appended
            }
            // 載入 Zotero 文獻供 \cite 解析（已有快取就不重抓）。
            .task { if zotero.items.isEmpty { await zotero.refresh() } }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .blocks:
            ZStack {
                BlockEditorView(text: $text, baseDir: fileDir, documentID: fileURL)
                BlockEditorStatusOverlay()
            }
        case .split:
            HSplitView {
                SourceTextView(
                    text: $text,
                    fontSize: CGFloat(editorFontSize),
                    onScroll: { scrollSync = $0 },
                    onPasteImage: saveImage
                )
                // minWidth 壓低:窄視窗時雙欄仍能縮進可用寬度,不會把側欄擠歪、
                // 造成選單位置與首頁/日記不一致。
                .frame(minWidth: 150)
                MarkdownPreviewView(
                    text: text, scrollSync: scrollSync, baseDir: fileDir,
                    citationItems: zotero.items, onOpenNote: { store.openNote($0) })
                    .frame(minWidth: 150)
            }
        case .source:
            SourceTextView(
                text: $text,
                fontSize: CGFloat(editorFontSize),
                onScroll: nil,
                onPasteImage: saveImage
            )
        case .preview:
            MarkdownPreviewView(
                text: text, scrollSync: ScrollSync(), baseDir: fileDir,
                citationItems: zotero.items, onOpenNote: { store.openNote($0) })
        }
    }

    // MARK: - Load & save

    private func load() {
        if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
            text = content
            initialText = content
            fileExisted = true
        } else {
            text = ""
            initialText = ""
            fileExisted = false
        }
    }

    private func scheduleAutosave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        // 檔案原本不存在且內容仍是空的 → 不落地，避免製造空檔案
        guard fileExisted || !text.isEmpty else { return }
        guard text != initialText || !fileExisted else { return }
        try? FileManager.default.createDirectory(
            at: fileDir, withIntermediateDirectories: true)
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            initialText = text
            fileExisted = true
        } catch {
            // 寫入失敗保持靜默，下次 autosave 再試
        }
    }

    // MARK: - Paste image

    private func saveImage(_ image: NSImage) -> String? {
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return nil }

        let dir = fileDir.appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "img-\(f.string(from: .now)).png"
        do {
            try png.write(to: dir.appendingPathComponent(name))
        } catch {
            return nil
        }
        return "![](assets/\(name))\n"
    }
}

// （WebResources 移到 Services/WebResources.swift，iOS 版共用）

/// Block 編輯器載入狀態覆蓋層：載入中顯示進度、失敗顯示重試。
struct BlockEditorStatusOverlay: View {
    @ObservedObject private var host = BlockEditorHost.shared

    var body: some View {
        if let error = host.loadError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("重試") { host.retry() }
            }
            .padding(20)
        } else if !host.isReady {
            ProgressView("載入編輯器…")
        }
    }
}
#endif
