exec(open('flat.py').read())
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
<div style="display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 28px; width: 520px; height: 540px; background: #EDEEF0; box-sizing: border-box; padding: 40px">
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
 ("Main.dc.html", m5, "A・雙開口弧",
  "內外兩道開口弧，缺口相對，中心一點。放射節奏最強、最像一個「記號」而不是一張圖；意義開放（專注／聚焦／軌道）。"),
 ("VariantB.dc.html", m6, "B・三開口弧",
  "同一個想法推到三層，缺口依序旋轉。層次更豐富、更有動勢；16px 時最內圈會開始融掉。"),
 ("VariantC.dc.html", m4, "C・圓盤負空間",
  "實心圓盤挖兩道橫槽＝鏡片下的筆記行。剪影最實、對比最高，遠遠就看得到；語意最接近「筆記」。"),
 ("VariantD.dc.html", m1, "D・軌道",
  "細環加環上一顆點，兩個元素。最安靜克制；代價是在小尺寸容易被看成電源鍵。"),
]
for fn, mk, title, desc in specs:
    open(fn,'w').write(TPL.format(svg=mk(bg="{{field}}", mk="{{mark}}"), title=title, desc=desc))
    print("wrote", fn)

def sym(sid, fn):
    return f'      <symbol id="{sid}" viewBox="0 0 1024 1024">{fn()}</symbol>'
syms = "\n".join([sym("icoA", m5), sym("icoB", m6), sym("icoC", m4), sym("icoD", m1)])
cells=[]
for label,sid in [("A・雙開口弧","icoA"),("B・三開口弧","icoB"),("C・圓盤負空間","icoC"),("D・軌道","icoD")]:
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
    <div style="font-size: 13px; color: #5B6167; line-height: 1.5; text-wrap: pretty">全平面、無漸層、無光澤——Claude／Spotify／Slack 的共通規則。記號只佔畫面約一半，四周留白。</div>
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
