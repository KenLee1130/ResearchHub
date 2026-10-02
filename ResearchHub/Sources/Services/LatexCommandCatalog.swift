import Foundation

/// 一個可補全的 LaTeX 指令。
nonisolated struct LatexCommand: Sendable {
    /// 接受時插入的文字，例如 `\frac{}{}`（游標會停在第一個 `{}` 裡）
    let insert: String
    /// 清單上灰字的說明；符號類直接放長相（α、⇒）
    let detail: String
    /// 只在 LaTeX 專案裡才有意義的指令（\documentclass、\input…），Markdown 筆記不顯示
    let projectOnly: Bool
}

/// 編輯器補全用的指令庫。
///
/// 分類排序有意義：同樣符合前綴時，越常用的排越前面。
/// 新增指令時放進對應分類即可；符號類的 detail 放 Unicode 長相，
/// 其他放一句繁中說明。
enum LatexCommandCatalog {

    static let all: [LatexCommand] =
        documentStructure + preamble + references + lists + floatsAndTables
        + textStyle + spacing + mathStructure + mathFonts + accents
        + bigOperators + functions + relations + arrows + binaryOperators
        + symbols + delimiters + greek + physics

    // MARK: - 文件結構

    private static let documentStructure: [LatexCommand] = [
        // 選了 \begin{} 會接著列環境名稱，選好自動補 \end{}（見 SourceTextView.acceptEnvironment）
        c(#"\begin{}"#, "開始環境"),
        c(#"\end{}"#, "結束環境"),
        c(#"\section{}"#, "節"),
        c(#"\subsection{}"#, "小節"),
        c(#"\subsubsection{}"#, "小小節"),
        c(#"\section*{}"#, "不編號的節"),
        c(#"\subsection*{}"#, "不編號的小節"),
        c(#"\paragraph{}"#, "段落標題"),
        c(#"\subparagraph{}"#, "小段落標題"),
        p(#"\chapter{}"#, "章（report／book）"),
        p(#"\chapter*{}"#, "不編號的章"),
        p(#"\part{}"#, "部"),
        c(#"\title{}"#, "標題"),
        c(#"\subtitle{}"#, "副標題"),
        c(#"\author{}"#, "作者"),
        c(#"\date{}"#, #"日期（\today＝今天）"#),
        c(#"\maketitle"#, "印出標題區"),
        c(#"\tableofcontents"#, "目錄"),
        p(#"\listoffigures"#, "圖目錄"),
        p(#"\listoftables"#, "表目錄"),
        c(#"\appendix"#, "之後的節改成附錄編號（A、B…）"),
        c(#"\newpage"#, "換頁"),
        c(#"\clearpage"#, "換頁並先排完所有浮動物件"),
        p(#"\cleardoublepage"#, "換到下一個奇數頁"),
        c(#"\pagebreak"#, "建議在此換頁"),
        c(#"\linebreak"#, "建議在此換行"),
        c(#"\newline"#, "強制換行"),
        c(#"\noindent"#, "這段不縮排"),
        c(#"\par"#, "結束段落"),
        p(#"\frontmatter"#, "前言部分（book）"),
        p(#"\mainmatter"#, "正文部分（book）"),
        p(#"\backmatter"#, "後記部分（book）"),
        c(#"\today"#, "今天的日期"),
        c(#"\LaTeX"#, "LaTeX 標誌"),
        c(#"\TeX"#, "TeX 標誌"),
        c(#"\thanks{}"#, "標題區的註腳（致謝、單位）"),
        p(#"\affiliation{}"#, "作者單位（revtex）"),
        p(#"\email{}"#, "電子郵件（revtex）"),
        p(#"\keywords{}"#, "關鍵字"),
    ]

    // MARK: - 導言區與檔案

    private static let preamble: [LatexCommand] = [
        p(#"\documentclass{}"#, "文件類別"),
        p(#"\documentclass[11pt]{}"#, "文件類別＋字級"),
        p(#"\usepackage{}"#, "載入套件"),
        p(#"\usepackage[]{}"#, "帶選項載入套件"),
        p(#"\input{}"#, "貼入另一個 .tex 檔的內容（任何地方可用）"),
        p(#"\include{}"#, "以新的一頁插入一章（只能在正文）"),
        p(#"\includeonly{}"#, "只編譯這幾章（放導言區）"),
        p(#"\subfile{}"#, "插入子檔（subfiles 套件）"),
        p(#"\newcommand{}{}"#, "定義新指令"),
        p(#"\newcommand{}[1]{}"#, "定義帶一個參數的新指令（#1）"),
        p(#"\renewcommand{}{}"#, "重新定義既有指令"),
        p(#"\providecommand{}{}"#, "還沒定義才定義"),
        p(#"\newenvironment{}{}{}"#, "定義新環境"),
        p(#"\DeclareMathOperator{}{}"#, #"定義數學運算子（如 \Tr）"#),
        p(#"\newtheorem{}{}"#, "定義定理類環境"),
        p(#"\theoremstyle{}"#, "定理樣式：plain／definition／remark"),
        p(#"\numberwithin{equation}{section}"#, "公式依節編號（1.1、1.2…）"),
        p(#"\allowdisplaybreaks"#, "允許長公式跨頁"),
        p(#"\bibliography{}"#, "BibTeX 參考文獻檔"),
        p(#"\bibliographystyle{}"#, "BibTeX 文獻樣式"),
        p(#"\addbibresource{}"#, "biblatex 參考文獻檔"),
        p(#"\printbibliography"#, "印出參考文獻（biblatex）"),
        p(#"\graphicspath{{figures/}}"#, "圖片資料夾"),
        p(#"\geometry{}"#, "版面邊界（geometry）"),
        p(#"\hypersetup{}"#, "連結樣式（hyperref）"),
        p(#"\setCJKmainfont{}"#, "中文主字型（xeCJK）"),
        p(#"\setmainfont{}"#, "主字型（fontspec）"),
        p(#"\setlength{}{}"#, "設定長度"),
        p(#"\setcounter{}{}"#, "設定計數器"),
        p(#"\pagestyle{}"#, "頁面樣式：plain／empty／fancy"),
        p(#"\thispagestyle{}"#, "這一頁的頁面樣式"),
        p(#"\setstretch{}"#, "行距倍數（setspace）"),
    ]

    // MARK: - 引用與連結

    private static let references: [LatexCommand] = [
        c(#"\label{}"#, "設定標籤"),
        c(#"\ref{}"#, "引用編號"),
        c(#"\eqref{}"#, "引用公式編號（含括號）"),
        c(#"\pageref{}"#, "引用頁碼"),
        c(#"\autoref{}"#, "自動加上「Figure」「Section」（hyperref）"),
        c(#"\cref{}"#, "自動加上類型名稱（cleveref）"),
        c(#"\Cref{}"#, #"同 \cref，句首大寫"#),
        c(#"\nameref{}"#, "引用標題文字"),
        c(#"\cite{}"#, "引用文獻"),
        c(#"\citep{}"#, "括號式引用（natbib）"),
        c(#"\citet{}"#, "文字式引用（natbib）"),
        c(#"\footnote{}"#, "註腳"),
        c(#"\marginpar{}"#, "頁邊註記"),
        c(#"\todo{}"#, "待辦註記（todonotes）"),
        c(#"\href{}{}"#, "超連結"),
        c(#"\url{}"#, "網址"),
    ]

    // MARK: - 清單

    private static let lists: [LatexCommand] = [
        c(#"\item"#, "清單項目"),
        c(#"\item[]"#, "自訂標記的清單項目"),
    ]

    // MARK: - 圖表

    private static let floatsAndTables: [LatexCommand] = [
        c(#"\includegraphics{}"#, "插入圖片"),
        c(#"\includegraphics[width=\linewidth]{}"#, "插入圖片（與行同寬）"),
        c(#"\caption{}"#, "圖表說明"),
        c(#"\centering"#, "置中"),
        c(#"\hline"#, "表格橫線"),
        c(#"\cline{}"#, "表格部分橫線（如 2-3）"),
        c(#"\toprule"#, "表格頂線（booktabs）"),
        c(#"\midrule"#, "表格中線（booktabs）"),
        c(#"\bottomrule"#, "表格底線（booktabs）"),
        c(#"\multicolumn{}{}{}"#, "合併欄"),
        c(#"\multirow{}{}{}"#, "合併列（multirow）"),
        c(#"\linewidth"#, "目前行寬"),
        c(#"\textwidth"#, "版心寬度"),
        c(#"\columnwidth"#, "欄寬"),
    ]

    // MARK: - 文字樣式

    private static let textStyle: [LatexCommand] = [
        c(#"\textbf{}"#, "粗體"),
        c(#"\textit{}"#, "斜體"),
        c(#"\emph{}"#, "強調"),
        c(#"\underline{}"#, "底線"),
        c(#"\texttt{}"#, "等寬字"),
        c(#"\textsc{}"#, "小型大寫"),
        c(#"\textsf{}"#, "無襯線"),
        c(#"\textrm{}"#, "羅馬體"),
        c(#"\textsl{}"#, "傾斜體"),
        c(#"\textnormal{}"#, "恢復一般字體"),
        c(#"\textsuperscript{}"#, "上標文字"),
        c(#"\textsubscript{}"#, "下標文字"),
        c(#"\textcolor{red}{}"#, "紅字"),
        c(#"\textcolor{blue}{}"#, "藍字"),
        c(#"\textcolor{green}{}"#, "綠字"),
        c(#"\textcolor{orange}{}"#, "橘字"),
        c(#"\textcolor{purple}{}"#, "紫字"),
        c(#"\color{}"#, "之後的文字換顏色"),
        c(#"\colorbox{red}{}"#, "底色標記"),
        c(#"\tiny"#, "字級：最小"),
        c(#"\scriptsize"#, "字級"),
        c(#"\footnotesize"#, "字級：註腳大小"),
        c(#"\small"#, "字級：小"),
        c(#"\normalsize"#, "字級：一般"),
        c(#"\large"#, "字級：大"),
        c(#"\Large"#, "字級：更大"),
        c(#"\LARGE"#, "字級"),
        c(#"\huge"#, "字級：巨大"),
        c(#"\Huge"#, "字級：最大"),
        c(#"\verb||"#, "原樣輸出（行內）"),
        c(#"\ldots"#, "…"),
        c(#"\textbackslash"#, "\\"),
    ]

    // MARK: - 間距

    private static let spacing: [LatexCommand] = [
        c(#"\vspace{}"#, "垂直空白"),
        c(#"\hspace{}"#, "水平空白"),
        c(#"\vfill"#, "垂直撐滿"),
        c(#"\hfill"#, "水平撐滿"),
        c(#"\quad"#, "1em 空白"),
        c(#"\qquad"#, "2em 空白"),
        c(#"\smallskip"#, "小段距"),
        c(#"\medskip"#, "中段距"),
        c(#"\bigskip"#, "大段距"),
        c(#"\indent"#, "縮排"),
        c(#"\phantom{}"#, "佔位但不顯示"),
        c(#"\hphantom{}"#, "水平佔位"),
        c(#"\vphantom{}"#, "垂直佔位"),
    ]

    // MARK: - 數學：結構

    private static let mathStructure: [LatexCommand] = [
        c(#"\frac{}{}"#, "分數"),
        c(#"\dfrac{}{}"#, "大分數（display 大小）"),
        c(#"\tfrac{}{}"#, "小分數（行內大小）"),
        c(#"\binom{}{}"#, "二項式係數"),
        c(#"\sqrt{}"#, "√"),
        c(#"\sqrt[]{}"#, "n 次方根"),
        c(#"\text{}"#, "數學中的文字"),
        c(#"\operatorname{}"#, "自訂運算子名稱"),
        c(#"\overbrace{}^{}"#, "上大括號"),
        c(#"\underbrace{}_{}"#, "下大括號"),
        c(#"\overset{}{}"#, "上方加符號"),
        c(#"\underset{}{}"#, "下方加符號"),
        c(#"\stackrel{}{}"#, "上方疊符號"),
        c(#"\xrightarrow{}"#, "可加文字的長箭頭 →"),
        c(#"\xleftarrow{}"#, "可加文字的長箭頭 ←"),
        c(#"\substack{}"#, "多行下標"),
        c(#"\tag{}"#, "自訂公式編號"),
        c(#"\nonumber"#, "這行不編號"),
        c(#"\notag"#, "這行不編號"),
        c(#"\displaystyle"#, "display 大小"),
        c(#"\limits"#, "上下限放正上下方"),
    ]

    // MARK: - 數學：字體

    private static let mathFonts: [LatexCommand] = [
        c(#"\mathrm{}"#, "直立體"),
        c(#"\mathbf{}"#, "粗體"),
        c(#"\mathit{}"#, "斜體"),
        c(#"\mathsf{}"#, "無襯線"),
        c(#"\mathtt{}"#, "等寬"),
        c(#"\mathbb{}"#, "黑板粗體 ℝℂℤ"),
        c(#"\mathcal{}"#, "花體 𝒜ℬ𝒞"),
        c(#"\mathfrak{}"#, "德文尖角體 𝔤𝔥"),
        c(#"\mathscr{}"#, "手寫體（mathrsfs）"),
        c(#"\boldsymbol{}"#, "粗體符號（含希臘字母）"),
        c(#"\bm{}"#, "粗體符號（bm 套件）"),
    ]

    // MARK: - 數學：重音

    private static let accents: [LatexCommand] = [
        c(#"\hat{}"#, "x̂"),
        c(#"\widehat{}"#, "寬帽"),
        c(#"\bar{}"#, "x̄"),
        c(#"\overline{}"#, "上橫線"),
        c(#"\tilde{}"#, "x̃"),
        c(#"\widetilde{}"#, "寬波浪"),
        c(#"\vec{}"#, "向量箭頭 x⃗"),
        c(#"\overrightarrow{}"#, "長向量箭頭"),
        c(#"\dot{}"#, "ẋ"),
        c(#"\ddot{}"#, "ẍ"),
        c(#"\check{}"#, "x̌"),
        c(#"\breve{}"#, "x̆"),
        c(#"\acute{}"#, "x́"),
        c(#"\grave{}"#, "x̀"),
    ]

    // MARK: - 數學：大型運算子

    private static let bigOperators: [LatexCommand] = [
        c(#"\sum"#, "∑"),
        c(#"\prod"#, "∏"),
        c(#"\coprod"#, "∐"),
        c(#"\int"#, "∫"),
        c(#"\iint"#, "∬"),
        c(#"\iiint"#, "∭"),
        c(#"\oint"#, "∮"),
        c(#"\bigcup"#, "⋃"),
        c(#"\bigcap"#, "⋂"),
        c(#"\bigoplus"#, "⨁"),
        c(#"\bigotimes"#, "⨂"),
        c(#"\lim"#, "lim"),
        c(#"\limsup"#, "lim sup"),
        c(#"\liminf"#, "lim inf"),
        c(#"\max"#, "max"),
        c(#"\min"#, "min"),
        c(#"\sup"#, "sup"),
        c(#"\inf"#, "inf"),
    ]

    // MARK: - 數學：函數名

    private static let functions: [LatexCommand] = [
        c(#"\sin"#, "sin"), c(#"\cos"#, "cos"), c(#"\tan"#, "tan"),
        c(#"\cot"#, "cot"), c(#"\sec"#, "sec"), c(#"\csc"#, "csc"),
        c(#"\arcsin"#, "arcsin"), c(#"\arccos"#, "arccos"), c(#"\arctan"#, "arctan"),
        c(#"\sinh"#, "sinh"), c(#"\cosh"#, "cosh"), c(#"\tanh"#, "tanh"),
        c(#"\exp"#, "exp"), c(#"\log"#, "log"), c(#"\ln"#, "ln"),
        c(#"\det"#, "det"), c(#"\dim"#, "dim"), c(#"\ker"#, "ker"),
        c(#"\deg"#, "deg"), c(#"\gcd"#, "gcd"), c(#"\arg"#, "arg"), c(#"\Pr"#, "Pr"),
        c(#"\bmod"#, "mod（二元）"),
        c(#"\pmod{}"#, "(mod n)"),
    ]

    // MARK: - 數學：關係

    private static let relations: [LatexCommand] = [
        c(#"\leq"#, "≤"), c(#"\geq"#, "≥"), c(#"\neq"#, "≠"),
        c(#"\le"#, "≤"), c(#"\ge"#, "≥"),
        c(#"\approx"#, "≈"), c(#"\equiv"#, "≡"), c(#"\sim"#, "∼"),
        c(#"\simeq"#, "≃"), c(#"\cong"#, "≅"), c(#"\propto"#, "∝"),
        c(#"\ll"#, "≪"), c(#"\gg"#, "≫"),
        c(#"\prec"#, "≺"), c(#"\succ"#, "≻"), c(#"\preceq"#, "⪯"), c(#"\succeq"#, "⪰"),
        c(#"\in"#, "∈"), c(#"\notin"#, "∉"), c(#"\ni"#, "∋"),
        c(#"\subset"#, "⊂"), c(#"\supset"#, "⊃"),
        c(#"\subseteq"#, "⊆"), c(#"\supseteq"#, "⊇"),
        c(#"\perp"#, "⊥"), c(#"\parallel"#, "∥"),
        c(#"\mid"#, "∣"), c(#"\nmid"#, "∤"),
        c(#"\models"#, "⊨"), c(#"\vdash"#, "⊢"),
        c(#"\doteq"#, "≐"), c(#"\asymp"#, "≍"),
    ]

    // MARK: - 數學：箭頭

    private static let arrows: [LatexCommand] = [
        c(#"\to"#, "→"), c(#"\rightarrow"#, "→"), c(#"\leftarrow"#, "←"),
        c(#"\leftrightarrow"#, "↔"),
        c(#"\Rightarrow"#, "⇒"), c(#"\Leftarrow"#, "⇐"), c(#"\Leftrightarrow"#, "⇔"),
        c(#"\implies"#, "⟹"), c(#"\impliedby"#, "⟸"), c(#"\iff"#, "⟺"),
        c(#"\mapsto"#, "↦"), c(#"\longmapsto"#, "⟼"),
        c(#"\longrightarrow"#, "⟶"), c(#"\longleftarrow"#, "⟵"),
        c(#"\hookrightarrow"#, "↪"), c(#"\hookleftarrow"#, "↩"),
        c(#"\uparrow"#, "↑"), c(#"\downarrow"#, "↓"), c(#"\updownarrow"#, "↕"),
        c(#"\nearrow"#, "↗"), c(#"\searrow"#, "↘"),
        c(#"\nwarrow"#, "↖"), c(#"\swarrow"#, "↙"),
        c(#"\rightleftharpoons"#, "⇌"),
    ]

    // MARK: - 數學：二元運算

    private static let binaryOperators: [LatexCommand] = [
        c(#"\times"#, "×"), c(#"\cdot"#, "⋅"), c(#"\div"#, "÷"),
        c(#"\pm"#, "±"), c(#"\mp"#, "∓"),
        c(#"\ast"#, "∗"), c(#"\star"#, "⋆"), c(#"\circ"#, "∘"), c(#"\bullet"#, "∙"),
        c(#"\oplus"#, "⊕"), c(#"\ominus"#, "⊖"), c(#"\otimes"#, "⊗"), c(#"\odot"#, "⊙"),
        c(#"\wedge"#, "∧"), c(#"\vee"#, "∨"),
        c(#"\cup"#, "∪"), c(#"\cap"#, "∩"), c(#"\setminus"#, "∖"),
        c(#"\dagger"#, "†"), c(#"\ddagger"#, "‡"),
    ]

    // MARK: - 數學：其他符號

    private static let symbols: [LatexCommand] = [
        c(#"\infty"#, "∞"), c(#"\partial"#, "∂"), c(#"\nabla"#, "∇"),
        c(#"\hbar"#, "ℏ"), c(#"\ell"#, "ℓ"),
        c(#"\Re"#, "ℜ"), c(#"\Im"#, "ℑ"), c(#"\aleph"#, "ℵ"),
        c(#"\emptyset"#, "∅"), c(#"\varnothing"#, "∅"),
        c(#"\forall"#, "∀"), c(#"\exists"#, "∃"), c(#"\nexists"#, "∄"),
        c(#"\neg"#, "¬"), c(#"\angle"#, "∠"), c(#"\triangle"#, "△"),
        c(#"\prime"#, "′"),
        c(#"\cdots"#, "⋯"), c(#"\vdots"#, "⋮"), c(#"\ddots"#, "⋱"), c(#"\dots"#, "…"),
        c(#"\checkmark"#, "✓"), c(#"\square"#, "□"), c(#"\blacksquare"#, "■"),
        c(#"\therefore"#, "∴"), c(#"\because"#, "∵"),
    ]

    // MARK: - 數學：括號

    private static let delimiters: [LatexCommand] = [
        c(#"\left("#, "自動大小 ("), c(#"\right)"#, "自動大小 )"),
        c(#"\left["#, "自動大小 ["), c(#"\right]"#, "自動大小 ]"),
        c(#"\left\{"#, "自動大小 {"), c(#"\right\}"#, "自動大小 }"),
        c(#"\left|"#, "自動大小 |"), c(#"\right|"#, "自動大小 |"),
        c(#"\left\langle"#, "自動大小 ⟨"), c(#"\right\rangle"#, "自動大小 ⟩"),
        c(#"\left."#, "看不見的左括號"), c(#"\right."#, "看不見的右括號"),
        c(#"\langle"#, "⟨"), c(#"\rangle"#, "⟩"),
        c(#"\lvert"#, "|"), c(#"\rvert"#, "|"),
        c(#"\lVert"#, "‖"), c(#"\rVert"#, "‖"),
        c(#"\lfloor"#, "⌊"), c(#"\rfloor"#, "⌋"),
        c(#"\lceil"#, "⌈"), c(#"\rceil"#, "⌉"),
        c(#"\big("#, "大一號 ("), c(#"\Big("#, "大兩號 ("),
        c(#"\bigg("#, "大三號 ("), c(#"\Bigg("#, "大四號 ("),
    ]

    // MARK: - 希臘字母

    private static let greek: [LatexCommand] = [
        c(#"\alpha"#, "α"), c(#"\beta"#, "β"), c(#"\gamma"#, "γ"), c(#"\delta"#, "δ"),
        c(#"\epsilon"#, "ϵ"), c(#"\varepsilon"#, "ε"), c(#"\zeta"#, "ζ"), c(#"\eta"#, "η"),
        c(#"\theta"#, "θ"), c(#"\vartheta"#, "ϑ"), c(#"\iota"#, "ι"), c(#"\kappa"#, "κ"),
        c(#"\lambda"#, "λ"), c(#"\mu"#, "μ"), c(#"\nu"#, "ν"), c(#"\xi"#, "ξ"),
        c(#"\pi"#, "π"), c(#"\varpi"#, "ϖ"), c(#"\rho"#, "ρ"), c(#"\varrho"#, "ϱ"),
        c(#"\sigma"#, "σ"), c(#"\varsigma"#, "ς"), c(#"\tau"#, "τ"), c(#"\upsilon"#, "υ"),
        c(#"\phi"#, "ϕ"), c(#"\varphi"#, "φ"), c(#"\chi"#, "χ"), c(#"\psi"#, "ψ"),
        c(#"\omega"#, "ω"),
        c(#"\Gamma"#, "Γ"), c(#"\Delta"#, "Δ"), c(#"\Theta"#, "Θ"), c(#"\Lambda"#, "Λ"),
        c(#"\Xi"#, "Ξ"), c(#"\Pi"#, "Π"), c(#"\Sigma"#, "Σ"), c(#"\Upsilon"#, "Υ"),
        c(#"\Phi"#, "Φ"), c(#"\Psi"#, "Ψ"), c(#"\Omega"#, "Ω"),
    ]

    // MARK: - physics／braket 套件

    private static let physics: [LatexCommand] = [
        c(#"\bra{}"#, "⟨ψ|（physics／braket）"),
        c(#"\ket{}"#, "|ψ⟩（physics／braket）"),
        c(#"\braket{}{}"#, "⟨φ|ψ⟩（physics）"),
        c(#"\ketbra{}{}"#, "|ψ⟩⟨φ|（physics）"),
        c(#"\expval{}"#, "⟨A⟩ 期望值（physics）"),
        c(#"\mel{}{}{}"#, "⟨φ|A|ψ⟩ 矩陣元（physics）"),
        c(#"\dv{}{}"#, "d/dx 導數（physics）"),
        c(#"\pdv{}{}"#, "∂/∂x 偏導數（physics）"),
        c(#"\abs{}"#, "|x| 絕對值（physics）"),
        c(#"\norm{}"#, "‖x‖ 範數（physics）"),
        c(#"\comm{}{}"#, "[A,B] 對易子（physics）"),
        c(#"\acomm{}{}"#, "{A,B} 反對易子（physics）"),
        c(#"\Tr"#, "Tr 跡（physics）"),
        c(#"\tr"#, "tr 跡（physics）"),
        c(#"\order{}"#, "𝒪(x)（physics）"),
        c(#"\qty()"#, "自動大小括號（physics）"),
        c(#"\eval{}_{}^{}"#, "代入上下限 |ₐᵇ（physics）"),
    ]

    // MARK: - 參數補全用的清單

    /// \usepackage{ 後面的套件名稱
    static let packages: [String] = [
        "amsmath", "amssymb", "amsthm", "mathtools", "physics", "braket", "bm",
        "graphicx", "xcolor", "hyperref", "cleveref", "geometry", "setspace",
        "xeCJK", "fontspec", "unicode-math", "microtype", "lmodern",
        "booktabs", "multirow", "array", "tabularx", "longtable", "makecell", "diagbox",
        "caption", "subcaption", "float", "wrapfig", "placeins", "adjustbox", "rotating",
        "tikz", "pgfplots", "tikz-feynman", "quantikz", "qcircuit",
        "siunitx", "natbib", "biblatex", "cite", "csquotes",
        "enumitem", "fancyhdr", "titlesec", "tocloft", "parskip", "indentfirst",
        "multicol", "lineno", "appendix", "authblk", "abstract", "titling",
        "listings", "minted", "verbatim", "fancyvrb",
        "algorithm", "algpseudocode", "algorithmic", "algorithm2e",
        "tcolorbox", "mdframed", "framed", "todonotes", "comment", "lipsum",
        "mathrsfs", "dsfont", "bbm", "esint", "cancel", "slashed", "tensor",
        "derivative", "diffcoeff", "empheq", "cases", "breqn", "nicefrac", "xfrac",
        "upgreek", "stmaryrd", "wasysym", "pifont", "textcomp", "gensymb",
        "soul", "ulem", "url", "xspace", "etoolbox", "xparse", "ifthen", "calc",
        "subfiles", "import", "standalone", "pdfpages", "bookmark", "glossaries",
        "inputenc", "fontenc", "babel", "ytableau", "youngtab", "mhchem", "chemformula",
    ]

    /// \documentclass{ 後面的文件類別
    static let documentClasses: [String] = [
        "article", "report", "book", "amsart", "amsbook",
        "revtex4-2", "revtex4-1", "beamer", "memoir",
        "scrartcl", "scrreprt", "scrbook", "elsarticle", "IEEEtran", "llncs",
        "ctexart", "ctexrep", "ctexbook", "standalone", "letter",
    ]

    // MARK: - 建構用

    private static func c(_ insert: String, _ detail: String) -> LatexCommand {
        LatexCommand(insert: insert, detail: detail, projectOnly: false)
    }

    private static func p(_ insert: String, _ detail: String) -> LatexCommand {
        LatexCommand(insert: insert, detail: detail, projectOnly: true)
    }
}
