import math
FIELD, MARK = "#14514B", "#F1EEE4"
CX = CY = 512
def plate(bg): return f'<rect x="100" y="100" width="824" height="824" rx="185" fill="{bg}"></rect>'

def arc(r, center_deg, gap_deg, w, mk):
    """以 center_deg 為缺口中心、開口 gap_deg 的同心弧"""
    a0 = center_deg + gap_deg/2
    a1 = center_deg - gap_deg/2
    p0=(CX+r*math.cos(math.radians(a0)), CY+r*math.sin(math.radians(a0)))
    p1=(CX+r*math.cos(math.radians(a1)), CY+r*math.sin(math.radians(a1)))
    large = 1 if (a1-a0) % 360 > 180 else 0
    return (f'<path d="M {p0[0]:.0f} {p0[1]:.0f} A {r} {r} 0 {large} 1 {p1[0]:.0f} {p1[1]:.0f}" '
            f'fill="none" stroke="{mk}" stroke-width="{w}" stroke-linecap="round"></path>')

W = 44
def u1(bg=FIELD, mk=MARK):
    """外環 ＋ 內層兩道同心弧（缺口依序旋轉）"""
    return (plate(bg)
            + arc(310, -90,  58, W, mk)      # 外環：開口在正上方
            + arc(196, 150, 100, W, mk)      # 內層外圈：開口在左下
            + arc(112, -20, 120, W, mk))     # 內層內圈：開口在右

def u2(bg=FIELD, mk=MARK):
    """u1 ＋ 中心一點"""
    return u1(bg, mk) + f'<circle cx="{CX}" cy="{CY}" r="26" fill="{mk}"></circle>'

def u3(bg=FIELD, mk=MARK):
    """內層兩弧缺口相對（180 度），對稱感最強"""
    return (plate(bg)
            + arc(310, -90, 58, W, mk)
            + arc(196, 120, 96, W, mk)
            + arc(112, -60, 96, W, mk))

def u4(bg=FIELD, mk=MARK):
    """內層兩弧靠得更近、外環與內層的留白更寬"""
    return (plate(bg)
            + arc(316, -90, 54, W, mk)
            + arc(174, 150, 104, W, mk)
            + arc(100, -30, 118, W, mk))

VARIANTS=[("U1 缺口依序旋轉",u1),("U2 ＋中心點",u2),
          ("U3 內層缺口相對",u3),("U4 留白更寬",u4)]
