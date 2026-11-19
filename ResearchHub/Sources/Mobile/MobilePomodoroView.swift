#if os(iOS)
import SwiftUI
import HubStore
import HubCore

/// 蕃茄鐘分頁。
///
/// 兩個版面，按下開始時用 matchedGeometryEffect 平滑切換：
///   • 待命：跟以前一樣，大數字置中，下面是模式、計畫、開始鈕
///   • 計時中：數字飛到最上面，中間播動畫（隨機挑一個場景，點一下換下一個），
///     暫停／重來／結束移到最下面
///
/// 兩種模式：
///   • 蕃茄鐘：照設定的分鐘倒數，到點彈完成小卡（跟以前一樣）
///   • 無限模式：正向計時直到按「結束」。畫面離開這一頁（切分頁、回桌面、鎖屏）或按暫停
///     的時間記成「非工作時間」，結束時告訴你總時間／工作／非工作
struct MobilePomodoroView: View {
    @Environment(PomodoroModel.self) private var pomodoro
    /// random / off / 某個場景的 rawValue
    @AppStorage("pomodoro.scene") private var sceneChoice = "random"
    @State private var scene: PomodoroScene = .study
    @State private var confirmDiscard = false
    /// 這一段已經挑過場景了（切分頁回來不要重抽）
    @State private var scenePicked = false
    @Namespace private var ns

    private var flow: FlowTimer? { pomodoro.flow }
    private var isFlowMode: Bool { flow != nil || (!pomodoro.isActive && pomodoro.mode == .flow) }
    /// 正在走（倒數中，或無限模式沒暫停）
    private var ticking: Bool { pomodoro.isRunning || (flow.map { !$0.paused } ?? false) }

    var body: some View {
        NavigationStack {
            ZStack {
                if pomodoro.isActive {
                    activeLayout
                } else {
                    idleLayout
                }
            }
            .animation(.spring(response: 0.6, dampingFraction: 0.86), value: pomodoro.isActive)
            .navigationTitle(pomodoro.isActive ? "" : "蕃茄鐘")
            .navigationBarTitleDisplayMode(pomodoro.isActive ? .inline : .large)
            .toolbar {
                if pomodoro.isActive {
                    ToolbarItem(placement: .topBarTrailing) { sceneMenu }
                }
            }
            .sheet(item: completionBinding) { prompt in
                MobileCompletionSheet(prompt: prompt)
            }
            .sheet(item: flowSummaryBinding) { summary in
                MobileFlowSummarySheet(summary: summary)
            }
            .confirmationDialog("放棄這一段？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("放棄，不記錄", role: .destructive) { pomodoro.reset() }
            } message: {
                Text("已經記的時間會全部丟掉。要留下紀錄請按「結束」。")
            }
            .onChange(of: pomodoro.isActive) { _, active in
                if active { pickScene() }
            }
            .onAppear {
                // 開 app 時就在計時中（重啟續跑）：補挑一次
                if pomodoro.isActive && !scenePicked { pickScene() }
            }
        }
    }

    // MARK: - 待命

