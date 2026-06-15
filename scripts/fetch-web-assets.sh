#!/usr/bin/env bash
#
# 把預覽/PDF 用的前端資源（KaTeX + marked）下載到 App bundle 資源夾，
# 讓筆記預覽與 PDF 輸出「離線可用」、不再每次連 CDN。
#
# 在「有網路的 Mac」上，於專案根目錄執行：
#     bash scripts/fetch-web-assets.sh
# 之後用 Xcode 重新 build；WebAssets.swift 會自動偵測到本地檔案並改用它們
# （偵測不到時仍會退回 CDN，所以沒跑這支腳本也不會壞）。
#
set -euo pipefail

KATEX_VERSION="0.16.9"
MARKED_VERSION="12.0.2"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/ResearchHub/Sources/WebAssets"
mkdir -p "$DEST"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "→ 下載 KaTeX $KATEX_VERSION（含字型）…"
curl -fsSL \
  "https://github.com/KaTeX/KaTeX/releases/download/v${KATEX_VERSION}/katex.tar.gz" \
  -o "$tmp/katex.tar.gz"
tar -xzf "$tmp/katex.tar.gz" -C "$tmp"
cp "$tmp/katex/katex.min.css" "$DEST/"
cp "$tmp/katex/katex.min.js"  "$DEST/"
rm -rf "$DEST/fonts"
cp -R "$tmp/katex/fonts" "$DEST/fonts"

echo "→ 下載 marked $MARKED_VERSION…"
curl -fsSL \
  "https://cdn.jsdelivr.net/npm/marked@${MARKED_VERSION}/marked.min.js" \
  -o "$DEST/marked.min.js"

echo ""
echo "✓ 完成。已放到：$DEST"
ls -1 "$DEST"
echo ""
echo "下一步："
echo "  1. 用 Xcode 開啟專案，確認 WebAssets/ 的檔案（含 fonts/）都在 App target 的"
echo "     Copy Bundle Resources 裡（同步資料夾通常會自動納入）。"
echo "  2. Build & Run，斷網測試預覽數學是否正常顯示。"
echo "  3. 若數學字型顯示不正確（fonts/ 沒被打包成子目錄），把 WebAssets 改以"
echo "     『folder reference（藍色資料夾）』加入，以保留 fonts/ 目錄結構。"
