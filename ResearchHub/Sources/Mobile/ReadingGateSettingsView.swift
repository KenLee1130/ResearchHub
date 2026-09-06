#if os(iOS)
import SwiftUI
import UIKit

/// 閱讀關卡設定：專注模式開關、黑名單（偵測已安裝的 app）、捷徑自動化設定指引。
struct ReadingGateSettingsView: View {
    @ObservedObject private var gate = ReadingGateStore.shared
    @State private var manual = ReadingGateStore.shared.localManual
    @State private var grace = ReadingGateStore.shared.graceMinutes
    @State private var blacklist = ReadingGateStore.shared.blacklist
    @State private var showAddCustom = false
    @State private var newName = ""
    @State private var newScheme = ""
    @State private var showGuide = false
    @State private var preview = false

    /// 目錄裡「這支手機真的有裝」的 app（canOpenURL 偵測；
    /// 需要 Info.plist 的 LSApplicationQueriesSchemes 有列該 scheme）。
    private var installed: [GateApp] {
        gate.allKnownApps.filter { app in
            guard let url = app.openURL else { return false }
            return UIApplication.shared.canOpenURL(url)
        }
    }

    /// 沒偵測到、但已經被勾選的（例如換過 scheme）——照樣顯示，才刪得掉。
    private var extras: [GateApp] {
        gate.allKnownApps.filter {
            blacklist.contains($0.scheme) && !installed.contains($0)
        }
    }

    var body: some View {
        List {
            Section {
                Toggle("專注模式（手動）", isOn: $manual)
                    .onChange(of: manual) { _, v in gate.localManual = v }
                LabeledContent("蕃茄鐘連動") {
                    Text(gate.focusState().gateActive ? "工作階段進行中" : "未在工作階段")
                        .foregroundStyle(.secondary)
                }
                Stepper("寬限期 \(grace) 分鐘", value: $grace, in: 1...60)
                    .onChange(of: grace) { _, v in gate.graceMinutes = v }
                if let until = gate.graceUntil {
                    HStack {
                        Text("寬限中，到 \(until, format: .dateTime.hour().minute())")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("立刻恢復攔截") { gate.clearGrace() }
                            .font(.caption)
                    }
                }
            } header: {
                Text("啟用條件")
            } footer: {
                Text("蕃茄鐘工作階段會自動啟用；也可以自己打開專注模式。通過一次後有寬限期，這段時間內不會重複攔截。")
            }

            Section {
                if installed.isEmpty {
                    Text("沒有偵測到目錄裡的 app")
                        .foregroundStyle(.secondary)
                }
                ForEach(installed) { app in
                    appRow(app)
                }
                ForEach(extras) { app in
                    appRow(app, missing: true)
                }
                Button {
                    showAddCustom = true
                } label: {
                    Label("手動新增 app", systemImage: "plus")
                }
            } header: {
                Text("黑名單")
            } footer: {
                Text("iOS 不允許 app 列出你安裝了什麼，所以這裡是「內建目錄比對」的結果——只顯示偵測到你有裝的。清單裡沒有的 app 可以自己加（要知道它的 URL scheme）。")
            }

            Section {
                Button {
                    showGuide = true
                } label: {
                    Label("怎麼設定捷徑自動化", systemImage: "wand.and.stars")
                }
                Button {
                    preview = true
                } label: {
                    Label("試跑一次關卡", systemImage: "play.circle")
                }
                LabeledContent("題庫") {
                    Text("\(gate.bank.papers.count) 篇")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("累計通過") {
                    Text("\(gate.totalPasses) 次")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("設定與題庫")
            } footer: {
                Text("關卡本身要靠「捷徑」的個人自動化觸發：打開黑名單 app 時執行「打開 URL researchhub://gate?app=<scheme>」。每個 app 各設一條，設定一次就好。")
            }
        }
        .navigationTitle("閱讀關卡")
        .onAppear { gate.reload() }
        .sheet(isPresented: $showAddCustom) { addCustomSheet }
        .sheet(isPresented: $showGuide) { ShortcutsGuideView(apps: blacklistedApps) }
        .fullScreenCover(isPresented: $preview) {
            ReadingGateView(target: nil) { preview = false }
        }
    }

    private var blacklistedApps: [GateApp] {
        gate.allKnownApps.filter { blacklist.contains($0.scheme) }
    }

    private func appRow(_ app: GateApp, missing: Bool = false) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                HStack(spacing: 6) {
                    Text("\(app.scheme)://").font(.caption2).foregroundStyle(.tertiary)
                    if missing {
                        Text("未偵測到").font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { blacklist.contains(app.scheme) },
                set: { on in
                    gate.setBlacklisted(app.scheme, on)
                    blacklist = gate.blacklist
                }))
            .labelsHidden()
        }
        .swipeActions {
            if app.custom {
                Button("刪除", role: .destructive) {
                    gate.removeCustomApp(app)
                    blacklist = gate.blacklist
                }
            }
        }
    }

    private var addCustomSheet: some View {
        NavigationStack {
            Form {
                TextField("顯示名稱（例如 Netflix）", text: $newName)
                TextField("URL scheme（例如 nflx）", text: $newScheme)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Section {
                    Text("不確定 scheme？在捷徑裡建一個「打開 App」動作選那個 app，多數 app 的 scheme 就是它的名字小寫。加完可以用上面的「試跑」確認跳得回去。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("新增 app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAddCustom = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加入") {
                        gate.addCustomApp(name: newName, scheme: newScheme)
                        blacklist = gate.blacklist
                        newName = ""; newScheme = ""
                        showAddCustom = false
                    }
                    .disabled(newScheme.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// 捷徑自動化設定教學：逐個 app 給可複製的 URL。
struct ShortcutsGuideView: View {
    let apps: [GateApp]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("一次性設定（每個 app 各做一遍）") {
                    stepRow(1, "打開「捷徑」app → 底部「自動化」")
                    stepRow(2, "「+」→ 新增個人自動化 → 選「App」")
                    stepRow(3, "App 選這一個、勾「已打開」")
                    stepRow(4, "選「立即執行」，關掉「執行前先詢問」")
                    stepRow(5, "加入動作「打開 URL」，貼上下面對應的網址")
                }
                Section {
                    if apps.isEmpty {
                        Text("還沒有勾選任何 app").foregroundStyle(.secondary)
                    }
                    ForEach(apps) { app in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).font(.subheadline.weight(.medium))
                            HStack {
                                Text("researchhub://gate?app=\(app.scheme)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    UIPasteboard.general.string =
                                        "researchhub://gate?app=\(app.scheme)"
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("每個 app 要貼的網址")
                } footer: {
                    Text("這是軟性防線：自動化你自己隨時可以關掉或刪除，它擋的是手滑，不是決心。")
                }
            }
            .navigationTitle("設定自動化")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func stepRow(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text).font(.callout)
        }
    }
}
#endif
