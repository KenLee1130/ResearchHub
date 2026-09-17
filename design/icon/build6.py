exec(open('spec.py').read())
TPL = '''<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
  <style>
    body {{ margin: 0; font-family: "Helvetica Neue", "PingFang TC", system-ui, sans-serif; }}
    a {{ color: #14514B; }} a:hover {{ color: #0B3833; }}
  </style>
</helmet>
<div style="display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 26px; width: 520px; height: 540px; background: #EDEEF0; box-sizing: border-box; padding: 40px">
  <svg width="340" height="340" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">{svg}</svg>
  <div style="display: flex; flex-direction: column; align-items: center; gap: 6px">
    <div style="font-size: 17px; font-weight: 600; color: #1C1F23">{title}</div>
    <div style="font-size: 13px; color: #5B6167; text-align: center; max-width: 350px; line-height: 1.5; text-wrap: pretty">{desc}</div>
  </div>
</div>
</x-dc>
<script data-dc-script data-props='{{"mark":{{"editor":"color","default":"#F1EEE4","options":["#F1EEE4","#FFFFFF","#8CE8CE","#FFD79A"]}},"field":{{"editor":"color","default":"#14514B","options":["#14514B","#1B2E52","#3B2A4A","#2A2A2E"]}}}}'>
class Component extends DCLogic {{
  renderVals() {{
    return {{
      mark: this.props.mark ?? '#F1EEE4',
      field: this.props.field ?? '#14514B'
    }};
  }}
}}
</script>
</body>
</html>
'''
specs = [
 ("Main.dc.html", v_a, "A・筆畫 44",
  "半徑 310 / 196 / 105，筆畫 44。角度完全照規格：外環缺口 70–110，第二環 35→270 與 300→330，第三環 90→180。"),
 ("VariantB.dc.html", v_b, "B・筆畫 52",
  "同半徑但筆畫加粗到 52。份量更足、遠看更清楚；環與環之間的縫隙相對變窄。"),
 ("VariantC.dc.html", v_c, "C・筆畫 38 ＋外擴",
  "筆畫收到 38，三環半徑各往外推一點（316 / 206 / 112）。最秀氣、縫隙最開；16px 會偏細。"),
 ("VariantD.dc.html", v_d, "D・內層更小",
  "外環 300，第二、三環縮到 180 / 88，筆畫 48。內層更集中，外環與內層的對比最強。"),
]
for fn, mk, title, desc in specs:
    open(fn,'w').write(TPL.format(svg=mk(bg="{{field}}", mk="{{mark}}"), title=title, desc=desc))
    print("wrote", fn)

def sym(sid, fn): return f'      <symbol id="{sid}" viewBox="0 0 1024 1024">{fn()}</symbol>'
syms = "\n".join([sym("icoA", v_a), sym("icoB", v_b), sym("icoC", v_c), sym("icoD", v_d)])
cells=[]
for label,sid in [("A・筆畫 44","icoA"),("B・筆畫 52","icoB"),("C・筆畫 38","icoC"),("D・內層更小","icoD")]:
    cells.append(f'    <div class="lbl">{label}</div>')
    for s in (128,64,32,16):
        cells.append(f'    <div class="cell"><svg width="{s}" height="{s}"><use href="#{sid}"></use></svg></div>')
SIZE='''<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
  <style>
    body { margin: 0; font-family: "Helvetica Neue", "PingFang TC", system-ui, sans-serif; }
    a { color: #14514B; } a:hover { color: #0B3833; }
    .cell { display: flex; align-items: center; justify-content: center; }
    .lbl { font-size: 14px; font-weight: 600; color: #1C1F23; }
    .hdr { font-size: 12px; color: #6B7178; letter-spacing: 0.04em; }
  </style>
</helmet>
<div style="width: 760px; height: 700px; background: #EDEEF0; box-sizing: border-box; padding: 36px 40px; display: flex; flex-direction: column; gap: 20px">
  <div style="display: flex; flex-direction: column; gap: 4px">
    <div style="font-size: 18px; font-weight: 600; color: #1C1F23">實際顯示尺寸</div>
    <div style="font-size: 13px; color: #5B6167; line-height: 1.5; text-wrap: pretty">四個版本角度相同，只差筆畫粗細與半徑。看 32px 與 16px：環之間的縫隙會不會糊掉。</div>
  </div>
  <svg width="0" height="0" style="position: absolute" aria-hidden="true">
    <defs>
__SYMS__
    </defs>
  </svg>
  <div style="display: grid; grid-template-columns: 170px 150px 110px 90px 80px; gap: 16px; align-items: center">
    <div class="hdr"></div>
    <div class="hdr cell">128</div>
    <div class="hdr cell">64</div>
    <div class="hdr cell">32</div>
    <div class="hdr cell">16</div>
__CELLS__
  </div>
</div>
</x-dc>
</body>
</html>
'''
open('SizeCheck.dc.html','w').write(SIZE.replace("__SYMS__",syms).replace("__CELLS__","\n".join(cells)))
print("wrote SizeCheck.dc.html")
