import SwiftUI
import WebKit
import Combine

/// Notion 式 block 編輯器（日記用）：WKWebView + Tiptap。
/// markdown 仍是唯一真實來源——載入時 markdown → blocks，編輯時 blocks → markdown 回傳 binding。
/// 支援：/ 選單、markdown 快捷輸入、$...$ / $$...$$ KaTeX 數學節點（點擊編輯）、Cmd+V 貼圖。
struct BlockEditorView {
    @Binding var text: String
    var baseDir: URL?
    /// 文件身分（換日記/換檔案時用來重置宿主狀態）
    var documentID: URL?

    /// 共用 webView 永遠掛在「最新的」容器上；舊容器被 SwiftUI 回收時不會帶走它。
    private func attachWebView(to container: WebViewContainer) {
        let webView = BlockEditorHost.shared.webView
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        container.addSubview(webView)
        #if os(macOS)
        container.needsLayout = true
        #else
        container.setNeedsLayout()
        #endif
    }

    private func sync() {
        let host = BlockEditorHost.shared
        host.textBinding = $text
        host.baseDir = baseDir
        if host.documentID != documentID {
            // 換了文件：清掉上一份的推送/回傳記錄，確保一定重新渲染
            host.documentID = documentID
            host.resetForNewDocument()
        }
        host.pushIfNeeded(text)
    }
}

#if os(macOS)
extension BlockEditorView: NSViewRepresentable {
    func makeNSView(context: Context) -> WebViewContainer {
        let container = WebViewContainer()
        attachWebView(to: container)
        sync()
        return container
    }

    func updateNSView(_ container: WebViewContainer, context: Context) {
        attachWebView(to: container)
        sync()
    }
}

/// 容器自己負責把 webView 撐滿（比 autoresizing 從零尺寸起算可靠）。
final class WebViewContainer: NSView {
    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
    }
}
#else
extension BlockEditorView: UIViewRepresentable {
    func makeUIView(context: Context) -> WebViewContainer {
        let container = WebViewContainer()
        attachWebView(to: container)
        sync()
        return container
    }

    func updateUIView(_ container: WebViewContainer, context: Context) {
        attachWebView(to: container)
        sync()
    }
}

/// 容器自己負責把 webView 撐滿（比 autoresizing 從零尺寸起算可靠）。
final class WebViewContainer: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.first?.frame = bounds
    }
}
#endif

