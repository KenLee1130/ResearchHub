import math
FIELD, MARK = "#14514B", "#F1EEE4"

def plate(bg): return f'<rect x="100" y="100" width="824" height="824" rx="185" fill="{bg}"></rect>'

def arc(r, a0, a1, w, mk, cx=512, cy=512):
    p0 = (cx+r*math.cos(math.radians(a0)), cy+r*math.sin(math.radians(a0)))
    p1 = (cx+r*math.cos(math.radians(a1)), cy+r*math.sin(math.radians(a1)))
    large = 1 if (a1-a0) % 360 > 180 else 0
    return (f'<path d="M {p0[0]:.0f} {p0[1]:.0f} A {r} {r} 0 {large} 1 {p1[0]:.0f} {p1[1]:.0f}" '
            f'fill="none" stroke="{mk}" stroke-width="{w}" stroke-linecap="round"></path>')

def R(h, w, mk, cx=512, cy=512, bowl=0.52, leg=0.62):
    """用同一套筆畫造 R：直幹 ＋ 上半的碗（圓弧）＋ 斜腿。
    h=字高, w=筆畫粗細, bowl=碗往右凸出的比例, leg=腿往右伸的比例"""
    top, bot = cy - h/2, cy + h/2
    mid = cy                                  # 碗收在中線
    stem_x = cx - h*0.30
    bulge = h * bowl * 0.5                    # 碗的矢高
    c = (mid - top) / 2                       # 半弦
    r = (bulge*bulge + c*c) / (2*bulge)       # 由矢高反推半徑
    large = 1 if bulge > r else 0
    leg_x = stem_x + h*leg*0.55
    return (
        f'<g fill="none" stroke="{mk}" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round">'
        f'<path d="M {stem_x:.0f} {top:.0f} L {stem_x:.0f} {bot:.0f}"></path>'
        f'<path d="M {stem_x:.0f} {top:.0f} A {r:.0f} {r:.0f} 0 {large} 1 {stem_x:.0f} {mid:.0f}"></path>'
        f'<path d="M {stem_x + w*0.55:.0f} {mid - w*0.1:.0f} L {leg_x:.0f} {bot:.0f}"></path>'
        f'</g>')

def v1(bg=FIELD, mk=MARK):
    """雙開口弧 ＋ 中心 R"""
    return (plate(bg) + arc(268, -46, -134, 48, mk) + arc(196, 134, 46, 48, mk)
            + R(196, 46, mk))

def v2(bg=FIELD, mk=MARK):
    """三開口弧 ＋ 中心 R（R 縮小）"""
    return (plate(bg) + arc(286, -44, -136, 42, mk) + arc(224, 136, 44, 42, mk)
            + arc(164, -44, -136, 42, mk) + R(150, 40, mk))

def v3(bg=FIELD, mk=MARK):
    """單開口弧 ＋ 大 R（最乾淨）"""
    return plate(bg) + arc(272, -44, -136, 52, mk) + R(250, 54, mk)

def v4(bg=FIELD, mk=MARK):
    """雙弧但缺口同側 ＋ R：像被翻開的頁緣"""
    return (plate(bg) + arc(268, -40, -150, 48, mk) + arc(196, -40, -150, 48, mk)
            + R(188, 46, mk))

VARIANTS = [("V1 雙弧＋R", v1), ("V2 三弧＋R", v2), ("V3 單弧＋大R", v3), ("V4 同側雙弧＋R", v4)]
