#!/bin/zsh
# 每週自動重簽 ResearchHubMobile 並安裝到 iPhone（趕在 7 天免費描述檔到期前，
# 避免 app 過期打不開＋iOS 撤銷開發者信任）。由 com.researchhub.iphone-resign LaunchAgent 觸發。
set -euo pipefail

PROJECT=/Users/kenlee/Desktop/projects/ResearchHub/ResearchHub.xcodeproj
DEVICE_ID=50D8E41A-F2CA-5644-A308-DAB5BAAC61F9   # iPhone「Ken」
APP=/Users/kenlee/Library/Developer/Xcode/DerivedData/ResearchHub-hiitradpiuupcaafzttbnxivtqhv/Build/Products/Debug-iphoneos/ResearchHubMobile.app
LOG=/tmp/researchhub-iphone-resign.log

notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"ResearchHub 週更\"" || true
}

echo "===== $(date '+%F %T') 開始重簽 =====" >> "$LOG"

if ! xcodebuild -project "$PROJECT" -scheme ResearchHubMobile \
    -destination "platform=iOS,id=$DEVICE_ID" \
    -configuration Debug -allowProvisioningUpdates build >> "$LOG" 2>&1; then
  notify "編譯失敗，看 $LOG"
  exit 1
fi

# 手機可能不在線上，隔 5 分鐘重試，共 6 次（30 分鐘）
for i in 1 2 3 4 5 6; do
  if xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >> "$LOG" 2>&1; then
    EXP=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null \
          | plutil -extract ExpirationDate raw -o - - 2>/dev/null || echo '?')
    echo "安裝成功，到期 $EXP" >> "$LOG"
    notify "iPhone 版已更新，效期到 ${EXP%%T*}"
    exit 0
  fi
  echo "第 $i 次安裝失敗（手機可能不在同網路），5 分鐘後重試" >> "$LOG"
  sleep 300
done

notify "安裝失敗：iPhone 連不上。手機連上 Wi-Fi 後手動跑一次腳本"
exit 1
