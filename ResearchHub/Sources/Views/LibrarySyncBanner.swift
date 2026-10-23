import SwiftUI
import HubStore

// MARK: - 同步狀態列

/// 「正在從 iCloud 取得另一台裝置的更新…」提示；沒在下載時不佔空間。
struct LibrarySyncBanner: View {
    private var sync = LibrarySync.shared

    var body: some View {
        if sync.pendingCount > 0 {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在從 iCloud 取得另一台裝置的更新（\(sync.pendingCount) 個檔案）…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        }
    }
}
