#!/bin/bash
# ResearchHub 的沙盒外小幫手。
#
# Mac 版 ResearchHub 是沙盒 app，不能直接執行 /Library/TeX 底下的 LaTeX 編譯器。
# Apple 給沙盒 app 的官方做法是：把腳本放在 ~/Library/Application Scripts/<bundle id>/，
# app 用 NSUserUnixTask 呼叫，腳本在沙盒外執行。install-mac.sh 會把這支裝過去。
#
# ⚠️ 這支腳本是被 com.apple.foundation.UserScriptService 執行的，那個 XPC 服務沒有
# iCloud Drive 的存取權：碰 ~/Library/Mobile Documents 底下的路徑會被 file provider
# 無限期擋住（不回錯、不跳視窗，整支就掛住）。所以這裡只收 app 容器裡的純本機路徑，
# iCloud 那側的檔案搬運由 app 自己做（見 LatexStaging.swift）。
#
# 子指令（輸出最後幾行是 KEY=VALUE，給 app 解析）：
#   compile <工作資料夾> <主檔.tex> <engine: xelatex|pdflatex|lualatex|auto>
#   zip     <來源資料夾> <目的 .zip>            （內容放在 zip 根目錄，跟 Overleaf 下載的格式一樣）
#   unzip   <.zip> <放到哪個資料夾> <新資料夾名稱>
#   ask     <claude|codex> <工作資料夾> <model 或 -> <session id 或 -> <effort 或 -> （論文問答，見 PaperChat.swift）
#   models  列出 ChatGPT（Codex）帳號可用的模型：每行 slug<TAB>名稱<TAB>effort1,effort2…<TAB>預設 effort
#   version
set -u
export PATH="/Library/TeX/texbin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
export LANG="en_US.UTF-8"

# 防呆：萬一哪天又把 iCloud 路徑傳進來，寧可立刻報錯，也不要整支卡死
require_local() {
  case "$1" in
    *"/Mobile Documents/"*|*"/com~apple~CloudDocs"*)
      echo "RC=5"
      echo "ERR=小幫手不能存取 iCloud 路徑（$1），請改傳 app 容器裡的暫存路徑"
      exit 0 ;;
  esac
}

cmd="${1:-}"; shift || true