/// 常駐的 block 編輯器宿主：WKWebView 只建立並載入一次（app 啟動即預載），
/// 之後切到日記分頁是即時顯示，只推送新的 markdown 內容。
@MainActor
final class BlockEditorHost: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = BlockEditorHost()

    let webView: WKWebView
    var baseDir: URL?
    var textBinding: Binding<String>?
    var documentID: URL?

    @Published private(set) var isReady = false
    @Published private(set) var loadError: String?

    private var lastTextFromJS: String?
    private var lastPushed: String?
    private var pendingText: String?
    private var assetCache: [String: String] = [:]
    private var retryCount = 0

    private override init() {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()
        let ucc = webView.configuration.userContentController
        ucc.add(self, name: "contentChanged")
        ucc.add(self, name: "ready")
        ucc.add(self, name: "pasteImage")
        ucc.add(self, name: "jsError")
        // 編輯器依賴（tiptap+KaTeX，本地 editor-bundle.js）用 user script 注入：
        // 同 origin 執行、錯誤訊息不會被 file:// 隔離政策遮罩。
        if let url = WebResources.baseURL?.appendingPathComponent("editor-bundle.js"),
           let js = try? String(contentsOf: url, encoding: .utf8) {
            ucc.addUserScript(WKUserScript(
                source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView.navigationDelegate = self
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #endif
        webView.underPageBackgroundColor = .clear
        startLoad()
    }

    /// app 啟動時呼叫即可觸發預載
    func preload() {}

    private func startLoad() {
        loadError = nil
        isReady = false
        webView.loadHTMLString(BlockEditorView.template, baseURL: WebResources.baseURL)
        // CDN 載入失敗（網路慢/斷線）時自動重試，最多 3 次
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, !self.isReady else { return }
            if self.retryCount < 3 {
                self.retryCount += 1
                self.startLoad()
            } else {
                self.loadError = "編輯器載入失敗——請檢查網路後按「重試」"
            }
        }
    }

    func retry() {
        retryCount = 0
        startLoad()
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let name = message.name
        let body = message.body as? String ?? ""
        Task { @MainActor in
            switch name {
            case "ready":
                self.isReady = true
                self.loadError = nil
                self.retryCount = 0
                if let pending = self.pendingText {
                    self.pendingText = nil
                    self.push(pending)
                }
            case "contentChanged":
                self.lastTextFromJS = body
                if self.textBinding?.wrappedValue != body {
                    self.textBinding?.wrappedValue = body
                }
            case "pasteImage":
                self.handlePastedImage(base64: body)
            case "jsError":
                NSLog("BlockEditor JS error: %@", body)
                if !self.isReady {
                    self.loadError = "編輯器發生錯誤：\(body.prefix(120))"
                }
            default:
                break
            }
        }
    }

    /// 換文件時清空狀態，避免跨文件的內容比對誤判（todo 偶爾不顯示的元兇）
    func resetForNewDocument() {
        lastTextFromJS = nil
        lastPushed = nil
        pendingText = nil
    }

    func pushIfNeeded(_ text: String) {
        guard text != lastTextFromJS, text != lastPushed else { return }
        push(text)
    }

    private func push(_ text: String) {
        guard isReady else {
            pendingText = text
            return
        }
        lastPushed = text
        pushAssets(for: text)
        guard let json = encode(text) else { return }
        webView.evaluateJavaScript("window.setMarkdown(\(json)[0])")
    }

    private func encode(_ string: String) -> String? {
        guard let data = try? JSONEncoder().encode([string]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Assets（本地圖片 → data URI 映射表）

    private static let imagePattern = try! NSRegularExpression(
        pattern: #"!\[[^\]]*\]\(([^)\s]+)\)"#)

    private func pushAssets(for text: String) {
        guard let baseDir else { return }
        let ns = text as NSString
        var map: [String: String] = [:]
        Self.imagePattern.enumerateMatches(
            in: text, range: NSRange(location: 0, length: ns.length)
        ) { match, _, _ in
            guard let m = match else { return }
            let path = ns.substring(with: m.range(at: 1))
            guard !path.hasPrefix("http"), !path.hasPrefix("data:") else { return }
            if let uri = dataURI(for: path, baseDir: baseDir) {
                map[path] = uri
            }
        }
        guard !map.isEmpty,
              let data = try? JSONEncoder().encode(map),
              let json = String(data: data, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript("window.mergeAssets(\(json))")
    }

    private func dataURI(for path: String, baseDir: URL) -> String? {
        if let cached = assetCache[path] { return cached }
        let url = baseDir.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mime: String
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": mime = "image/jpeg"
        case "gif": mime = "image/gif"
        default: mime = "image/png"
        }
        let uri = "data:\(mime);base64,\(data.base64EncodedString())"
        assetCache[path] = uri
        return uri
    }

    // MARK: - 貼圖

    private func handlePastedImage(base64: String) {
        guard let baseDir else { return }
        // body 可能是 dataURL（data:image/png;base64,xxx）或純 base64
        let raw = base64.contains(",")
            ? String(base64.split(separator: ",", maxSplits: 1)[1])
            : base64
        guard let data = Data(base64Encoded: raw) else { return }

        let dir = baseDir.appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "img-\(f.string(from: .now)).png"
        let path = "assets/\(name)"
        do {
            try data.write(to: dir.appendingPathComponent(name))
        } catch {
            return
        }

        let uri = "data:image/png;base64,\(raw)"
        assetCache[path] = uri
        guard let pathJSON = encode(path), let uriJSON = encode(uri) else { return }
        webView.evaluateJavaScript(
            "window.insertPastedImage(\(pathJSON)[0], \(uriJSON)[0])")
    }
}

extension BlockEditorView {
    // MARK: - HTML template

    /// 用 computed property：內含 L() 本地化字串，語言切換重載編輯器時要重新求值。
    static var template: String { #"""
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="color-scheme" content="light dark">
    <!-- 手機必要：沒有 viewport 會以 980px 桌面寬渲染；鎖縮放避免 iOS 聚焦輸入時自動放大 -->
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
    <link rel="stylesheet" href="katex.min.css">
    <style>
      html, body { background: transparent; margin: 0; }
      body {
        font: 15px/1.7 -apple-system, "PingFang TC", sans-serif;
        color: CanvasText;
        padding: 16px 22px 40vh;
      }
      .tiptap:focus { outline: none; }
      .tiptap > * + * { margin-top: 0.4em; }
      .tiptap p { margin: 0; }
      h1 { font-size: 1.6em; margin: 0.5em 0 0.2em; }
      h2 { font-size: 1.3em; margin: 0.5em 0 0.2em; }
      h3 { font-size: 1.1em; margin: 0.4em 0 0.2em; }
      p.is-empty:first-child::before {
        content: attr(data-placeholder);
        color: rgba(127,127,127,0.6);
        float: left; height: 0; pointer-events: none;
      }
      ul, ol { padding-left: 1.4em; margin: 0; }
      ul[data-type="taskList"] { list-style: none; padding-left: 0.15em; }
      ul[data-type="taskList"] li { display: flex; gap: 8px; align-items: flex-start; }
      ul[data-type="taskList"] li > label { flex: 0 0 auto; margin-top: 4px; }
      ul[data-type="taskList"] li > div { flex: 1 1 auto; min-width: 0; }
      ul[data-type="taskList"] li[data-checked="true"] > div { opacity: 0.55; text-decoration: line-through; }
      code {
        font-family: ui-monospace, monospace; font-size: 0.9em;
        background: rgba(127,127,127,0.15); padding: 1px 5px; border-radius: 4px;
      }
      pre {
        background: rgba(127,127,127,0.13); padding: 10px 12px;
        border-radius: 8px; overflow-x: auto;
      }
      pre code { background: none; padding: 0; }
      blockquote {
        border-left: 3px solid rgba(127,127,127,0.4);
        margin: 0; padding-left: 12px; opacity: 0.85;
      }
      hr { border: none; border-top: 1px solid rgba(127,127,127,0.3); margin: 12px 0; }
      img { max-width: 100%; border-radius: 6px; }
      .math-inline {
        cursor: pointer; padding: 0 2px; border-radius: 4px;
      }
      .math-inline:hover { background: rgba(127,127,127,0.15); }
      .math-block {
        cursor: pointer; display: block; text-align: center;
        padding: 8px 4px; border-radius: 8px; margin: 4px 0;
      }
      .math-block:hover { background: rgba(127,127,127,0.1); }
      .math-empty { color: rgba(127,127,127,0.6); font-style: italic; }
      #slash-menu, #math-editor {
        position: absolute; z-index: 50; display: none;
        background: Canvas; color: CanvasText;
        border: 1px solid rgba(127,127,127,0.35); border-radius: 10px;
        box-shadow: 0 8px 24px rgba(0,0,0,0.25); padding: 4px;
      }
      #slash-menu { min-width: 190px; max-height: 280px; overflow-y: auto; }
      #math-editor { padding: 10px; width: 340px; }
      #math-editor textarea {
        width: 100%; box-sizing: border-box; min-height: 60px; resize: vertical;
        font-family: ui-monospace, monospace; font-size: 13px;
        background: rgba(127,127,127,0.1); color: CanvasText;
        border: 1px solid rgba(127,127,127,0.3); border-radius: 6px; padding: 6px;
        outline: none;
      }
      #math-preview { padding: 8px 4px; text-align: center; min-height: 24px; overflow-x: auto; }
      #math-editor .row { display: flex; gap: 8px; justify-content: flex-end; margin-top: 6px; }
      #math-editor button {
        font: 13px -apple-system, sans-serif; padding: 3px 12px; border-radius: 6px;
        border: 1px solid rgba(127,127,127,0.35); background: transparent; color: CanvasText;
        cursor: pointer;
      }
      #math-editor button.primary { background: rgba(127,127,127,0.2); }
      .slash-item {
        padding: 6px 10px; border-radius: 6px; font-size: 14px;
        cursor: pointer; display: flex; align-items: center; gap: 8px;
      }
      .slash-item.active { background: rgba(127,127,127,0.18); }
      .slash-hint { margin-left: auto; opacity: 0.45; font-size: 11px; font-family: ui-monospace; }
      .toggle-list { position: relative; padding-left: 22px; }
      .toggle-arrow {
        position: absolute; left: 0; top: 1px;
        width: 18px; height: 22px; border: none; background: none;
        cursor: pointer; color: rgba(127,127,127,0.7); font-size: 12px;
        transition: transform 0.15s; padding: 0;
      }
      .toggle-list.open > .toggle-arrow { transform: rotate(90deg); }
      .toggle-summary-node { font-weight: 500; }
      .toggle-list:not(.open) > .toggle-body > *:not(.toggle-summary-node) { display: none; }
      .drag-handle {
        position: fixed; z-index: 40; width: 20px; height: 22px;
        display: flex; align-items: center; justify-content: center;
        cursor: grab; border-radius: 5px;
        color: rgba(127,127,127,0.7); font-size: 13px; letter-spacing: -2px;
      }
      .drag-handle::after { content: "⋮⋮"; }
      .drag-handle:hover { background: rgba(127,127,127,0.15); }
      .drag-handle:active { cursor: grabbing; }
      .drag-handle.hide { display: none; }
    </style>
    </head>
    <body>
    <div id="editor"></div>
    <div id="slash-menu"></div>
    <script>
      // 載入錯誤回報（module import 失敗也會觸發）
      window.onerror = function (msg, src, line) {
        try { window.webkit.messageHandlers.jsError.postMessage(msg + " @" + line); } catch (e) {}
      };
      window.addEventListener("unhandledrejection", function (e) {
        try { window.webkit.messageHandlers.jsError.postMessage(String(e.reason)); } catch (err) {}
      });
    </script>
    <div id="math-editor">
      <textarea id="math-input" placeholder="\#(L("LaTeX，例如")) \frac{S_{im}S_{jm}}{S_{0m}}"></textarea>
      <div id="math-preview"></div>
      <div class="row">
        <button id="math-delete">\#(L("刪除"))</button>
        <button id="math-done" class="primary">\#(L("完成")) ⏎</button>
      </div>
    </div>
    <script>
      // 依賴由 Swift 端以 WKUserScript 注入本地 editor-bundle.js（IIFE，global RHEditor），離線可用。
      // 整段包進 IIFE：頂層 const Node/Image 會遮蔽 DOM 全域（bundle 內部要用 window.Node
      // 判斷 TEXT_NODE），造成 markdown 解析炸掉、內容顯示不出來。
      (() => {
      const { Editor, Extension, Node, mergeAttributes, InputRule,
              TextSelection, NodeSelection, Fragment,
              StarterKit, TaskList, TaskItem, Image, Placeholder,
              Markdown, katex } = RHEditor;

      // ---- Assets（相對路徑 → data URI）----
      let assetMap = {};
      window.mergeAssets = function (map) {
        Object.assign(assetMap, map);
        if (window.__editor) refreshImages();
      };

      function renderKatex(el, latex, displayMode) {
        if (!latex || !latex.trim()) {
          el.innerHTML = '<span class="math-empty">\#(L("點擊編輯公式"))</span>';
          return;
        }
        try {
          katex.render(latex, el, { displayMode, throwOnError: false });
        } catch (e) {
          el.textContent = latex;
        }
      }

      // ---- 數學節點 ----
      function makeMathNode(name, isBlock) {
        return Node.create({
          name,
          group: isBlock ? "block" : "inline",
          inline: !isBlock,
          atom: true,
          selectable: true,
          addAttributes() {
            return { latex: { default: "" } };
          },
          parseHTML() {
            return [{ tag: `span[data-${name}]` }];
          },
          renderHTML({ node, HTMLAttributes }) {
            return ["span", mergeAttributes(HTMLAttributes, { [`data-${name}`]: "" }),
                    node.attrs.latex];
          },
          addInputRules() {
            const type = this.type;
            const find = isBlock
              ? /\$\$([^$]+)\$\$$/
              : /\$([^$\s][^$]*?)\$$/;
            // 自訂 handler：明確刪除整個 match（含 $ 定界符）再插入節點
            return [new InputRule({
              find,
              handler: ({ range, match, chain }) => {
                chain()
                  .deleteRange(range)
                  .insertContent({ type: type.name, attrs: { latex: match[1].trim() } })
                  .run();
              }
            })];
          },
          addNodeView() {
            return ({ node, getPos, editor }) => {
              const dom = document.createElement("span");
              dom.className = isBlock ? "math-block" : "math-inline";
              renderKatex(dom, node.attrs.latex, isBlock);
              dom.addEventListener("mousedown", e => {
                e.preventDefault();
                openMathEditor(editor, getPos, isBlock);
              });
              return {
                dom,
                update(updated) {
                  if (updated.type.name !== name) return false;
                  renderKatex(dom, updated.attrs.latex, isBlock);
                  return true;
                }
              };
            };
          },
          addStorage() {
            return {
              markdown: {
                serialize(state, node) {
                  if (isBlock) {
                    state.write("$$" + node.attrs.latex + "$$");
                    state.closeBlock(node);
                  } else {
                    state.write("$" + node.attrs.latex + "$");
                  }
                },
                parse: {}
              }
            };
          }
        });
      }
      const MathInline = makeMathNode("mathInline", false);
      const MathBlock = makeMathNode("mathBlock", true);

      // ---- 圖片：src 為相對路徑，顯示時查 assetMap ----
      const LocalImage = Image.extend({
        addNodeView() {
          return ({ node }) => {
            const img = document.createElement("img");
            img.src = assetMap[node.attrs.src] || node.attrs.src;
            return {
              dom: img,
              update(updated) {
                if (updated.type.name !== "image") return false;
                img.src = assetMap[updated.attrs.src] || updated.attrs.src;
                return true;
              }
            };
          };
        }
      });

      function refreshImages() {
        document.querySelectorAll(".tiptap img").forEach(img => {
          const src = img.getAttribute("src");
          if (assetMap[src]) img.src = assetMap[src];
        });
      }

      // ---- Toggle list（摺疊區塊）----
      // 結構：toggleList = toggleSummary（行內標題，正常編輯）+ block+（內容）
      // markdown 表示法：> [!toggle] 標題（內容為 blockquote 後續段落）
      const ToggleSummary = Node.create({
        name: "toggleSummary",
        content: "inline*",
        defining: true,
        selectable: false,
        parseHTML() {
          return [{ tag: "div[data-toggle-summary]" }];
        },
        renderHTML({ HTMLAttributes }) {
          return ["div", mergeAttributes(HTMLAttributes,
            { "data-toggle-summary": "", class: "toggle-summary-node" }), 0];
        },
        addKeyboardShortcuts() {
          return {
            // 標題列按 Enter → 跳到內容第一個 block
            Enter: ({ editor }) => {
              const { $from } = editor.state.selection;
              for (let d = $from.depth; d > 0; d--) {
                if ($from.node(d).type.name === "toggleSummary") {
                  editor.commands.setTextSelection($from.after(d) + 1);
                  return true;
                }
              }
              return false;
            }
          };
        },
        addStorage() {
          return {
            markdown: {
              serialize(state, node) { state.renderInline(node); },
              parse: {}
            }
          };
        }
      });

      const ToggleList = Node.create({
        name: "toggleList",
        group: "block",
        content: "toggleSummary block+",
        defining: true,
        addAttributes() {
          return { open: { default: true } };
        },
        parseHTML() {
          return [{ tag: "div[data-toggle]" }];
        },
        renderHTML({ HTMLAttributes }) {
          return ["div", mergeAttributes(HTMLAttributes, { "data-toggle": "" }), 0];
        },
        addNodeView() {
          return ({ node, getPos, editor }) => {
            const dom = document.createElement("div");
            dom.className = "toggle-list" + (node.attrs.open ? " open" : "");
            const arrow = document.createElement("button");
            arrow.className = "toggle-arrow";
            arrow.textContent = "▸";
            arrow.contentEditable = "false";
            arrow.addEventListener("mousedown", e => {
              e.preventDefault();
              e.stopPropagation();
              const pos = getPos();
              const current = editor.state.doc.nodeAt(pos);
              if (!current) return;
              editor.view.dispatch(editor.state.tr.setNodeMarkup(
                pos, undefined, { open: !current.attrs.open }));
            });
            const body = document.createElement("div");
            body.className = "toggle-body";
            dom.appendChild(arrow);
            dom.appendChild(body);
            return {
              dom,
              contentDOM: body,
              update(updated) {
                if (updated.type.name !== "toggleList") return false;
                dom.className = "toggle-list" + (updated.attrs.open ? " open" : "");
                return true;
              }
            };
          };
        },
        addStorage() {
          return {
            markdown: {
              serialize(state, node) {
                state.wrapBlock("> ", null, node, () => {
                  node.forEach((child, _, i) => {
                    if (i === 0) {
                      state.write("[!toggle] ");
                      state.renderInline(child);
                      state.closeBlock(child);
                    } else {
                      state.render(child, node, i);
                    }
                  });
                });
              },
              parse: {}
            }
          };
        }
      });

      // 載入時把「> [!toggle] …」blockquote 轉回 toggleList 節點（支援巢狀，重複跑到穩定）
      function togglify() {
        for (let pass = 0; pass < 5; pass++) {
          const { state } = editor;
          const replacements = [];
          state.doc.descendants((node, pos) => {
            if (node.type.name !== "blockquote") return true;
            const first = node.firstChild;
            if (!first || first.type.name !== "paragraph") return true;
            const text = first.textContent;
            if (!text.startsWith("[!toggle]")) return true;
            const summaryStr = text.slice(9).trim();
            const summaryNode = state.schema.nodes.toggleSummary.create(
              null, summaryStr ? state.schema.text(summaryStr) : null);
            let rest = node.content.cut(first.nodeSize);
            if (rest.childCount === 0) {
              rest = Fragment.from(state.schema.nodes.paragraph.create());
            }
            replacements.push({
              from: pos, to: pos + node.nodeSize,
              node: state.schema.nodes.toggleList.create(
                { open: true }, Fragment.from([summaryNode]).append(rest))
            });
            return false;
          });
          if (!replacements.length) break;
          let tr = state.tr;
          for (const r of replacements.reverse()) {
            tr = tr.replaceWith(r.from, r.to, r.node);
          }
          editor.view.dispatch(tr);
        }
      }

      // ---- 空清單項目按 Backspace → 一路 lift 到最外層 ----
      const ExitListOnBackspace = Extension.create({
        name: "exitListOnBackspace",
        priority: 1000,
        addKeyboardShortcuts() {
          return {
            Backspace: ({ editor }) => {
              const { state } = editor;
              const { $from, empty } = state.selection;
              if (!empty || $from.parentOffset !== 0) return false;
              if ($from.parent.type.name !== "paragraph") return false;
              if ($from.parent.content.size !== 0) return false;

              const listAncestor = ($f) => {
                for (let d = $f.depth; d > 0; d--) {
                  const name = $f.node(d).type.name;
                  if (name === "taskItem" || name === "listItem") return name;
                }
                return null;
              };

              // 情況 A：空段落在清單「內」→ 一路 lift 到最外層
              if (listAncestor($from)) {
                let guard = 0;
                while (guard++ < 10) {
                  const inside = listAncestor(editor.state.selection.$from);
                  if (!inside) break;
                  if (!editor.commands.liftListItem(inside)) break;
                }
                return true;
              }

              // 情況 B：空段落的前一個 sibling 是清單 → 刪掉空段落、游標回到清單最後
              const paraPos = $from.before();
              const $para = state.doc.resolve(paraPos);
              const prev = $para.nodeBefore;
              if (prev && ["bulletList", "orderedList", "taskList"].includes(prev.type.name)) {
                let tr = state.tr.delete(paraPos, paraPos + $from.parent.nodeSize);
                tr = tr.setSelection(TextSelection.near(tr.doc.resolve(paraPos), -1));
                editor.view.dispatch(tr.scrollIntoView());
                return true;
              }
              return false;
            }
          };
        }
      });

      // ---- Slash 選單項目 ----
      // label 由 Swift 端本地化注入；match 保留中英關鍵字，兩種語言都搜得到。
      const slashItems = [
        { label: "\#(L("文字"))", hint: "", match: "text paragraph 文字",
          run: ed => ed.chain().focus().setParagraph().run() },
        { label: "\#(L("標題 1"))", hint: "#", match: "h1 heading1 標題",
          run: ed => ed.chain().focus().setHeading({ level: 1 }).run() },
        { label: "\#(L("標題 2"))", hint: "##", match: "h2 heading2 標題",
          run: ed => ed.chain().focus().setHeading({ level: 2 }).run() },
        { label: "\#(L("標題 3"))", hint: "###", match: "h3 heading3 標題",
          run: ed => ed.chain().focus().setHeading({ level: 3 }).run() },
        { label: "\#(L("項目清單"))", hint: "-", match: "bullet list ul 項目 清單",
          run: ed => ed.chain().focus().toggleBulletList().run() },
        { label: "\#(L("編號清單"))", hint: "1.", match: "ordered number ol 編號",
          run: ed => ed.chain().focus().toggleOrderedList().run() },
        { label: "\#(L("待辦清單"))", hint: "[ ]", match: "todo task checkbox 待辦",
          run: ed => ed.chain().focus().toggleTaskList().run() },
        { label: "\#(L("行內公式"))", hint: "$", match: "math inline latex eq equation 行內 公式 數學",
          run: ed => {
            ed.chain().focus().insertContent({ type: "mathInline", attrs: { latex: "" } }).run();
          } },
        { label: "\#(L("數學公式（區塊）"))", hint: "$$", match: "math block latex eq equation 數學 公式 區塊",
          run: ed => {
            ed.chain().focus().insertContent({ type: "mathBlock", attrs: { latex: "" } }).run();
          } },
        { label: "\#(L("摺疊清單"))", hint: "▸", match: "toggle details collapse fold 摺疊 折疊 收合",
          run: ed => {
            ed.chain().focus().insertContent({
              type: "toggleList",
              attrs: { open: true },
              content: [{ type: "toggleSummary" }, { type: "paragraph" }]
            }).run();
          } },
        { label: "\#(L("引用"))", hint: ">", match: "quote blockquote 引用",
          run: ed => ed.chain().focus().toggleBlockquote().run() },
        { label: "\#(L("程式碼"))", hint: "```", match: "code 程式 代碼",
          run: ed => ed.chain().focus().toggleCodeBlock().run() },
        { label: "\#(L("分隔線"))", hint: "---", match: "divider hr rule 分隔",
          run: ed => ed.chain().focus().setHorizontalRule().run() }
      ];

      let applying = false;
      let sendTimer = null;

      const editor = new Editor({
        element: document.getElementById("editor"),
        extensions: [
          StarterKit,
          ExitListOnBackspace,
          TaskList,
          TaskItem.configure({ nested: true }),
          LocalImage,
          MathInline,
          MathBlock,
          ToggleSummary,
          ToggleList,
          Placeholder.configure({ placeholder: "\#(L("輸入文字，或打「/」插入區塊"))" }),
          Markdown.configure({ html: false, breaks: false, transformPastedText: true })
        ],
        onUpdate() { scheduleSend(); refreshSlash(); },
        onSelectionUpdate() { refreshSlash(); }
      });
      window.__editor = editor;

      // ---- 自製拖拉把手：hover 在 block 左側出現 ⋮⋮，拖拉重排 ----
      // 用 ProseMirror 原生拖放：dragstart 時選取整個 block 並設定 view.dragging，
      // drop 的落點計算與移動全部交給 PM 處理。
      const dragHandle = document.createElement("div");
      dragHandle.className = "drag-handle hide";
      dragHandle.draggable = true;
      document.body.appendChild(dragHandle);
      let handleBlockPos = null;

      function hideHandle() {
        dragHandle.classList.add("hide");
        handleBlockPos = null;
      }

      document.addEventListener("mousemove", e => {
        if (e.target === dragHandle) return;
        const view = editor.view;
        const editorRect = view.dom.getBoundingClientRect();
        if (e.clientX < editorRect.left - 30 || e.clientX > editorRect.right ||
            e.clientY < editorRect.top || e.clientY > editorRect.bottom) {
          hideHandle();
          return;
        }
        const posInfo = view.posAtCoords({
          left: Math.max(e.clientX, editorRect.left + 1), top: e.clientY });
        if (!posInfo) { hideHandle(); return; }

        let blockPos = null;
        if (posInfo.inside >= 0) {
          const $i = view.state.doc.resolve(posInfo.inside);
          blockPos = $i.depth === 0 ? posInfo.inside : $i.before(1);
        } else {
          const $p = view.state.doc.resolve(posInfo.pos);
          if ($p.depth >= 1) blockPos = $p.before(1);
        }
        if (blockPos == null) { hideHandle(); return; }

        const dom = view.nodeDOM(blockPos);
        if (!dom || !(dom instanceof HTMLElement)) { hideHandle(); return; }
        const rect = dom.getBoundingClientRect();
        handleBlockPos = blockPos;
        dragHandle.style.left = (rect.left - 26) + "px";
        dragHandle.style.top = (rect.top + 1) + "px";
        dragHandle.classList.remove("hide");
      });

      dragHandle.addEventListener("dragstart", e => {
        if (handleBlockPos == null) return;
        const view = editor.view;
        const sel = NodeSelection.create(view.state.doc, handleBlockPos);
        view.dispatch(view.state.tr.setSelection(sel));
        e.dataTransfer.effectAllowed = "move";
        e.dataTransfer.setData("text/plain", "block");
        view.dragging = { slice: sel.content(), move: true };
      });

      document.addEventListener("dragend", () => hideHandle());
      document.addEventListener("scroll", () => hideHandle(), true);

      // ---- 雙擊內容下方的空白處 → 在文末新增空白 block ----
      document.body.addEventListener("dblclick", e => {
        if (editor.view.dom.contains(e.target)) return;
        const doc = editor.state.doc;
        const last = doc.lastChild;
        if (last && last.type.name === "paragraph" && last.content.size === 0) {
          editor.chain().focus("end").run();
        } else {
          editor.chain()
            .insertContentAt(doc.content.size, { type: "paragraph" })
            .focus("end")
            .run();
        }
      });

      function scheduleSend() {
        if (applying) return;
        clearTimeout(sendTimer);
        sendTimer = setTimeout(() => {
          const md = editor.storage.markdown.getMarkdown();
          window.webkit.messageHandlers.contentChanged.postMessage(md);
        }, 250);
      }

      // 載入 markdown 後，把純文字中的 $...$ / $$...$$ 轉成數學節點
      function mathify() {
        const { state } = editor;
        const replacements = [];

        state.doc.descendants((node, pos) => {
          // 整段只有 $$...$$ → mathBlock
          if (node.type.name === "paragraph" && node.childCount === 1 &&
              node.firstChild.isText) {
            const m = node.textContent.match(/^\$\$([\s\S]+)\$\$$/);
            if (m) {
              replacements.push({
                from: pos, to: pos + node.nodeSize,
                node: state.schema.nodes.mathBlock.create({ latex: m[1].trim() })
              });
              return false;
            }
          }
          // 行內 $...$ → mathInline
          if (node.isText && node.text.includes("$")) {
            const re = /\$([^$\n]+?)\$/g;
            let m;
            while ((m = re.exec(node.text)) !== null) {
              replacements.push({
                from: pos + m.index, to: pos + m.index + m[0].length,
                node: state.schema.nodes.mathInline.create({ latex: m[1].trim() })
              });
            }
          }
          return true;
        });

        if (!replacements.length) return;
        let tr = state.tr;
        for (const r of replacements.reverse()) {
          tr = tr.replaceWith(r.from, r.to, r.node);
        }
        editor.view.dispatch(tr);
      }

      window.setMarkdown = function (md) {
        applying = true;
        editor.commands.setContent(md, false);
        togglify();
        mathify();
        refreshImages();
        applying = false;
      };

      window.insertPastedImage = function (path, uri) {
        assetMap[path] = uri;
        editor.chain().focus()
          .insertContent({ type: "image", attrs: { src: path } }).run();
      };

      // ---- 貼上圖片攔截（有文字時讓文字優先）----
      document.addEventListener("paste", e => {
        const cd = e.clipboardData;
        if (!cd) return;
        if (cd.types.includes("text/plain")) return;
        for (const item of cd.items) {
          if (item.type.startsWith("image/")) {
            const file = item.getAsFile();
            if (!file) continue;
            e.preventDefault();
            const reader = new FileReader();
            reader.onload = () =>
              window.webkit.messageHandlers.pasteImage.postMessage(reader.result);
            reader.readAsDataURL(file);
            return;
          }
        }
      }, true);

      // ---- 數學編輯彈窗 ----
      const mathEditor = document.getElementById("math-editor");
      const mathInput = document.getElementById("math-input");
      const mathPreview = document.getElementById("math-preview");
      let mathTarget = null; // { getPos, isBlock }

      function openMathEditor(ed, getPos, isBlock) {
        const pos = getPos();
        const node = ed.state.doc.nodeAt(pos);
        if (!node) return;
        mathTarget = { getPos, isBlock };
        mathInput.value = node.attrs.latex;
        renderKatex(mathPreview, node.attrs.latex, true);
        const c = ed.view.coordsAtPos(pos);
        mathEditor.style.left = Math.min(c.left + window.scrollX, window.innerWidth - 360) + "px";
        mathEditor.style.top = (c.bottom + window.scrollY + 6) + "px";
        mathEditor.style.display = "block";
        mathInput.focus();
      }

      function closeMathEditor() {
        mathEditor.style.display = "none";
        mathTarget = null;
        editor.commands.focus();
      }

      function commitMath() {
        if (!mathTarget) return;
        const pos = mathTarget.getPos();
        const node = editor.state.doc.nodeAt(pos);
        if (!node) return closeMathEditor();
        const latex = mathInput.value.trim();
        let tr = editor.state.tr;
        if (latex) {
          tr = tr.setNodeMarkup(pos, undefined, { latex });
        } else {
          tr = tr.delete(pos, pos + node.nodeSize);
        }
        editor.view.dispatch(tr);
        closeMathEditor();
      }

      function deleteMathNode() {
        if (!mathTarget) return;
        const pos = mathTarget.getPos();
        const node = editor.state.doc.nodeAt(pos);
        if (node) {
          editor.view.dispatch(editor.state.tr.delete(pos, pos + node.nodeSize));
        }
        closeMathEditor();
      }

      mathInput.addEventListener("input", () =>
        renderKatex(mathPreview, mathInput.value, true));
      mathInput.addEventListener("keydown", e => {
        if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); commitMath(); }
        else if (e.key === "Escape") { e.preventDefault(); closeMathEditor(); }
        e.stopPropagation();
      });
      document.getElementById("math-done").onclick = commitMath;
      document.getElementById("math-delete").onclick = deleteMathNode;

      // ---- Slash 選單 + @/! 標記補全 ----
      const menu = document.getElementById("slash-menu");
      let filtered = [];
      let activeIndex = 0;
      let slashRange = null;

      // 待辦標記（@due/@line/!high/!low）：insert 為插入文字，back 為插入後游標回退格數
      const markerItems = [
        { label: "@due(7/15)", hint: "\#(L("到期日"))", insert: "@due()", back: 1, match: "@due deadline 到期" },
        { label: "@line(A)", hint: "\#(L("主線歸屬"))", insert: "@line()", back: 1, match: "@line track 主線" },
        { label: "!high", hint: "\#(L("高優先"))", insert: "!high ", back: 0, match: "!high priority 高" },
        { label: "!low", hint: "\#(L("低優先"))", insert: "!low ", back: 0, match: "!low priority 低" }
      ];

      function refreshSlash() {
        const { state } = editor;
        const { $from, empty } = state.selection;
        if (!empty || !$from.parent.isTextblock) return hideMenu();
        const start = $from.start();
        const textBefore = state.doc.textBetween(start, $from.pos, "\n");

        const m = textBefore.match(/^\/([^\s]*)$/);
        if (m) {
          const query = m[1].toLowerCase();
          filtered = slashItems.filter(i =>
            i.match.includes(query) || i.label.toLowerCase().includes(query));
          if (!filtered.length) return hideMenu();
          slashRange = { from: start, to: $from.pos };
        } else {
          // 行內任意位置的 @/! 開頭字組（前面是行首或空白；「![」不會觸發）
          const mk = textBefore.match(/(?:^|\s)([@!][a-zA-Z]*)$/);
          if (!mk) return hideMenu();
          const q = mk[1].toLowerCase();
          filtered = markerItems.filter(i =>
            i.insert.toLowerCase().startsWith(q) || i.match.includes(q));
          if (!filtered.length) return hideMenu();
          slashRange = { from: $from.pos - mk[1].length, to: $from.pos };
        }

        activeIndex = Math.min(activeIndex, filtered.length - 1);
        renderMenu();
        const c = editor.view.coordsAtPos($from.pos);
        menu.style.left = (c.left + window.scrollX) + "px";
        menu.style.top = (c.bottom + window.scrollY + 4) + "px";
        menu.style.display = "block";
      }

      function renderMenu() {
        menu.innerHTML = "";
        filtered.forEach((item, i) => {
          const div = document.createElement("div");
          div.className = "slash-item" + (i === activeIndex ? " active" : "");
          div.innerHTML = "<span>" + item.label + "</span>" +
            (item.hint ? "<span class='slash-hint'>" + item.hint + "</span>" : "");
          div.onmouseenter = () => { activeIndex = i; renderMenu(); };
          div.onmousedown = e => { e.preventDefault(); applyItem(item); };
          menu.appendChild(div);
        });
      }

      function hideMenu() {
        menu.style.display = "none";
        slashRange = null;
        activeIndex = 0;
      }

      function applyItem(item) {
        if (slashRange) {
          editor.chain().focus().deleteRange(slashRange).run();
        }
        if (item.run) {
          item.run(editor);
        } else {
          // 標記項目：插入文字，必要時把游標退回括號內
          editor.chain().focus().insertContent(item.insert).run();
          if (item.back) {
            editor.commands.setTextSelection(editor.state.selection.from - item.back);
          }
        }
        hideMenu();
      }

      function scrollActiveIntoView() {
        const el = menu.children[activeIndex];
        if (el) el.scrollIntoView({ block: "nearest" });
      }
      document.addEventListener("keydown", e => {
        if (menu.style.display !== "block") return;
        if (e.key === "ArrowDown") {
          e.preventDefault(); e.stopPropagation();
          activeIndex = (activeIndex + 1) % filtered.length;
          renderMenu(); scrollActiveIntoView();
        } else if (e.key === "ArrowUp") {
          e.preventDefault(); e.stopPropagation();
          activeIndex = (activeIndex - 1 + filtered.length) % filtered.length;
          renderMenu(); scrollActiveIntoView();
        } else if (e.key === "Enter") {
          e.preventDefault(); e.stopPropagation();
          applyItem(filtered[activeIndex]);
        } else if (e.key === "Escape") {
          e.preventDefault(); e.stopPropagation();
          hideMenu();
        }
      }, true);

      window.addEventListener("blur", () => { hideMenu(); });

      window.webkit.messageHandlers.ready.postMessage("");
      })();
    </script>
    </body>
    </html>
    """#
    }
}
