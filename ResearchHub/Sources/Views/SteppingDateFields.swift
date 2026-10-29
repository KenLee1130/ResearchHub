#if os(macOS)
import SwiftUI
import AppKit

// 規劃預覽用的日期／時間欄：純文字、可以直接打，↑↓ 調整（日期一天、時間 15 分鐘），24 小時制。
// 不用系統的 DatePicker：它的欄位年在最前面、箭頭先動到年，而且 12 小時制不好打。

/// 解析使用者打的日期／時間（寬鬆：2026/11/5、11/5、13:30、1330、9 都收）。
enum PlanTimeInput {
    static let calendar = Calendar.current

    /// 日期：yyyy/M/d 或 M/d（年沿用 `base`）；回傳的 Date 保留 `base` 的時分。
    static func parseDay(_ text: String, base: Date) -> Date? {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "/").replacingOccurrences(of: ".", with: "/")
            .split(separator: "/").compactMap { Int($0) }
        var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: base)
        switch parts.count {
        case 3: comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        case 2: comps.month = parts[0]; comps.day = parts[1]
        default: return nil
        }
        guard let date = calendar.date(from: comps),
              calendar.component(.day, from: date) == comps.day else { return nil }   // 2/30 這種不收
        return date
    }

    /// 時間：H:mm、HHmm、H（整點）；回傳的 Date 保留 `base` 的年月日。
    static func parseTime(_ text: String, base: Date) -> Date? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "：", with: ":")
        var hour: Int?, minute = 0
        if let colon = t.firstIndex(of: ":") {
            hour = Int(t[..<colon]); minute = Int(t[t.index(after: colon)...]) ?? -1
        } else if let n = Int(t) {
            if t.count <= 2 { hour = n } else { hour = n / 100; minute = n % 100 }
        }
        guard let h = hour, (0...23).contains(h), (0...59).contains(minute) else { return nil }
        return calendar.date(bySettingHour: h, minute: minute, second: 0, of: base)
    }

    static func dayText(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy/MM/dd"
        return f.string(from: date)
    }

    static func timeText(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

/// 日期欄：打 2026/11/5 或 11/5，↑↓ 一天一天調。
struct DayTextField: View {
    @Binding var date: Date
    @State private var text = ""

    var body: some View {
        SteppingTextField(text: $text, width: 84,
                          onStep: { delta in
                              if let d = PlanTimeInput.calendar.date(byAdding: .day, value: delta, to: date) { date = d }
                          },
                          onCommit: {
                              if let d = PlanTimeInput.parseDay(text, base: date) { date = d }
                              text = PlanTimeInput.dayText(date)
                          })
        .onChange(of: date, initial: true) { _, new in text = PlanTimeInput.dayText(new) }
        .help("可以直接打 2026/11/5 或 11/5；↑↓ 一天一天調")
    }
}

/// 時間欄：24 小時制，打 13:30、1330 或 9，↑↓ 每次 15 分鐘。
struct TimeTextField: View {
    @Binding var date: Date
    var stepMinutes = 15
    @State private var text = ""

    var body: some View {
        SteppingTextField(text: $text, width: 52,
                          onStep: { delta in
                              if let d = PlanTimeInput.calendar.date(byAdding: .minute, value: delta * stepMinutes, to: date) { date = d }
                          },
                          onCommit: {
                              if let d = PlanTimeInput.parseTime(text, base: date) { date = d }
                              text = PlanTimeInput.timeText(date)
                          })
        .onChange(of: date, initial: true) { _, new in text = PlanTimeInput.timeText(new) }
        .help("24 小時制，可以直接打 13:30 或 1330；↑↓ 每次 15 分鐘")
    }
}

/// NSTextField：攔 ↑↓ 當步進、Return 與失焦當送出。SwiftUI 的 TextField 攔不到方向鍵。
struct SteppingTextField: NSViewRepresentable {
    @Binding var text: String
    var width: CGFloat
    var onStep: (Int) -> Void
    var onCommit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.alignment = .center
        field.controlSize = .small
        field.focusRingType = .default
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // 使用者正在打字時不要蓋掉他打的
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SteppingTextField
        init(_ parent: SteppingTextField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onCommit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onStep(1); return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onStep(-1); return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.text = textView.string
                parent.onCommit()
                control.window?.makeFirstResponder(nil)   // 收掉焦點，Return 不會往外傳成快捷鍵
                return true
            default:
                return false
            }
        }
    }
}
#endif