case "$cmd" in
  version)
    echo "HELPER=2"
    command -v latexmk >/dev/null && echo "LATEXMK=$(command -v latexmk)" || echo "LATEXMK="
    ;;

  compile)
    work="$1"; main="$2"; engine="$3"
    require_local "$work"
    cd "$work" || { echo "RC=2"; echo "ERR=找不到編譯工作資料夾"; exit 0; }
    case "$engine" in
      xelatex)  flag="-xelatex" ;;
      lualatex) flag="-lualatex" ;;
      pdflatex) flag="-pdf" ;;
      *)        flag="" ;;   # auto：交給專案自己的 latexmkrc
    esac
    base="${main%.tex}"
    # 就地編譯：中間檔跟來源放在一起，\include{chapters/x} 的 .aux 自然就有地方寫
    latexmk $flag -interaction=nonstopmode -file-line-error -synctex=1 \
      "$main" > ".rh-latexmk.out" 2>&1 &
    pid=$!
    # 看門狗：卡住（例如套件在等輸入）超過 120 秒就砍掉
    for _ in $(seq 1 240); do
      kill -0 $pid 2>/dev/null || break
      sleep 0.5
    done
    if kill -0 $pid 2>/dev/null; then
      pkill -P $pid 2>/dev/null; kill $pid 2>/dev/null
      echo "TIMEOUT=1"
    fi
    wait $pid 2>/dev/null
    rc=$?
    [ -f "$work/$base.pdf" ] && echo "PDF=$work/$base.pdf"
    echo "LOG=$work/$base.log"
    echo "RC=$rc"
    ;;

  zip)
    proj="$1"; dest="$2"
    require_local "$proj"; require_local "$dest"
    cd "$proj" || { echo "RC=2"; exit 0; }
    rm -f "$dest"
    # 排除 app 自己的狀態與 LaTeX 編譯中間檔（Overleaf 下載的 zip 也不含這些）；.bbl 保留（arXiv 會用）
    /usr/bin/zip -q -r -X "$dest" . -x ".researchhub/*" -x "*.DS_Store" -x "__MACOSX/*" \
      -x "*.aux" -x "*.log" -x "*.fls" -x "*.fdb_latexmk" -x "*.xdv" -x "*.synctex.gz" \
      -x "*.out" -x "*.toc" -x "*.blg" -x "*.bcf" -x "*.run.xml" -x "*.lof" -x "*.lot"
    echo "RC=$?"
    ;;

  unzip)
    zip="$1"; parent="$2"; name="$3"
    require_local "$zip"; require_local "$parent"
    dest="$parent/$name"; n=2
    while [ -e "$dest" ]; do dest="$parent/$name $n"; n=$((n+1)); done
    tmp=$(mktemp -d)
    /usr/bin/ditto -x -k "$zip" "$tmp" || { echo "RC=3"; rm -rf "$tmp"; exit 0; }
    rm -rf "$tmp/__MACOSX"
    # 解開後若只有一個資料夾（常見：專案被包在一層資料夾裡），就用它當專案根目錄
    count=$(find "$tmp" -mindepth 1 -maxdepth 1 -not -name '.DS_Store' | wc -l | tr -d ' ')
    only=$(find "$tmp" -mindepth 1 -maxdepth 1 -not -name '.DS_Store' | head -1)
    if [ "$count" = "1" ] && [ -d "$only" ]; then src="$only"; else src="$tmp"; fi
    mkdir -p "$dest"
    /usr/bin/ditto "$src" "$dest"
    rm -rf "$tmp"
    echo "DEST=$dest"
    echo "RC=0"
    ;;

  ask)
    # 論文問答：用使用者自己的 Claude／ChatGPT 訂閱（Claude Code CLI、Codex CLI）。
    # 工作資料夾在 app 容器裡，app 先寫好 prompt.txt（和 system.txt），
    # 這裡把回覆串流寫進 out.jsonl，app 邊跑邊讀，看起來就是一個字一個字出來。
    provider="$1"; work="$2"; model="${3:--}"; session="${4:--}"; effort="${5:--}"
    require_local "$work"
    cd "$work" || { echo "RC=2"; echo "ERR=找不到問答工作資料夾"; exit 0; }
    # Claude Code 裝在 ~/.local/bin；Codex 是 npm 全域套件（nvm 的 node 底下）
    PATH="$HOME/.local/bin:$PATH"
    for d in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$d" ] && PATH="$d:$PATH"; done
    export PATH
    rm -f out.jsonl err.txt
    case "$provider" in
      claude)
        command -v claude >/dev/null || { echo "RC=127"; echo "ERR=找不到 Claude Code（claude 指令）"; exit 0; }
        # 不給任何工具、不讀使用者的 Claude Code 設定（CLAUDE.md、hooks、MCP），只回答問題
        args=(-p --output-format stream-json --verbose --include-partial-messages
              --tools "" --setting-sources "" --strict-mcp-config
              --system-prompt "$(cat system.txt 2>/dev/null)")
        [ "$model" != "-" ] && args+=(--model "$model")
        [ "$effort" != "-" ] && args+=(--effort "$effort")
        [ "$session" != "-" ] && args+=(--resume "$session")
        claude "${args[@]}" < prompt.txt > out.jsonl 2> err.txt &
        ;;
      codex)
        command -v codex >/dev/null || { echo "RC=127"; echo "ERR=找不到 Codex CLI（codex 指令）"; exit 0; }
        margs=(); [ "$model" != "-" ] && margs=(-m "$model")
        [ "$effort" != "-" ] && margs+=(-c "model_reasoning_effort=\"$effort\"")
        if [ "$session" != "-" ]; then
          codex exec resume "$session" --json --skip-git-repo-check ${margs[@]+"${margs[@]}"} - < prompt.txt > out.jsonl 2> err.txt &
        else
          codex exec --json --skip-git-repo-check -s read-only -C "$work" ${margs[@]+"${margs[@]}"} - < prompt.txt > out.jsonl 2> err.txt &
        fi
        ;;
      *) echo "RC=64"; echo "ERR=未知的 AI：$provider"; exit 0 ;;
    esac
    pid=$!
    # 看門狗：一題最多等 5 分鐘
    for _ in $(seq 1 600); do
      kill -0 $pid 2>/dev/null || break
      sleep 0.5
    done
    if kill -0 $pid 2>/dev/null; then
      pkill -P $pid 2>/dev/null; kill $pid 2>/dev/null
      echo "TIMEOUT=1"
    fi
    wait $pid 2>/dev/null
    echo "RC=$?"
    ;;

  models)
    cache="$HOME/.codex/models_cache.json"
    [ -f "$cache" ] || { echo "RC=2"; exit 0; }
    /usr/bin/python3 - "$cache" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
models = d.get("models", d if isinstance(d, list) else [])
for m in models:
    if not isinstance(m, dict) or m.get("visibility") != "list":
        continue
    levels = m.get("supported_reasoning_levels") or m.get("supported_reasoning_efforts") or []
    levels = [e.get("effort") if isinstance(e, dict) else e for e in levels]
    print("\t".join([m.get("slug", ""), m.get("display_name") or m.get("slug", ""),
                     ",".join(x for x in levels if x), m.get("default_reasoning_level") or ""]))
PY
    echo "RC=0"
    ;;

  *)
    echo "RC=64"; echo "ERR=未知的子指令：$cmd"
    ;;
esac
