import math
FIELD, MARK = "#14514B", "#F1EEE4"
CX = CY = 512
def plate(bg): return f'<rect x="100" y="100" width="824" height="824" rx="185" fill="{bg}"></rect>'

def arc(r, a0, a1, w, mk):
    """a0 → a1 順時針"""
    p0=(CX+r*math.cos(math.radians(a0)), CY+r*math.sin(math.radians(a0)))
    p1=(CX+r*math.cos(math.radians(a1)), CY+r*math.sin(math.radians(a1)))
    large = 1 if (a1-a0) % 360 > 180 else 0
    return (f'<path d="M {p0[0]:.0f} {p0[1]:.0f} A {r} {r} 0 {large} 1 {p1[0]:.0f} {p1[1]:.0f}" '
            f'fill="none" stroke="{mk}" stroke-width="{w}" stroke-linecap="round"></path>')

def outer(w=44, mk=MARK, r=310, gap=58):
    """外環：接近滿圓，開口在正上方"""
    return arc(r, -90 + gap/2, -90 - gap/2, w, mk)

def coil(u0, u1, w, mk, r_out=205, r_in=46, turns=1.7, th0=210, n=90):
    """內螺旋的一段：u 由 0（外）到 1（內）"""
    pts=[]
    for i in range(n+1):
        u = u0 + (u1-u0)*i/n
        r = r_out - (r_out-r_in)*u
        th = math.radians(th0 + turns*360*u)
        pts.append(f"{CX+r*math.cos(th):.1f} {CY+r*math.sin(th):.1f}")
    return (f'<path d="M {" L ".join(pts)}" fill="none" stroke="{mk}" stroke-width="{w}" '
            f'stroke-linecap="round" stroke-linejoin="round"></path>')

def t1(bg=FIELD, mk=MARK):
    """外環 ＋ 完整內螺旋"""
    return plate(bg) + outer(mk=mk) + coil(0, 1, 44, mk)

def t2(bg=FIELD, mk=MARK):
    """外環 ＋ 斷開的內螺旋（兩道缺口）——最接近平板稿"""
    return (plate(bg) + outer(mk=mk)
            + coil(0.00, 0.42, 44, mk) + coil(0.52, 0.88, 44, mk) + coil(0.96, 1.0, 44, mk))

def t3(bg=FIELD, mk=MARK):
    """t2 ＋ 右下那截獨立的弧"""
    return t2(bg, mk) + arc(238, 34, 92, 44, mk)

def t4(bg=FIELD, mk=MARK):
    """外環 ＋ 內螺旋由外而內漸細"""
    out = plate(bg) + outer(mk=mk)
    n=6
    for i in range(n):
        u0, u1 = i/n, (i+1)/n
        out += coil(u0, min(1.0, u1+0.004), 46-16*u0, mk)
    return out

VARIANTS=[("T1 外環＋完整螺旋",t1),("T2 外環＋斷開螺旋",t2),
          ("T3 ＋右下獨立弧",t3),("T4 螺旋漸細",t4)]
