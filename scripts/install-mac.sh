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
