#!/bin/zsh
# 更新 macOS 版一條龍：build Release → 裝進 /Applications → 清掉 Spotlight 重複 → 重啟 app
#
# 解決兩個工作流痛點：
#   1. DerivedData 裡的 Debug/Release 版會被 Launch Services 註冊，
#      cmd+space 會冒出多個 ResearchHub，容易開錯 → 裝完後反註冊並刪掉。
#   2. 裝完自動重啟，不用手動再開。
set -euo pipefail
setopt null_glob

cd "$(dirname "$0")/.."

echo "▸ Building Release…"
xcodebuild -project ResearchHub.xcodeproj -scheme ResearchHub \
  -configuration Release build -quiet

BUILT_DIR=$(xcodebuild -project ResearchHub.xcodeproj -scheme ResearchHub \
  -configuration Release -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')
APP="$BUILT_DIR/ResearchHub.app"
[[ -d "$APP" ]] || { echo "✗ 找不到建置產物：$APP" >&2; exit 1 }

echo "▸ Quitting running app…"
osascript -e 'tell application "ResearchHub" to quit' >/dev/null 2>&1 || true
for i in {1..20}; do
  pgrep -xq ResearchHub || break
  sleep 0.5
done
pkill -x ResearchHub 2>/dev/null || true

echo "▸ Installing to /Applications…"
rsync -a --delete "$APP/" /Applications/ResearchHub.app/

# 反註冊並刪掉 DerivedData 裡的副本，Spotlight 只留 /Applications 這份
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
for dup in ~/Library/Developer/Xcode/DerivedData/ResearchHub-*/Build/Products/*/ResearchHub.app; do
  "$LSREG" -u "$dup" >/dev/null 2>&1 || true
  rm -rf "$dup"
done
"$LSREG" -f /Applications/ResearchHub.app >/dev/null 2>&1 || true

echo "▸ Relaunching…"
open -a /Applications/ResearchHub.app
echo "✓ 已安裝並重啟 /Applications/ResearchHub.app"

# LaTeX 專案用的沙盒外小幫手：沙盒 app 只能透過 NSUserUnixTask 執行
# ~/Library/Application Scripts/<bundle id>/ 裡的腳本（app 自己不能寫那裡，所以由這裡安裝）
SCRIPTS_DIR="$HOME/Library/Application Scripts/com.ken.ResearchHub"
mkdir -p "$SCRIPTS_DIR"
install -m 755 scripts/researchhub-helper.sh "$SCRIPTS_DIR/researchhub-helper.sh" \
  && echo "✓ LaTeX 小幫手已安裝"

# 同步 iPhone 重簽用的 repo clone（在 ~/Library，launchd 才讀得到——
# TCC 擋 launchd 碰 ~/Desktop；這裡是終端機環境，有 Desktop 權限可以 pull）
RESIGN_REPO="$HOME/Library/Application Support/ResearchHub/resign/repo"
if [[ -d "$RESIGN_REPO/.git" ]]; then
  git -C "$RESIGN_REPO" pull --ff-only --quiet \
    && echo "✓ 重簽 clone 已同步" \
    || echo "⚠ 重簽 clone 同步失敗（不影響 Mac 版）"
fi