    private var idleLayout: some View {
        VStack(spacing: 24) {
            Spacer()

            timerText(size: 76)
            Text(isFlowMode ? LocalizedStringKey("正向計時") : LocalizedStringKey(pomodoro.phase.label))
                .font(.headline)
                .foregroundStyle(.secondary)

            if pomodoro.phase == .work {
                Picker("模式", selection: Bindable(pomodoro).mode) {
                    ForEach(PomodoroModel.Mode.allCases) { m in
                        Text(LocalizedStringKey(m.label)).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 60)
            }

            TextField(isFlowMode ? "這段要做什麼…" : "這顆要做什麼…", text: Bindable(pomodoro).currentPlan)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 40)

            controls(compact: false)

            Text("今天 \(pomodoro.todayCount) 顆 · 本輪第 \(min(pomodoro.cyclePosition + 1, pomodoro.cycleLength)) / \(pomodoro.cycleLength) 顆")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Group {
                if isFlowMode {
                    Text("一直計時到你按「結束」。離開這一頁（切分頁、回桌面、鎖屏）或按暫停的時間記成非工作時間，結束時會告訴你總時間、工作與非工作各多久。")
                } else {
                    Text("倒數以結束時刻計算——鎖屏、切出去都不會停，時間到會推播通知。停在這一頁倒數時螢幕會保持常亮。")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - 計時中

    private var activeLayout: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                timerText(size: 64)
                subtitle
            }
            .padding(.top, 4)

            sceneArea
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
                .transition(.asymmetric(insertion: .scale(scale: 0.88).combined(with: .opacity),
                                        removal: .opacity))

            controls(compact: true)
                .padding(.bottom, 28)
        }
    }

    @ViewBuilder private var subtitle: some View {
        if let flow {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(spacing: 10) {
                    Label(Self.clock(flow.workSeconds(at: ctx.date)), systemImage: "brain.head.profile")
                        .foregroundStyle(Color.red)
                    Label(Self.clock(flow.awaySeconds(at: ctx.date)), systemImage: "cup.and.saucer")
                        .foregroundStyle(.secondary)
                    if flow.paused {
                        Text("暫停中")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.18)))
                            .foregroundStyle(.orange)
                    }
                }
                .font(.subheadline.monospacedDigit())
            }
            if !flow.plan.isEmpty {
                Text(flow.plan).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            HStack(spacing: 6) {
                Text(LocalizedStringKey(pomodoro.phase.label))
                if !pomodoro.isRunning {
                    Text("· 暫停中").foregroundStyle(.orange)
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            if pomodoro.phase == .work, !pomodoro.currentPlan.isEmpty {
                Text(pomodoro.currentPlan).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var sceneArea: some View {
        if sceneChoice == "off" {
            Color.clear.frame(maxHeight: .infinity)
        } else {
            PomodoroSceneView(scene: scene, paused: !ticking)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Label(scene.title, systemImage: scene.symbol)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(12)
                }
                .overlay {
                    if !ticking {
                        RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.black.opacity(0.25))
                        Image(systemName: "pause.fill").font(.system(size: 34)).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                .contentShape(RoundedRectangle(cornerRadius: 28))
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.35)) { scene = scene.next }
                }
                .id(scene)
                .transition(.opacity)
        }
    }

    private var sceneMenu: some View {
        Menu {
            Picker("動畫", selection: $sceneChoice) {
                Label("隨機", systemImage: "shuffle").tag("random")
                ForEach(PomodoroScene.allCases) { s in
                    Label(s.title, systemImage: s.symbol).tag(s.rawValue)
                }
                Label("不要動畫", systemImage: "eye.slash").tag("off")
            }
        } label: {
            Image(systemName: "sparkles.tv")
        }
        .onChange(of: sceneChoice) { pickScene() }
    }

    // MARK: - 共用元件

    /// 大數字：蕃茄鐘是倒數，無限模式是總經過時間
    @ViewBuilder private func timerText(size: CGFloat) -> some View {
        Group {
            if let flow {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Self.clock(flow.totalSeconds(at: ctx.date)))
                }
            } else if isFlowMode {
                Text(verbatim: "00:00")
            } else {
                PomodoroCountdownText(clock: pomodoro.clock)
            }
        }
        .font(.system(size: size, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .contentTransition(.numericText())
        .matchedGeometryEffect(id: "timer", in: ns)
    }

    /// 底部的操作列。待命時只有「重設＋開始」；計時中三顆：重來／放棄、暫停、結束（或換場景）
    private func controls(compact: Bool) -> some View {
        HStack(spacing: 28) {
            if compact {
                circleButton(flow != nil ? "xmark" : "arrow.counterclockwise",
                             label: flow != nil ? "放棄" : "重來") {
                    if flow != nil { confirmDiscard = true } else { pomodoro.reset() }
                }
            } else if !isFlowMode {
                circleButton("arrow.counterclockwise", label: "重設") { pomodoro.reset() }
            }

            Button {
                pomodoro.toggle()
            } label: {
                Image(systemName: ticking ? "pause.fill" : "play.fill")
                    .font(.title)
                    .frame(width: compact ? 72 : 56, height: compact ? 72 : 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(flow != nil ? .red : .accentColor)
            .clipShape(Circle())
            .accessibilityLabel(ticking ? Text("暫停") : Text("開始"))

            if compact {
                if flow != nil {
                    circleButton("stop.fill", label: "結束", tint: .red) { pomodoro.stopFlow() }
                } else {
                    circleButton("shuffle", label: "換動畫") {
                        withAnimation(.easeInOut(duration: 0.35)) { scene = scene.next }
                    }
                    .disabled(sceneChoice == "off")
                }
            }
        }
        .matchedGeometryEffect(id: "controls", in: ns)
    }

    private func circleButton(_ symbol: String, label: LocalizedStringKey, tint: Color? = nil,
                              action: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .tint(tint)
            .clipShape(Circle())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func pickScene() {
        scenePicked = true
        if let fixed = PomodoroScene(rawValue: sceneChoice) {
            scene = fixed
        } else if sceneChoice != "off" {
            // "random"，或舊版存的場景名（已經沒有了）都當隨機
            scene = .random(excluding: scene)
        }
    }

    /// 秒數 → 「12:34」或「1:02:03」
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private var completionBinding: Binding<PomodoroModel.CompletionPrompt?> {
        Binding(get: { pomodoro.completionPrompt }, set: { pomodoro.completionPrompt = $0 })
    }

    private var flowSummaryBinding: Binding<FlowSummary?> {
        Binding(get: { pomodoro.flowSummary }, set: { pomodoro.flowSummary = $0 })
    }
}

// MARK: - 無限模式的總結

struct MobileFlowSummarySheet: View {
    let summary: FlowSummary
    @Environment(PomodoroModel.self) private var pomodoro
    @Environment(\.dismiss) private var dismiss
    @State private var doneNote = ""

    private var workRatio: Double {
        summary.totalSeconds > 0 ? summary.workSeconds / summary.totalSeconds : 0
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 14) {
                        Text(Self.duration(summary.totalSeconds))
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(verbatim: Self.range(summary.startedAt, summary.endedAt))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        // 工作／非工作的比例條
                        GeometryReader { geo in
                            HStack(spacing: 2) {
                                Capsule().fill(Color.red).frame(width: max(geo.size.width * workRatio - 1, 0))
                                Capsule().fill(Color.secondary.opacity(0.35))
                            }
                        }
                        .frame(height: 10)
                        HStack {
                            stat("總時間", summary.totalSeconds, .primary)
                            Divider().frame(height: 36)
                            stat("工作", summary.workSeconds, .red)
                            Divider().frame(height: 36)
                            stat("非工作", summary.awaySeconds, .secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                if summary.sessionID != nil {
                    Section("這段完成了什麼？") {
                        TextField("寫一句就好", text: $doneNote, axis: .vertical)
                    }
                } else {
                    Section {
                        Text("工作不到一分鐘，這段不記進紀錄。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                SpotifyTracksSection(start: summary.startedAt, end: summary.endedAt,
                                     sessionID: summary.sessionID, showConnectHint: true)
            }
            .navigationTitle(summary.plan.isEmpty ? Text("這段專注") : Text(summary.plan))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if summary.sessionID != nil { pomodoro.recordDone(doneNote) }
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func stat(_ title: LocalizedStringKey, _ seconds: TimeInterval, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Self.duration(seconds))
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }

    /// 「1 小時 23 分」「12 分 30 秒」
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = s / 60 % 60, sec = s % 60
        if h > 0 { return L("\(h) 小時 \(m) 分") }
        if m > 0 { return L("\(m) 分 \(sec) 秒") }
        return L("\(sec) 秒")
    }

    static func range(_ a: Date, _ b: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(f.string(from: a)) – \(f.string(from: b))"
    }
}

// MARK: - 這段時間聽了哪些歌（Spotify）

struct SpotifyTracksSection: View {
    let start: Date
    let end: Date
    let sessionID: UUID?
    /// 沒連結時顯示「去連結」那一列（無限模式總結用；一般完成小卡沒連就整段不出現）
    var showConnectHint = false

    @State private var spotify = SpotifyService.shared
    @State private var tracks: [SpotifyTrack]?
    @State private var error: String?
    @Environment(PomodoroModel.self) private var pomodoro

    var body: some View {
        if spotify.isConnected {
            Section {
                if let tracks {
                    if tracks.isEmpty {
                        Text("這段時間沒有聽歌（或 Spotify 還沒更新紀錄）")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(tracks) { track in row(track) }
                } else if let error {
                    Text(error).font(.callout).foregroundStyle(.red)
                    Button("重試") { Task { await load() } }
                } else {
                    HStack { ProgressView(); Text("讀取 Spotify…").foregroundStyle(.secondary) }
                }
            } header: {
                HStack {
                    Label("這段時間聽了", systemImage: "music.note")
                    Spacer()
                    if let tracks, !tracks.isEmpty { Text("\(tracks.count) 首") }
                }
            } footer: {
                Text("Spotify 只記播超過 30 秒的歌，剛結束的那首可能要過一下才會出現。")
            }
            .task(id: sessionID) { await load() }
        } else if showConnectHint {
            Section {
                NavigationLink {
                    SpotifySettingsView()
                } label: {
                    Label("連結 Spotify，結束時列出這段聽了哪些歌", systemImage: "music.note")
                }
            }
        }
    }

    private func row(_ track: SpotifyTrack) -> some View {
        HStack(spacing: 10) {
            Image(systemName: track.nowPlaying ? "speaker.wave.2.fill" : "music.note")
                .foregroundStyle(Color.green)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.name).lineLimit(1)
                Text(track.artists.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(verbatim: track.nowPlaying ? "▶︎" : Self.time.string(from: track.playedAt))
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = track.url { UIApplication.shared.open(url) }
        }
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func load() async {
        error = nil
        do {
            let list = try await spotify.tracks(from: start, to: end)
            tracks = list
            if let sessionID { pomodoro.attachTracks(list.map(\.line), to: sessionID) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Spotify 設定

struct SpotifySettingsView: View {
    @State private var spotify = SpotifyService.shared
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                if spotify.isConnected {
                    Label("已連結", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("中斷連結", role: .destructive) { spotify.disconnect() }
                } else {
                    Button {
                        Task { await spotify.connect() }
                    } label: {
                        if spotify.isConnecting {
                            HStack { ProgressView(); Text("連結中…") }
                        } else {
                            Label("連結 Spotify", systemImage: "link")
                        }
                    }
                    .disabled(!spotify.isConfigured || spotify.isConnecting)
                }
                if let err = spotify.lastError {
                    Text(err).font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                Text("只要兩個唯讀權限：最近播放、正在播放。蕃茄鐘結束時查那段時間聽了哪些歌，記在那筆紀錄裡。")
            }

            Section {
                TextField("Client ID", text: $spotify.clientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            } header: {
                Text("Spotify Client ID")
            }

            Section("第一次設定（約 3 分鐘）") {
                Text("1. 用電腦打開 developer.spotify.com/dashboard，登入後按 Create app。")
                VStack(alignment: .leading, spacing: 6) {
                    Text("2. Redirect URI 填這一串（一字不差）：")
                    HStack {
                        Text(verbatim: SpotifyService.redirectURI)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        Button(copied ? "已複製" : "複製") {
                            UIPasteboard.general.string = SpotifyService.redirectURI
                            copied = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                Text("3. API 勾選 Web API，存檔。")
                Text("4. 打開這個 app 的 Settings，把 Client ID 貼到上面，再按「連結 Spotify」。")
            }
            .font(.callout)
        }
        .navigationTitle("Spotify")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
