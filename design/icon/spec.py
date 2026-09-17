import math
FIELD, MARK = "#14514B", "#F1EEE4"
CX = CY = 512
def plate(bg): return f'<rect x="100" y="100" width="824" height="824" rx="185" fill="{bg}"></rect>'

def P(r, th):
    """數學慣例：0°＝正右、逆時鐘為正。SVG 的 y 向下，所以 sin 取負"""
    return (CX + r*math.cos(math.radians(th)), CY - r*math.sin(math.radians(th)))

def ccw(r, th0, th1, w, mk):
    """從 th0 逆時鐘畫到 th1"""
    p0, p1 = P(r, th0), P(r, th1)
    sweep = (th1 - th0) % 360
    large = 1 if sweep > 180 else 0
    return (f'<path d="M {p0[0]:.1f} {p0[1]:.1f} A {r} {r} 0 {large} 0 {p1[0]:.1f} {p1[1]:.1f}" '
            f'fill="none" stroke="{mk}" stroke-width="{w}" stroke-linecap="round"></path>')

def mark(bg=FIELD, mk=MARK, r1=310, r2=196, r3=105, w=44):
    return (plate(bg)
        + ccw(r1, 110, 70,  w, mk)    # 外環：缺口 70–110（正上）
        + ccw(r2, 35, 270,  w, mk)    # 第二環 第一部分
        + ccw(r2, 300, 330, w, mk)    # 第二環 第二部分
        + ccw(r3, 90, 180,  w, mk))   # 第三環

def v_a(bg=FIELD, mk=MARK): return mark(bg, mk)
def v_b(bg=FIELD, mk=MARK): return mark(bg, mk, r1=310, r2=196, r3=105, w=52)
def v_c(bg=FIELD, mk=MARK): return mark(bg, mk, r1=316, r2=206, r3=112, w=38)
def v_d(bg=FIELD, mk=MARK): return mark(bg, mk, r1=300, r2=180, r3=88,  w=48)

VARIANTS=[("A 筆畫 44",v_a),("B 筆畫 52（粗）",v_b),
          ("C 筆畫 38（細）＋外擴",v_c),("D 內層更小",v_d)]
