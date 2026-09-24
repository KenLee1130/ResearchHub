#!/bin/zsh
# 自動重簽 ResearchHubMobile 並安裝到 iPhone（免費描述檔 7 天到期，
# 過期後 app 打不開＋iOS 撤銷開發者信任）。
#
# 由 com.researchhub.iphone-resign LaunchAgent 每 4 小時觸發一次；
# 手機上那張描述檔剩 >3 天就直接跳過（很便宜），所以到期前有十幾次機會。
#
# 踩過的坑（別再改回去）：
#   • launchd 被 macOS TCC 擋在 ~/Desktop 外 → 一律從 ~/Library 下的 repo clone 建置；
#     clone 由 install-mac.sh（終端機、有 Desktop 權限）同步。
#   • 建置不能用 -destination id=<手機>：手機不在線時連「編譯」都失敗，
#     重試根本跑不到 → 改 generic/platform=iOS，只有安裝那步需要手機。
#   • Xcode 手上描述檔沒過期時會沿用舊的，提前重簽只會裝回同一張快過期的 →
#     到了該續命的時候先刪掉本機快取的描述檔，逼它抓一張新的 7 天效期。
#   • Xcode 的 Apple ID 可能被登出（Xcode 更新／keychain 損壞）→ 偵測到就跳
#     會停留的警告視窗，這一步只有使用者能做。
set -uo pipefail

BASE="$HOME/Library/Application Support/ResearchHub/resign"
REPO="$BASE/repo"
PROJECT="$REPO/ResearchHub.xcodeproj"
DERIVED="$BASE/DerivedData"
BUNDLE_ID=com.ken.ResearchHub.mobile
# iPhone「Ken」的硬體 UDID。別改回 devicectl 的 CoreDevice 識別碼（50D8E41A-…那種）：
# 那是配對時產生的，Xcode 更新／重新登入 Apple ID 後重新配對就會換掉，安裝會一直失敗。
DEVICE_ID=00008140-000E349E3E42801C
APP="$DERIVED/Build/Products/Debug-iphoneos/ResearchHubMobile.app"
LOG="$HOME/Library/Logs/researchhub-iphone-resign.log"
# 內容＝目前裝在手機上那張描述檔的到期時刻（ISO 8601）
STAMP="$HOME/Library/Logs/researchhub-iphone-resign.stamp"
PROFILES_DIRS=(
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  "$HOME/Library/MobileDevice/Provisioning Profiles"
)
RENEW_WITHIN_DAYS=3

log() { echo "$(date '+%F %T') $1" >> "$LOG"; }

notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"ResearchHub iPhone 續命\"" || true
}

# 需要使用者動手的狀況：用會停留的警告視窗（丟背景，不擋住腳本）
alert() {
  /usr/bin/osascript -e "display alert \"ResearchHub iPhone 版快過期了\" message \"$1\" as critical" \
    >/dev/null 2>&1 &
}

# ---- 1. 還不用續命就跳過 ----------------------------------------------------
now=$(date +%s)
if [[ "${1:-}" != "--force" && -s "$STAMP" ]]; then
  exp_iso=$(cat "$STAMP")
  exp=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$exp_iso" "+%s" 2>/dev/null || echo 0)
  left_days=$(( (exp - now) / 86400 ))
  if (( exp > 0 && left_days > RENEW_WITHIN_DAYS )); then
    exit 0   # 每 4 小時一次，不寫 log 免得洗版
  fi
fi

log "===== 開始重簽（手機上描述檔到期：$(cat "$STAMP" 2>/dev/null || echo 未知)）====="

git -C "$REPO" pull --ff-only >> "$LOG" 2>&1 \
  || log "pull 失敗（launchd 讀不到 Desktop origin），用 clone 現有版本"

# ---- 2. 刪掉本機快取的本 app 描述檔，逼 Xcode 抓新的 --------------------------
for dir in "${PROFILES_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  for f in "$dir"/*.mobileprovision(N); do
    if security cms -D -i "$f" 2>/dev/null | plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null \
         | grep -q "\.${BUNDLE_ID}$"; then
      rm -f "$f" && log "刪除舊描述檔 $(basename "$f")"
    fi
  done
done

# ---- 3. 建置（不需要手機在線）------------------------------------------------
BUILD_OUT=$(mktemp)
xcodebuild -project "$PROJECT" -scheme ResearchHubMobile \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED" \
  -configuration Debug -allowProvisioningUpdates build > "$BUILD_OUT" 2>&1
build_rc=$?
cat "$BUILD_OUT" >> "$LOG"

if (( build_rc != 0 )); then
  if grep -qE "No Accounts|Invalid credentials in keychain|missing Xcode-Username" "$BUILD_OUT"; then
    log "失敗：Xcode 沒有登入 Apple ID"
    alert "Xcode 的 Apple ID 登出了，沒辦法幫 iPhone 版續命。請打開 Xcode → Settings → Accounts → 「+」重新登入 Apple ID。登入後不用做別的，下次排程會自動補上。"
  else
    log "失敗：編譯錯誤"
    notify "iPhone 版編譯失敗，看 $LOG"
  fi
  rm -f "$BUILD_OUT"
  exit 1
fi
rm -f "$BUILD_OUT"

new_exp_iso=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null \
  | plutil -extract ExpirationDate raw -o - - 2>/dev/null)
log "建置成功，新描述檔到期 $new_exp_iso"

# ---- 4. 安裝（需要手機在線；裝不上就等下一個 4 小時）--------------------------
for i in 1 2; do
  if xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >> "$LOG" 2>&1; then
    echo "$new_exp_iso" > "$STAMP"
    log "安裝成功，手機上描述檔到期 $new_exp_iso"
    notify "iPhone 版已續命，效期到 ${new_exp_iso%%T*}"
    exit 0
  fi
  log "第 $i 次安裝失敗（手機不在同網路？）"
  (( i < 2 )) && sleep 60
done

# 裝不上：還有時間就安靜等下次；真的快到期了才吵使用者
if [[ -s "$STAMP" ]]; then
  cur=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$(cat "$STAMP")" "+%s" 2>/dev/null || echo 0)
  if (( cur - now < 86400 )); then
    alert "手機上的 ResearchHub 不到一天就過期，但這台 Mac 一直連不到 iPhone。請讓 iPhone 解鎖並連上和 Mac 同一個 Wi-Fi（或插線），4 小時內會自動再試。"
  fi
fi
exit 1
