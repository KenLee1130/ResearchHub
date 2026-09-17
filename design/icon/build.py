exec(open('gen.py').read())
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
    a {{ color: #0E5350; }} a:hover {{ color: #08312F; }}
  </style>
</helmet>
<div style="display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 28px; width: 520px; height: 560px; background: #EDEEF0; box-sizing: border-box; padding: 40px">
  <svg width="380" height="380" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg" style="filter: drop-shadow(0 12px 28px rgba(0,0,0,0.28))">
{svg}
  </svg>
  <div style="display: flex; flex-direction: column; align-items: center; gap: 6px">
    <div style="font-size: 17px; font-weight: 600; color: #1C1F23">{title}</div>
    <div style="font-size: 13px; color: #5B6167; text-align: center; max-width: 350px; line-height: 1.5; text-wrap: pretty">{desc}</div>
  </div>
</div>
</x-dc>
<script data-dc-script data-props='{{"accent":{{"editor":"color","default":"#8BE8CE","options":["#8BE8CE","#7FD1FF","#F2C879","#C9A7F5"]}},"bg":{{"editor":"color","default":"#0E5350","options":["#0E5350","#123A63","#3A2E5C","#1F3A2E"]}}}}'>
class Component extends DCLogic {{
  renderVals() {{
    return {{
      accent: this.props.accent ?? '#8BE8CE',
      bg: this.props.bg ?? '#0E5350'
    }};
  }}
}}
</script>
</body>
</html>
'''
specs = [
 ("Main.dc.html","a",dict(ys=(404,512,620)),"A・三條・折射",
  "底圖是等距的直條紋，穿過鏡片時被往外撐開並微微弓起——鏡緣的錯位就是「這是一片透鏡」的全部證據，不需要手把。白球改成乾淨的平面白加柔和落影。"),
 ("VariantB.dc.html","b",dict(ys=(448,576)),"B・兩條・折射",
  "只留兩條。留白更多、折射的弧線更清楚，小尺寸不會黏在一起——三條與兩條的差別主要在密度。"),
 ("VariantC.dc.html","c",dict(empty=True),"C・空鏡片",
  "中間什麼都不放，只留玻璃本身的高光與邊緣反光。最安靜、最像一顆鏡片；代價是沒有「筆記」的線索。"),
]
def sym(sid,p,**kw):
    return f'      <symbol id="{sid}" viewBox="0 0 1024 1024">\n{icon_svg(p, bg="#0E5350", accent="#8BE8CE", **kw)}\n      </symbol>'
syms = "\n".join([sym("icoA","sa",ys=(404,512,620)),
                  sym("icoB","sb",ys=(448,576)),
                  sym("icoC","sc",empty=True)])
cells=[]
for label,sid in [("A・三條・折射","icoA"),("B・兩條・折射","icoB"),("C・空鏡片","icoC")]:
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
    a { color: #0E5350; } a:hover { color: #08312F; }
    .cell { display: flex; align-items: center; justify-content: center; }
    .lbl { font-size: 14px; font-weight: 600; color: #1C1F23; }
    .hdr { font-size: 12px; color: #6B7178; letter-spacing: 0.04em; }
  </style>
</helmet>
<div style="width: 760px; height: 620px; background: #EDEEF0; box-sizing: border-box; padding: 36px 40px; display: flex; flex-direction: column; gap: 20px">
  <div style="display: flex; flex-direction: column; gap: 4px">
    <div style="font-size: 18px; font-weight: 600; color: #1C1F23">實際顯示尺寸</div>
    <div style="font-size: 13px; color: #5B6167; line-height: 1.5; text-wrap: pretty">Dock 約 64–128px，Spotlight 與選單列只有 16–32px。這裡看的是：條紋會不會黏成一團、鏡框的開口還在不在。</div>
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
