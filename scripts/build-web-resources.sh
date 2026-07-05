#!/bin/bash
# 重建 ResearchHub/Resources/EditorWeb/ 的 web 依賴（版本全部釘死，可重現）。
# 需要 node + npm。產物：
#   editor-bundle.js  — tiptap 全家桶 + tiptap-markdown + katex（IIFE，global RHEditor）
#   katex.min.css / katex.min.js（字型路徑改為同層，配合 Xcode 資源攤平）
#   fonts/*.woff2
#   marked.min.js
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/ResearchHub/Resources/EditorWeb"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$WORK"
npm init -y > /dev/null
npm install --silent \
  esbuild \
  @tiptap/core@2.4.0 @tiptap/pm@2.4.0 @tiptap/starter-kit@2.4.0 \
  @tiptap/extension-task-list@2.4.0 @tiptap/extension-task-item@2.4.0 \
  @tiptap/extension-image@2.4.0 @tiptap/extension-placeholder@2.4.0 \
  tiptap-markdown@0.8.10 katex@0.16.9 marked@12.0.2

cat > entry.js <<'EOF'
export { Editor, Extension, Node, mergeAttributes, InputRule } from "@tiptap/core";
export { TextSelection, NodeSelection } from "@tiptap/pm/state";
export { Fragment } from "@tiptap/pm/model";
export { default as StarterKit } from "@tiptap/starter-kit";
export { default as TaskList } from "@tiptap/extension-task-list";
export { default as TaskItem } from "@tiptap/extension-task-item";
export { default as Image } from "@tiptap/extension-image";
export { default as Placeholder } from "@tiptap/extension-placeholder";
export { Markdown } from "tiptap-markdown";
export { default as katex } from "katex";
EOF

npx esbuild entry.js --bundle --format=iife --global-name=RHEditor --minify \
  --outfile=editor-bundle.js

mkdir -p "$OUT/fonts"
cp editor-bundle.js "$OUT/"
cp node_modules/katex/dist/katex.min.js "$OUT/"
cp node_modules/marked/marked.min.js "$OUT/"
cp node_modules/katex/dist/fonts/*.woff2 "$OUT/fonts/"
# Xcode synchronized folder 打包時會把子目錄攤平 → 字型與 CSS 同層
sed 's|url(fonts/|url(|g' node_modules/katex/dist/katex.min.css > "$OUT/katex.min.css"

echo "Done → $OUT"
ls -lh "$OUT"
