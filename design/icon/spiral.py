import math
FIELD, MARK = "#14514B", "#F1EEE4"
def plate(bg): return f'<rect x="100" y="100" width="824" height="824" rx="185" fill="{bg}"></rect>'

def spiral_path(turns=2.4, r0=54, r1=272, start=-95, cx=512, cy=512, n=320):
    pts=[]
    for i in range(n+1):
        t=i/n
        th=math.radians(start)+t*turns*2*math.pi
        r=r0+(r1-r0)*t
        pts.append(f"{cx+r*math.cos(th):.1f} {cy+r*math.sin(th):.1f}")
    return "M " + " L ".join(pts)

def s1(bg=FIELD, mk=MARK):
    """連續螺旋：一筆到底，等粗"""
    return (plate(bg) + f'<path d="{spiral_path()}" fill="none" stroke="{mk}" '
            f'stroke-width="54" stroke-linecap="round" stroke-linejoin="round"></path>')

def s2(bg=FIELD, mk=MARK):
    """分段螺旋：四段圓端弧，半徑遞減、缺口依序旋轉（最接近手稿）"""
    segs=[(268,-52,168),(198,120,-20),(132,-64,150),(72,110,-40)]
    out=plate(bg)
    for r,a0,a1 in segs:
        p0=(512+r*math.cos(math.radians(a0)),512+r*math.sin(math.radians(a0)))
        p1=(512+r*math.cos(math.radians(a1)),512+r*math.sin(math.radians(a1)))
        large=1 if (a1-a0)%360>180 else 0
        out+=(f'<path d="M {p0[0]:.0f} {p0[1]:.0f} A {r} {r} 0 {large} 1 {p1[0]:.0f} {p1[1]:.0f}" '
              f'fill="none" stroke="{mk}" stroke-width="50" stroke-linecap="round"></path>')
    return out

def s3(bg=FIELD, mk=MARK):
    """連續螺旋但筆畫由外而內變細＝有速度感"""
    out=plate(bg); n=7
    for i in range(n):
        t0,t1=i/n,(i+1)/n
        sub=[]
        for k in range(41):
            t=t0+(t1-t0)*k/40
            th=math.radians(-95)+t*2.4*2*math.pi
            r=54+(272-54)*t
            sub.append(f"{512+r*math.cos(th):.1f} {512+r*math.sin(th):.1f}")
        w=58-34*(1-t0)
        out+=(f'<path d="M {" L ".join(sub)}" fill="none" stroke="{mk}" '
              f'stroke-width="{w:.0f}" stroke-linecap="round" stroke-linejoin="round"></path>')
    return out

def s4(bg=FIELD, mk=MARK):
    """分段螺旋 ＋ 中心實心點"""
    return s2(bg,mk)+f'<circle cx="512" cy="512" r="30" fill="{mk}"></circle>'

VARIANTS=[("S1 連續螺旋",s1),("S2 分段螺旋",s2),("S3 漸細螺旋",s3),("S4 分段＋中心點",s4)]

def s5(bg=FIELD, mk=MARK):
    """螺旋外兩圈 ＋ 中心收成 R"""
    out = plate(bg)
    for r,a0,a1,w in [(272,-56,150,50),(196,128,-26,50)]:
        p0=(512+r*math.cos(math.radians(a0)),512+r*math.sin(math.radians(a0)))
        p1=(512+r*math.cos(math.radians(a1)),512+r*math.sin(math.radians(a1)))
        large=1 if (a1-a0)%360>180 else 0
        out+=(f'<path d="M {p0[0]:.0f} {p0[1]:.0f} A {r} {r} 0 {large} 1 {p1[0]:.0f} {p1[1]:.0f}" '
              f'fill="none" stroke="{mk}" stroke-width="{w}" stroke-linecap="round"></path>')
    h, w = 176, 40
    top, bot = 512-h/2, 512+h/2
    mid = top + h*0.52
    sx = 512 - h*0.26
    ctrl = h*0.42*1.34
    out += (f'<g fill="none" stroke="{mk}" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round">'
            f'<path d="M {sx:.0f} {top:.0f} L {sx:.0f} {bot:.0f}"></path>'
            f'<path d="M {sx:.0f} {top:.0f} C {sx+ctrl:.0f} {top:.0f} {sx+ctrl:.0f} {mid:.0f} {sx:.0f} {mid:.0f}"></path>'
            f'<path d="M {sx+h*0.16:.0f} {mid:.0f} L {sx+h*0.60:.0f} {bot:.0f}"></path></g>')
    return out
