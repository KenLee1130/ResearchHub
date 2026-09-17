exec(open('conc.py').read())
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
 ("Main.dc.html", u1, "A・缺口依序旋轉",
  "三層同心：外環開口在正上方、中間留一整圈白、內層兩道同心弧。三個缺口依序旋轉（上→左下→右），繞一圈才回來。"),
 ("VariantB.dc.html", u2, "B・＋中心點",
  "同 A，中心補一個實心點收住視線。三層之外多一個落點，構圖更穩；也更接近你手稿中心那一小塊。"),
 ("VariantC.dc.html", u3, "C・內層缺口相對",
  "內層兩道弧的缺口差 180 度，對稱感最強、最像一枚徽章。少了 A 那種一路轉下去的動勢。"),
 ("VariantD.dc.html", u4, "D・留白更寬",
  "內層整體再縮小，外環與內層之間的空白更寬。三層的分層最清楚，小尺寸也最不會黏；代價是中心稍微空。"),
]
for fn, mk, title, desc in specs:
    open(fn,'w').write(TPL.format(svg=mk(bg="{{field}}", mk="{{mark}}"), title=title, desc=desc))
    print("wrote", fn)

def sym(sid, fn): return f'      <symbol id="{sid}" viewBox="0 0 1024 1024">{fn()}</symbol>'
syms = "\n".join([sym("icoA", u1), sym("icoB", u2), sym("icoC", u3), sym("icoD", u4)])
cells=[]
for label,sid in [("A・缺口旋轉","icoA"),("B・＋中心點","icoB"),("C・缺口相對","icoC"),("D・留白更寬","icoD")]:
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
    <div style="font-size: 13px; color: #5B6167; line-height: 1.5; text-wrap: pretty">看的是 32px 與 16px：三層之間的兩道留白還在不在——那是這個記號的骨架。</div>
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
