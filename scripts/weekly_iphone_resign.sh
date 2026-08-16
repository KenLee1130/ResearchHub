#!/bin/zsh
# 自動重簽 ResearchHubMobile 並安裝到 iPhone（免費描述檔 7 天到期，
# 過期後 app 打不開＋iOS 撤銷開發者信任）。由 com.researchhub.iphone-resign
# LaunchAgent 每天 20:00 觸發：距上次成功 <5 天就直接跳過，
# 所以單次失敗（Mac 睡著、手機不在線上）隔天會自動補救，不用等一週。
set -euo pipefail

PROJECT=/Users/kenlee/Desktop/projects/ResearchHub/ResearchHub.xcodeproj
DEVICE_ID=50D8E41A-F2CA-5644-A308-DAB5BAAC61F9   # iPhone「Ken」
APP=/Users/kenlee/Library/Developer/Xcode/DerivedData/ResearchHub-hiitradpiuupcaafzttbnxivtqhv/Build/Products/Debug-iphoneos/ResearchHubMobile.app
LOG=/Users/kenlee/Library/Logs/researchhub-iphone-resign.log   # /tmp 會被系統清掉
STAMP=/Users/kenlee/Library/Logs/researchhub-iphone-resign.stamp

notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"ResearchHub 週更\"" || true
}

# 距上次成功不到 5 天就不用重簽（帶 --force 可跳過檢查）
if [[ "${1:-}" != "--force" && -f "$STAMP" ]]; then
  if [[ -n "$(find "$STAMP" -mtime -5 2>/dev/null)" ]]; then
    echo "$(date '+%F %T') 距上次成功 <5 天，跳過" >> "$LOG"
    exit 0
  fi
fi

echo "===== $(date '+%F %T') 開始重簽 =====" >> "$LOG"

if ! xcodebuild -project "$PROJECT" -scheme ResearchHubMobile \
    -destination "platform=iOS,id=$DEVICE_ID" \
    -configuration Debug -allowProvisioningUpdates build >> "$LOG" 2>&1; then
  notify "編譯失敗，看 $LOG"
  exit 1
fi

# 手機可能不在線上，隔 5 分鐘重試，共 6 次（30 分鐘）；都失敗明天排程再試
for i in 1 2 3 4 5 6; do
  if xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >> "$LOG" 2>&1; then
    EXP=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null \
          | plutil -extract ExpirationDate raw -o - - 2>/dev/null || echo '?')
    echo "安裝成功，到期 $EXP" >> "$LOG"
    touch "$STAMP"
    notify "iPhone 版已更新，效期到 ${EXP%%T*}"
    exit 0
  fi
  echo "第 $i 次安裝失敗（手機可能不在同網路），5 分鐘後重試" >> "$LOG"
  sleep 300
done

notify "安裝失敗：iPhone 連不上。明天 20:00 會自動再試"
exit 1
