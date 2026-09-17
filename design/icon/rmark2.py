import math
FIELD, MARK = "#14514B", "#F1EEE4"
def plate(bg): return f'<rect x="100" y="100" width="824" height="824" rx="185" fill="{bg}"></rect>'

def arc(r, a0, a1, w, mk, cx=512, cy=512):
    p0=(cx+r*math.cos(math.radians(a0)), cy+r*math.sin(math.radians(a0)))
    p1=(cx+r*math.cos(math.radians(a1)), cy+r*math.sin(math.radians(a1)))
    large = 1 if (a1-a0)%360>180 else 0
    return (f'<path d="M {p0[0]:.0f} {p0[1]:.0f} A {r} {r} 0 {large} 1 {p1[0]:.0f} {p1[1]:.0f}" '
            f'fill="none" stroke="{mk}" stroke-width="{w}" stroke-linecap="round"></path>')

def R(h, mk, cx=512, cy=512, style="a", bw=0.42, bowl_frac=0.52, legx=0.60, w=None):
    """碗用三次貝茲（比圓弧更像字，不會變氣球）；style 決定腿從哪裡長出來"""
    w = w if w else h*0.21
    top, bot = cy-h/2, cy+h/2
    mid = top + h*bowl_frac
    sx = cx - h*0.26
    bx = sx + h*bw                       # 碗最右
    ctrl = h*bw*1.34
    bowl = (f'M {sx:.0f} {top:.0f} C {sx+ctrl:.0f} {top:.0f} {sx+ctrl:.0f} {mid:.0f} {sx:.0f} {mid:.0f}')
    if style == "b":                     # 腿從碗的右緣落下
        leg = f'M {bx-w*0.15:.0f} {mid-h*0.06:.0f} L {sx+h*legx:.0f} {bot:.0f}'
    elif style == "c":                   # 腿從幹的接點斜出（古典）
        leg = f'M {sx+w*0.35:.0f} {mid-w*0.05:.0f} L {sx+h*legx:.0f} {bot:.0f}'
    else:                                # 腿與碗共用接點，略往右起
        leg = f'M {sx+h*0.16:.0f} {mid:.0f} L {sx+h*legx:.0f} {bot:.0f}'
    return (f'<g fill="none" stroke="{mk}" stroke-width="{w:.0f}" stroke-linecap="round" stroke-linejoin="round">'
            f'<path d="M {sx:.0f} {top:.0f} L {sx:.0f} {bot:.0f}"></path>'
            f'<path d="{bowl}"></path><path d="{leg}"></path></g>')

def framed(style, bg=FIELD, mk=MARK, arcs=2, **kw):
    out = plate(bg)
    if arcs >= 1: out += arc(268, -46, -134, 48, mk)
    if arcs >= 2: out += arc(196, 134, 46, 48, mk)
    return out + R(196 if arcs == 2 else 250, mk, style=style, **kw)

VARIANTS = [
    ("Ra 接點起腿", lambda **k: framed("a", **k)),
    ("Rb 碗緣起腿", lambda **k: framed("b", **k)),
    ("Rc 古典斜腿", lambda **k: framed("c", **k)),
    ("Rb 單弧大R", lambda **k: framed("b", arcs=1, **k)),
    ("Rb 無弧",    lambda bg=FIELD, mk=MARK: plate(bg) + R(300, mk, style="b")),
]
