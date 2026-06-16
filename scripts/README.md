# 離線前端資源（KaTeX / marked）

筆記**預覽**與 **PDF 輸出**是用內嵌 WebView 跑 [KaTeX]（數學排版）和
[marked]（Markdown → HTML）渲染的——**不是**用你電腦裡的 LaTeX（MacTeX/TeX Live）。

目前這些函式庫預設從 `cdnjs.cloudflare.com` 載入，所以**沒網路時預覽/數學會壞**。

## 改成離線

在有網路的 Mac 上執行：

```sh
bash scripts/fetch-web-assets.sh
```

它會把 `katex.min.js`、`katex.min.css`、KaTeX 字型、`marked.min.js` 下載到
`ResearchHub/Sources/WebAssets/`。重新 build 後，`WebAssets.swift` 會自動偵測到
本地檔案並改用它們（偵測不到就退回 CDN，所以**沒跑也不會壞**）。

### 注意：字型子目錄

`katex.min.css` 內以相對路徑 `fonts/*.woff2` 參照字型。載入 HTML 時的 `baseURL`
會指到 bundle 裡的資源目錄，所以 `fonts/` 必須以**子目錄**形式被打包進去。
若 build 後數學字型顯示不正確，請在 Xcode 把 `WebAssets` 以
**folder reference（藍色資料夾）** 加入 target，以保留目錄結構。

## 尚未涵蓋：區塊（TipTap）編輯器

「區塊」模式的編輯器（`BlockEditorView.swift`）另外從 `esm.sh` 載入整套
TipTap 模組（core、starter-kit、各 extension、tiptap-markdown、katex）。
要讓**它**也離線，需要額外的 JS 打包步驟（用 esbuild/rollup 把這些模組打成
單一檔案再放進 bundle、改成 `import` 本地路徑）——屬於較大的後續工作，本腳本未處理。

[KaTeX]: https://katex.org
[marked]: https://marked.js.org
