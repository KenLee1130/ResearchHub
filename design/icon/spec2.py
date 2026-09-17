import math
FIELD, MARK = "#14514B", "#F1EEE4"
CX = CY = 512
def plate(bg): return f'<rect x="100" y="100" width="824" height="824" rx="185" fill="{bg}"></rect>'
def P(r, th): return (CX + r*math.cos(math.radians(th)), CY - r*math.sin(math.radians(th)))

def arcd(r, th0, th1, w, mk, cw=False):
    """cw=False 逆時鐘、True 順時鐘（角度用數學慣例：0°正右、逆時鐘為正）"""
    p0, p1 = P(r, th0), P(r, th1)
    sweep = (th0 - th1) % 360 if cw else (th1 - th0) % 360
    large = 1 if sweep > 180 else 0
    flag = 1 if cw else 0          # SVG y 向下：sweep-flag 1 = 順時鐘
    return (f'<path d="M {p0[0]:.1f} {p0[1]:.1f} A {r} {r} 0 {large} {flag} {p1[0]:.1f} {p1[1]:.1f}" '
            f'fill="none" stroke="{mk}" stroke-width="{w}" stroke-linecap="round"></path>')

def mark(bg=FIELD, mk=MARK, r1=310, r2=202, r2b=160, r3=96, w=56):
    return (plate(bg)
        + arcd(r1, 120, 60,  w, mk)            # 外環：缺口 60–120
        + arcd(r2, 35, 250,  w, mk)            # 第二環 第一部分
        + arcd(r2b, 300, 330, w, mk)           # 第二環 第二部分（半徑落在二、三環之間偏外）
        + arcd(r3, 90, 180,  w, mk, cw=True))  # 第三環：順時鐘 90→180（270° 長弧）

def e1(bg=FIELD, mk=MARK): return mark(bg, mk, w=52)
def e2(bg=FIELD, mk=MARK): return mark(bg, mk, w=56)
def e3(bg=FIELD, mk=MARK): return mark(bg, mk, r1=312, r2=206, r2b=166, r3=90, w=60)
def e4(bg=FIELD, mk=MARK): return mark(bg, mk, r1=308, r2=200, r2b=168, r3=104, w=56)

VARIANTS=[("E1 筆畫 52",e1),("E2 筆畫 56",e2),
          ("E3 筆畫 60（最粗）",e3),("E4 筆畫 56・第二部分外移",e4)]
