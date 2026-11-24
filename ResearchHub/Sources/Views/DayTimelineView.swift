#if os(macOS)
import SwiftUI
import HubCore
import HubStore
import UniformTypeIdentifiers

/// 日記分頁月曆欄旁邊的「今天的時間軸」：一條豎直的小時刻度，當天事件依標籤色畫成色塊，
/// 紫線是現在時刻，過去的時段壓暗，夠長的空檔標出來；日記裡還沒排時段的待辦列在最下面，
/// 拖到軸上就排成事件（並把日記那一行搬進檔首規劃段）。
///
/// 跟 `MacMonthGrid` 一樣隨欄寬連續變化，不是三個版面切換：
///   • 寬 ≥ 200：標題＋時間＋蕃茄格＋空檔＋待拖的待辦
///   • 中 72–200：只留一行標題，字隨寬度淡出
///   • 窄 ≤ 72：只剩色塊與現在線，滑過顯示說明
/// 範圍與座標全交給 `DayTimelineLayout`（HubCore，可測），這裡只畫。
struct DayTimelineView: View {
    @Environment(EventStore.self) private var eventStore
    /// 蕃茄鐘紀錄與正在跑的那段 → 軸左側的紅線
    @Environment(PomodoroModel.self) private var pomodoro
    @AppStorage(PomodoroModel.SettingsKey.workMinutes) private var workMinutes = 25
    /// 預設範圍（設定可改）：沒有更早／更晚的事件時軸從幾點到幾點
    @AppStorage("timeline.startHour") private var defaultStartHour = 8
    @AppStorage("timeline.endHour") private var defaultEndHour = 22

    let day: Date
    /// 當天的事件（重複的已展開）
    let events: [CalendarEvent]
    /// 當天日記裡的待辦行（正在編輯的用編輯器裡的文字）：挑出還沒排時段的給拖放
    let todoLines: [TodoLine]
    /// 事件是否完成（日記裡對應的規劃行勾掉了）
    let isDone: (CalendarEvent) -> Bool
    /// 點色塊 → 開事件編輯器
    let onOpen: (CalendarEvent) -> Void
    /// 待辦拖到軸上某個時刻（已對齊 15 分鐘）
    let onSchedule: (TodoLine, Date) -> Void
    /// 色塊拖到新時段（整塊平移或拉底邊，已對齊 15 分鐘）
    let onRetime: (CalendarEvent, Date, Date) -> Void

    @State private var width: CGFloat = 232
    /// 正在從下面清單拖的那一句（`.onDrag` 時記下，`performDrop` 就不必解 NSItemProvider）
    @State private var dragging: TodoLine?
    /// 拖曳經過軸時的落點預覽
    @State private var dropStart: Date?
    /// 點開詳情的那條紅線（用開始時刻認，每分鐘重繪也不會跳掉）
    @State private var openFocus: Date?
    /// 正在拖的色塊：整塊平移或拉底邊，`dy` 是目前拖了幾點
    @State private var blockDrag: BlockDrag?

    private struct BlockDrag {
        enum Kind { case move, resize }
        let id: UUID
        let kind: Kind
        var dy: CGFloat
    }

    private let calendar = Calendar.current

    /// 欄寬 ≤ narrow：只剩色塊；≥ wide：全資訊；中間線性過渡
    static let narrowWidth: CGFloat = 72
    static let wideWidth: CGFloat = 200
    private var t: CGFloat {
        min(max((width - Self.narrowWidth) / (Self.wideWidth - Self.narrowWidth), 0), 1)
    }
    private var isNarrow: Bool { width <= Self.narrowWidth }
    private var isWide: Bool { width >= Self.wideWidth }
    /// 小時標籤那一欄的寬
    private var gutter: CGFloat { isNarrow ? 20 : 38 }

    private var rules: DayTimelineLayout.Rules {
        DayTimelineLayout.Rules(defaultStartHour: defaultStartHour, defaultEndHour: defaultEndHour)
    }

    /// 還沒排時段、也還沒做完的待辦
    private var unscheduled: [TodoLine] {
        todoLines.filter { !$0.done && !FileSystemStore.hasTimeRange($0.meta.cleanText) }
    }

