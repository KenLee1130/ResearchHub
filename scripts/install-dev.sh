#!/bin/zsh
# 安裝「dev 版」ResearchHub，與正式版並存：build Dev configuration → /Applications/ResearchHub Dev.app
#
# 與 install-mac.sh 的差別：
#   - 絕不碰 /Applications/ResearchHub.app，也不 quit 正式版（只 quit「ResearchHub Dev」）。
#   - bundle id 是 com.ken.ResearchHub.dev、URL scheme 是 researchhub-dev://，
#     UserDefaults／沙盒容器／Application Scripts 都各自一份，不會和正式版互相干擾。
#   - 資料隔離：第一次執行會把 iCloud 資料夾複製一份到 ~/ResearchHubLibrary-dev/
#     （只複製，不動原資料；之後執行不再覆蓋），dev 版第一次啟動時請選這個資料夾。
#
# 重構期間一律跑這支；全部完成後再跑一次 install-mac.sh 替換正式版（見 docs/ARCHITECTURE.md 第 6 節）。
set -euo pipefail
setopt null_glob

cd "$(dirname "$0")/.."

DEV_APP="/Applications/ResearchHub Dev.app"
DEV_BUNDLE_ID="com.ken.ResearchHub.dev"
DEV_LIBRARY="$HOME/ResearchHubLibrary-dev"
ICLOUD_LIBRARY="$HOME/Library/Mobile Documents/com~apple~CloudDocs/ResearchHubLibrary"

echo "▸ Building Dev…"
xcodebuild -project ResearchHub.xcodeproj -scheme ResearchHub \
  -configuration Dev build -quiet

BUILT_DIR=$(xcodebuild -project ResearchHub.xcodeproj -scheme ResearchHub \
  -configuration Dev -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')
APP="$BUILT_DIR/ResearchHub Dev.app"
[[ -d "$APP" ]] || { echo "✗ 找不到建置產物：$APP" >&2; exit 1 }

# 防呆：產物的 bundle id 必須是 dev 版，絕不把正式版的東西裝到 dev 路徑（反之亦然）
BUILT_ID=$(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
[[ "$BUILT_ID" == "$DEV_BUNDLE_ID" ]] || {
  echo "✗ 建置產物的 bundle id 是「$BUILT_ID」，不是 $DEV_BUNDLE_ID，中止" >&2; exit 1 }

echo "▸ Quitting running dev app（正式版不動）…"
osascript -e 'tell application id "com.ken.ResearchHub.dev" to quit' >/dev/null 2>&1 || true
for i in {1..20}; do
  pgrep -xq "ResearchHub Dev" || break
  sleep 0.5
done
pkill -x "ResearchHub Dev" 2>/dev/null || true

echo "▸ Installing to $DEV_APP…"
rsync -a --delete "$APP/" "$DEV_APP/"

# 反註冊並刪掉 DerivedData 裡的 Dev 副本（只動 Dev 產物；正式版的 Release/Debug 由 install-mac.sh 管）
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
for dup in ~/Library/Developer/Xcode/DerivedData/ResearchHub-*/Build/Products/Dev/"ResearchHub Dev.app"; do
  "$LSREG" -u "$dup" >/dev/null 2>&1 || true
  rm -rf "$dup"
done
"$LSREG" -f "$DEV_APP" >/dev/null 2>&1 || true

# dev 版的沙盒外小幫手：NSUserUnixTask 只看 ~/Library/Application Scripts/<dev bundle id>/
SCRIPTS_DIR="$HOME/Library/Application Scripts/$DEV_BUNDLE_ID"
mkdir -p "$SCRIPTS_DIR"
install -m 755 scripts/researchhub-helper.sh "$SCRIPTS_DIR/researchhub-helper.sh" \
  && install -m 644 scripts/babeldoc-align.py "$SCRIPTS_DIR/babeldoc-align.py" \
  && echo "✓ dev 版小幫手已安裝（$SCRIPTS_DIR）"

# 資料隔離：第一次才複製，之後不覆蓋
FIRST_RUN=0
if [[ ! -d "$DEV_LIBRARY" ]]; then
  if [[ -d "$ICLOUD_LIBRARY" ]]; then
    echo "▸ 第一次執行：把 iCloud 資料夾複製到 $DEV_LIBRARY（只複製，不動原資料）…"
    rsync -a "$ICLOUD_LIBRARY/" "$DEV_LIBRARY/"
    FIRST_RUN=1
  else
    echo "⚠ 找不到 iCloud 資料夾 $ICLOUD_LIBRARY，略過複製；dev 版啟動後請自行選資料夾"
  fi
fi

echo "▸ Relaunching dev app…"
open -a "$DEV_APP"
echo "✓ 已安裝並啟動 $DEV_APP（bundle id $DEV_BUNDLE_ID，scheme researchhub-dev://）"
if (( FIRST_RUN )); then
  echo
  echo "★ dev 版第一次啟動沒有資料夾記憶，請在 app 裡選擇：$DEV_LIBRARY"
  echo "  （正式版仍用 iCloud 資料夾，兩邊資料互不影響）"
fi
