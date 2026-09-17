exec(open('spiral.py').read())
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
 ("Main.dc.html", s3, "A・漸細螺旋",
  "一筆到底，由外而內逐漸變細。有方向、有速度感，收尾乾淨；小尺寸表現最好——我的推薦。"),
 ("VariantB.dc.html", s1, "B・等粗螺旋",
  "同樣一筆到底但筆畫等粗，更沉穩、更像一個印記。比 A 安靜，少了那點動勢。"),
 ("VariantC.dc.html", s2, "C・分段螺旋",
  "四段圓端弧、缺口依序旋轉——最接近你手稿的節奏與呼吸感。大尺寸最有個性；32px 以下段落會開始互相干擾。"),
 ("VariantD.dc.html", s5, "D・螺旋＋中心 R",
  "外兩圈維持螺旋，中心收成一個同粗細筆畫造的 R。多了明確的識別；但也多了一個要讀的東西，16px 時 R 會糊掉。"),
]
for fn, mk, title, desc in specs:
    open(fn,'w').write(TPL.format(svg=mk(bg="{{field}}", mk="{{mark}}"), title=title, desc=desc))
    print("wrote", fn)

def sym(sid, fn): return f'      <symbol id="{sid}" viewBox="0 0 1024 1024">{fn()}</symbol>'
syms = "\n".join([sym("icoA", s3), sym("icoB", s1), sym("icoC", s2), sym("icoD", s5)])
cells=[]
for label,sid in [("A・漸細螺旋","icoA"),("B・等粗螺旋","icoB"),("C・分段螺旋","icoC"),("D・螺旋＋R","icoD")]:
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
    <div style="font-size: 13px; color: #5B6167; line-height: 1.5; text-wrap: pretty">看的是 32px 與 16px：螺旋的圈與圈之間會不會黏在一起。</div>
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