    var body: some View {
        // 每分鐘重繪：現在線、過去壓暗、空檔「還剩」都跟著走
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(spacing: 0) {
                header(now: context.date)
                Divider()
                GeometryReader { geo in
                    let layout = DayTimelineLayout.make(
                        day: day, events: events, availableHeight: geo.size.height - 16,
                        rules: rules, calendar: calendar)
                    if layout.scrolls {
                        ScrollView(.vertical) {
                            axis(layout, now: context.date, width: geo.size.width)
                                .padding(.vertical, 8)
                        }
                    } else {
                        axis(layout, now: context.date, width: geo.size.width)
                            .padding(.vertical, 8)
                    }
                }
                if isWide, !unscheduled.isEmpty {
                    Divider()
                    unscheduledList
                }
            }
        }
        .background(GeometryReader { geo in
            Color.clear.onChange(of: geo.size.width, initial: true) { _, new in width = new }
        })
        .inkSurface(.chrome)
    }

    // MARK: - 標題列

    @ViewBuilder private func header(now: Date) -> some View {
        let isToday = calendar.isDateInToday(day)
        if isNarrow {
            // 窄：只放一個時鐘圖示，滑過看日期
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .help(Text(dayTitle))
        } else {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(isToday ? L("時間軸 · 今天") : L("時間軸"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(dayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isWide {
                    VStack(alignment: .trailing, spacing: 1) {
                        if isToday {
                            Text(Self.clock.string(from: now))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Color.accentColor)
                        }
                        Text(scheduledSummary)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private var dayTitle: String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("Md EEE")
        return f.string(from: day)
    }

    private var scheduledSummary: String {
        let minutes = DayTimelineLayout.make(day: day, events: events, availableHeight: 600,
                                             rules: rules, calendar: calendar).scheduledMinutes
        return L("已排 \(Self.hoursText(minutes))")
    }

    // MARK: - 軸

    private func axis(_ layout: DayTimelineLayout, now: Date, width: CGFloat) -> some View {
        let isToday = calendar.isDateInToday(day)
        let blockLeft = gutter
        let blockRight: CGFloat = isNarrow ? 4 : 8
        let blockArea = max(width - blockLeft - blockRight, 10)

        return ZStack(alignment: .topLeading) {
            // 小時刻度
            ForEach(layout.hours, id: \.self) { hour in
                hourRow(hour, layout: layout)
                    .frame(width: width, height: layout.pointsPerHour, alignment: .topLeading)
                    .offset(y: CGFloat(hour - layout.startHour) * layout.pointsPerHour)
            }
            Rectangle().fill(.quaternary).frame(width: width, height: 1)
                .offset(y: layout.totalHeight)

            // 今天：過去的時段壓暗
            if isToday {
                Rectangle()
                    .fill(Color.black.opacity(0.22))
                    .frame(width: width, height: max(layout.y(for: now), 0))
                    .allowsHitTesting(false)
            }

            // 空檔（只在寬版、且還沒過去）
            if isWide {
                ForEach(Array(layout.gaps.enumerated()), id: \.offset) { _, gap in
                    if !isToday || gap.end > now {
                        gapChip(gap, now: isToday ? now : nil)
                            .offset(x: blockLeft, y: gap.y + 6)
                    }
                }
            }

            // 事件色塊
            ForEach(layout.blocks) { block in
                let colWidth = blockArea / CGFloat(block.columnCount)
                let preview = dragPreview(block, layout: layout)
                let y = preview.map { layout.y(for: $0.start) } ?? block.y
                let height = preview.map { layout.y(for: $0.end) - layout.y(for: $0.start) } ?? block.height
                blockView(block, layout: layout, range: preview)
                    .frame(width: max(colWidth - 2, 8), height: max(height - 2, 8))
                    .offset(x: blockLeft + CGFloat(block.column) * colWidth, y: y + 1)
                    .zIndex(blockDrag?.id == block.id ? 1 : 0)
            }

            // 蕃茄鐘：專注過的時段畫成紅色直線，正在跑的延伸到現在（任一台裝置）
            ForEach(Array(pomodoro.focusSpans(on: day, now: now).enumerated()), id: \.offset) { _, span in
                focusLine(span, layout: layout, now: now)
                    .offset(x: blockLeft - (isNarrow ? 4 : 6) - 5, y: layout.y(for: span.start))
            }

            // 拖放預覽
            if let start = dropStart, let todo = dragging {
                let minutes = todo.meta.estMinutes ?? 60
                let end = min(start.addingTimeInterval(Double(minutes) * 60), layout.dayEnd)
                dropPreview(todo, start: start, end: end)
                    .frame(width: blockArea - 2, height: max(layout.y(for: end) - layout.y(for: start) - 2, 8))
                    .offset(x: blockLeft, y: layout.y(for: start) + 1)
                    .allowsHitTesting(false)
            }

            // 現在線
            if isToday, now >= layout.date(at: 0), now <= layout.date(at: layout.totalHeight) {
                nowLine(width: width)
                    .offset(y: layout.y(for: now))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: layout.totalHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .onDrop(of: [.utf8PlainText, .plainText], delegate: TimelineDropDelegate(
            layout: layout,
            dropStart: $dropStart,
            performDrop: { start in
                guard let todo = dragging else { return false }
                dragging = nil
                onSchedule(todo, start)
                return true
            }))
    }

    private func hourRow(_ hour: Int, layout: DayTimelineLayout) -> some View {
        // 窄版每兩小時標一次，免得擠成一團；壓縮時也一樣
        let label = hour % 24
        let show = isNarrow || layout.pointsPerHour < 30 ? label % 2 == 0 : true
        return VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(.quaternary).frame(height: 1)
            if show {
                Text(String(format: "%02d", label))
                    .font(.system(size: isNarrow ? 8 : 9))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.leading, isNarrow ? 3 : 8)
                    .padding(.top, 1)
            }
        }
    }

    private func focusLine(_ span: FocusSpan, layout: DayTimelineLayout, now: Date) -> some View {
        let height = max(layout.y(for: span.end) - layout.y(for: span.start), 2)
        let isOpen = openFocus == span.start
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.red)
                .frame(width: isOpen ? 5 : 3, height: height)
            if span.live {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                    .shadow(color: .red.opacity(0.6), radius: 3)
                    .offset(y: 3.5)
            }
        }
        .frame(width: 7, height: height, alignment: .bottom)
        // 線只有 3pt 寬，點擊範圍往左（小時欄）放寬、太短的也至少 12pt 高
        .frame(width: 12, height: max(height, 12), alignment: .bottomTrailing)
        .contentShape(Rectangle())
        .offset(x: -2)
        .onTapGesture { openFocus = isOpen ? nil : span.start }
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .popover(isPresented: Binding(
            get: { openFocus == span.start },
            set: { if !$0, openFocus == span.start { openFocus = nil } }),
                 arrowEdge: .trailing) {
            FocusSpanDetailView(span: span,
                                session: span.sessionID.flatMap { pomodoro.session(id: $0) },
                                events: events, now: now)
        }
        .help(Text(span.live
                   ? L("蕃茄鐘進行中 · \(Self.rangeText(span.start, span.end)) · 點一下看詳情")
                   : L("蕃茄鐘 · \(Self.rangeText(span.start, span.end)) · 點一下看詳情")))
    }

    private func nowLine(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.accentColor).frame(width: width, height: 1.5)
            Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                .offset(x: gutter - 6)
        }
        .frame(height: 7)
        .offset(y: -3.5)
    }

    private func gapChip(_ gap: DayTimelineLayout.Gap, now: Date?) -> some View {
        // 今天的空檔從現在起算
        let from = now.map { max($0, gap.start) } ?? gap.start
        let minutes = Int(gap.end.timeIntervalSince(from) / 60)
        return Text(L("空檔 \(Self.hoursText(minutes))"))
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
    }

    // MARK: - 色塊

    /// 拖曳中的色塊顯示在哪（沒在拖、或拖了等於沒動回 nil）
    private func dragPreview(_ block: DayTimelineLayout.Block, layout: DayTimelineLayout) -> (start: Date, end: Date)? {
        guard let drag = blockDrag, drag.id == block.id else { return nil }
        switch drag.kind {
        case .move: return layout.moving(block, by: drag.dy)
        case .resize: return layout.resizing(block, by: drag.dy)
        }
    }

    /// 跨日（被裁過）的色塊不能拖
    private func canDrag(_ block: DayTimelineLayout.Block) -> Bool {
        block.start == block.event.start && block.end == block.event.end
    }

    /// 拖整塊或拉底邊。用全域座標算位移：色塊預覽跟著移動，自己的座標系也會跟著跑。
    private func dragGesture(_ block: DayTimelineLayout.Block, kind: BlockDrag.Kind,
                             layout: DayTimelineLayout) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                blockDrag = BlockDrag(id: block.id, kind: kind, dy: value.translation.height)
            }
            .onEnded { value in
                blockDrag = nil
                let result = kind == .move
                    ? layout.moving(block, by: value.translation.height)
                    : layout.resizing(block, by: value.translation.height)
                if let result { onRetime(block.event, result.start, result.end) }
            }
    }

    private func blockView(_ block: DayTimelineLayout.Block, layout: DayTimelineLayout,
                           range: (start: Date, end: Date)?) -> some View {
        let tag = eventStore.tag(for: block.event.tagID)
        let color = tag?.color ?? .gray
        let done = isDone(block.event)
        let boxes = pomodoroBoxes(for: block)
        let dragging = blockDrag?.id == block.id
        let shown = range ?? (block.start, block.end)
        let draggable = canDrag(block)
        return HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3)
            if !isNarrow {
                VStack(alignment: .leading, spacing: 2) {
                    Text(block.event.title)
                        .font(.system(size: isWide ? 12 : 11))
                        .strikethrough(done)
                        .foregroundStyle(done ? Color.secondary : Color.primary)
                        .lineLimit(block.height >= 56 ? 2 : 1)
                        .opacity(Double(t))
                    if isWide, block.height >= 36 || dragging {
                        HStack(spacing: 5) {
                            Text(Self.rangeText(shown.start, shown.end))
                                .foregroundStyle(dragging ? Color.accentColor : Color.secondary)
                            if let boxes, !dragging {
                                pomodoroRow(total: boxes.total, done: boxes.done)
                            }
                            if let tag, block.height >= 56, !dragging {
                                Text(tag.name).foregroundStyle(color)
                            }
                        }
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(done ? 0.10 : isNarrow ? 0.32 : 0.18)))
        .overlay {
            if dragging {
                RoundedRectangle(cornerRadius: 6).strokeBorder(color, lineWidth: 1.5)
            }
        }
        .shadow(color: .black.opacity(dragging ? 0.35 : 0), radius: 6, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { onOpen(block.event) }
        .gesture(dragGesture(block, kind: .move, layout: layout), including: draggable ? .all : .subviews)
        // 底邊拉長／縮短
        .overlay(alignment: .bottom) {
            if draggable {
                Color.clear
                    .frame(height: 6)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(dragGesture(block, kind: .resize, layout: layout))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen(block.event) }
        .help(Text(draggable
                   ? L("\(block.event.title)\n\(Self.rangeText(block.start, block.end))\n拖曳移動、拉底邊改長度")
                   : L("\(block.event.title)\n\(Self.rangeText(block.start, block.end))")))
    }

    /// 這段要幾顆蕃茄（事件長度 ÷ 專注分鐘）、日記那一行已投入幾顆（`@pomo(n)`）
    private func pomodoroBoxes(for block: DayTimelineLayout.Block) -> (total: Int, done: Int)? {
        let minutes = block.minutes
        guard minutes > 0, workMinutes > 0 else { return nil }
        let total = Int((Double(minutes) / Double(workMinutes)).rounded(.up))
        let title = block.event.title.trimmingCharacters(in: .whitespaces)
        let done = todoLines.first { line in
            FileSystemStore.hasTimeRange(line.meta.cleanText)
                && line.meta.cleanText.hasSuffix(" " + title)
        }?.meta.pomoDone ?? 0
        return (total, min(done, total))
    }

    private func pomodoroRow(total: Int, done: Int) -> some View {
        HStack(spacing: 2) {
            // 最多畫 8 格，再多用數字
            ForEach(0..<min(total, 8), id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i < done ? Color.orange : Color.primary.opacity(0.14))
                    .frame(width: 6, height: 6)
            }
            Text("\(done)/\(total)")
        }
    }

    private func dropPreview(_ todo: TodoLine, start: Date, end: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(todo.meta.cleanText)
                .font(.system(size: 12))
                .lineLimit(1)
            Text(Self.rangeText(start, end))
                .font(.system(size: 9))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
    }

    // MARK: - 還沒排時段的待辦（拖進軸裡）

    private var unscheduledList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("還沒排時段")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(unscheduled, id: \.lineIndex) { todo in
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                    Text(todo.meta.cleanText)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let est = todo.meta.estMinutes {
                        Text(Self.hoursText(est))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                .contentShape(Rectangle())
                .help("拖到上面的時間軸排時段（長度用 @est，沒有就 1 小時）")
                .onDrag {
                    dragging = todo
                    return NSItemProvider(object: todo.meta.cleanText as NSString)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxHeight: 160)
    }

    // MARK: - 文字

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func rangeText(_ start: Date, _ end: Date) -> String {
        "\(clock.string(from: start))–\(clock.string(from: end))"
    }

    /// 90 → 1h30、120 → 2h、45 → 45m
    static func hoursText(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h\(String(format: "%02d", m))"
    }
}

/// 把拖曳位置換成時刻：經過時更新預覽，放開時交給 view 建事件。
/// 座標是 `.onDrop` 掛的那個 view（軸本身）的座標，所以 y 直接丟給 layout 換算。
private struct TimelineDropDelegate: DropDelegate {
    let layout: DayTimelineLayout
    @Binding var dropStart: Date?
    let performDrop: (Date) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.utf8PlainText, .plainText])
    }

    func dropEntered(info: DropInfo) {
        dropStart = layout.date(at: info.location.y)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropStart = layout.date(at: info.location.y)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        dropStart = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let start = layout.date(at: info.location.y)
        dropStart = nil
        return performDrop(start)
    }
}
#endif
