#if os(macOS)
import SwiftUI

/// 版面設定面板。真相在專案裡的 format.tex（標準 LaTeX，Overleaf 也吃得懂）；
/// 這裡只是它的圖形介面，兩邊改都可以，打開面板時會重新讀檔。
struct FormatPanelView: View {
    let projectURL: URL
    var onApply: () -> Void
    var openFormatFile: () -> Void

    @State private var format = LatexFormat()
    @State private var engine = "auto"
    @State private var hasInput = true
    @State private var loaded = false

    private var formatURL: URL { projectURL.appendingPathComponent(LatexProject.formatName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("版面")
                .font(.headline)

            if !hasInput {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("主檔還沒引入 format.tex，這些設定不會生效。")
                            .font(.caption)
                        Button("在主檔加入 \\input{format}") { addFormatInput() }
                            .controlSize(.small)
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("紙張").gridColumnAlignment(.trailing)
                    Picker("", selection: $format.paper) {
                        Text("A4").tag("a4paper")
                        Text("Letter").tag("letterpaper")
                        Text("B5").tag("b5paper")
                        Text("A5").tag("a5paper")
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                GridRow {
                    Text("上下留白")
                    HStack(spacing: 6) {
                        mmField("上", $format.top)
                        mmField("下", $format.bottom)
                    }
                }
                GridRow {
                    Text("左右留白")
                    HStack(spacing: 6) {
                        mmField("左", $format.left)
                        mmField("右", $format.right)
                    }
                }
                GridRow {
                    Text("行距")
                    HStack(spacing: 6) {
                        Slider(value: $format.lineStretch, in: 1.0...2.5, step: 0.05)
                            .frame(width: 110)
                        Text(String(format: "%.2f", format.lineStretch))
                            .font(.caption.monospacedDigit())
                            .frame(width: 34, alignment: .trailing)
                    }
                }
                GridRow {
                    Text("段落間距")
                    HStack(spacing: 6) {
                        Slider(value: $format.parSkip, in: 0...2, step: 0.1)
                            .frame(width: 110)
                        Text(String(format: "%.1fem", format.parSkip))
                            .font(.caption.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                GridRow {
                    Text("字級")
                    Picker("", selection: $format.fontSize) {
                        Text("10 pt").tag(10)
                        Text("11 pt").tag(11)
                        Text("12 pt").tag(12)
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                GridRow {
                    Text("編譯器")
                    Picker("", selection: $engine) {
                        Text("自動（依 latexmkrc）").tag("auto")
                        Text("XeLaTeX（中文用）").tag("xelatex")
                        Text("pdfLaTeX").tag("pdflatex")
                        Text("LuaLaTeX").tag("lualatex")
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }

            Divider()

            HStack {
                Button("直接編輯 format.tex") { openFormatFile() }
                    .controlSize(.small)
                Spacer()
                Button("套用") { apply() }
                    .keyboardShortcut(.defaultAction)
            }

            Text("設定存在專案的 format.tex 與 latexmkrc；字級寫在主檔的 \\documentclass。"
                 + "帶去 Overleaf 排版一樣。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 380)
        .onAppear(perform: load)
    }

    private func mmField(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", value: value, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
                .multilineTextAlignment(.trailing)
            Text("mm").font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - 讀寫

    private func load() {
        guard !loaded else { return }
        loaded = true
        let text = (try? String(contentsOf: formatURL, encoding: .utf8)) ?? ""
        let mainText = LatexProject.mainFile(in: projectURL)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        format = LatexFormat.parse(text, fontSize: LatexFormat.fontSize(inMain: mainText))
        hasInput = mainText.isEmpty || LatexFormat.hasFormatInput(mainText)
        let s = LatexProject.settings(of: projectURL)
        engine = s.engine ?? LatexProject.engine(for: projectURL, main:
            LatexProject.mainFile(in: projectURL) ?? projectURL)
    }

    private func apply() {
        let existing = try? String(contentsOf: formatURL, encoding: .utf8)
        try? format.render(into: existing).write(to: formatURL, atomically: true, encoding: .utf8)

        if let main = LatexProject.mainFile(in: projectURL),
           let text = try? String(contentsOf: main, encoding: .utf8) {
            var updated = text
            if LatexFormat.fontSize(inMain: text) != format.fontSize {
                updated = LatexFormat.setFontSize(format.fontSize, inMain: updated)
            }
            if updated != text {
                try? updated.write(to: main, atomically: true, encoding: .utf8)
            }
        }

        var s = LatexProject.settings(of: projectURL)
        s.engine = engine
        LatexProject.save(s, to: projectURL)
        onApply()
    }

    private func addFormatInput() {
        guard let main = LatexProject.mainFile(in: projectURL),
              let text = try? String(contentsOf: main, encoding: .utf8) else { return }
        try? LatexFormat.insertFormatInput(text)
            .write(to: main, atomically: true, encoding: .utf8)
        if !FileManager.default.fileExists(atPath: formatURL.path) {
            try? format.render(into: nil).write(to: formatURL, atomically: true, encoding: .utf8)
        }
        hasInput = true
    }
}
#endif
