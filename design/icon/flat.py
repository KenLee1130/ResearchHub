import math
# 參照 Claude／Spotify／Slack 的共通點：全平面、置中記號、放射構圖、粗筆圓端、元素 1–4 個。
# 這批刻意把記號縮到約畫面一半，四周留白（上一版最大的毛病就是塞太滿）。
FIELD, MARK = "#14514B", "#F1EEE4"

def plate(bg): return f'<rect x="100" y="100" width="824" height="824" rx="185" fill="{bg}"></rect>'

def m1(bg=FIELD, mk=MARK):
    """軌道：細環 ＋ 環上一顆實心點。兩個元素，最安靜"""
    return (plate(bg)
        + f'<circle cx="512" cy="512" r="196" fill="none" stroke="{mk}" stroke-width="40"></circle>'
        + f'<circle cx="512" cy="316" r="74" fill="{mk}"></circle>')

def m2(bg=FIELD, mk=MARK):
    """大缺口環：只有一個 C 形，缺口開在右上"""
    a0, a1 = math.radians(-52), math.radians(-128)
    r = 200
    p0 = (512+r*math.cos(a0), 512+r*math.sin(a0))
    p1 = (512+r*math.cos(a1), 512+r*math.sin(a1))
    return (plate(bg)
        + f'<path d="M {p0[0]:.0f} {p0[1]:.0f} A {r} {r} 0 1 1 {p1[0]:.0f} {p1[1]:.0f}" '
          f'fill="none" stroke="{mk}" stroke-width="76" stroke-linecap="round"></path>')

def m3(bg=FIELD, mk=MARK):
    """匯聚：四根粗棒從四方指向中心、留出十字負空間＝hub"""
    bars = []
    for ang in (0, 90, 180, 270):
        bars.append(f'<g transform="rotate({ang} 512 512)">'
                    f'<rect x="482" y="286" width="60" height="150" rx="30" fill="{mk}"></rect></g>')
    return plate(bg) + "".join(bars) + f'<circle cx="512" cy="512" r="46" fill="{mk}"></circle>'

def m4(bg=FIELD, mk=MARK):
    """圓盤＋負空間橫槽：實心圓挖兩道槽＝鏡片下的筆記行"""
    slots = "".join(
        f'<rect x="280" y="{y-22}" width="464" height="44" rx="22" fill="{bg}"></rect>'
        for y in (466, 558))
    return plate(bg) + f'<circle cx="512" cy="512" r="208" fill="{mk}"></circle>' + slots

def m5(bg=FIELD, mk=MARK):
    """雙環：內外兩道開口弧，缺口相對＝放射節奏"""
    def arc(r, a0, a1, w):
        p0 = (512+r*math.cos(math.radians(a0)), 512+r*math.sin(math.radians(a0)))
        p1 = (512+r*math.cos(math.radians(a1)), 512+r*math.sin(math.radians(a1)))
        large = 1 if (a1-a0) % 360 > 180 else 0
        return (f'<path d="M {p0[0]:.0f} {p0[1]:.0f} A {r} {r} 0 {large} 1 {p1[0]:.0f} {p1[1]:.0f}" '
                f'fill="none" stroke="{mk}" stroke-width="{w}" stroke-linecap="round"></path>')
    return plate(bg) + arc(214, -50, -130, 54) + arc(112, 130, 50, 54) + f'<circle cx="512" cy="512" r="32" fill="{mk}"></circle>'

VARIANTS = [("M1 軌道", m1), ("M2 大缺口環", m2), ("M3 匯聚 hub", m3),
            ("M4 圓盤負空間", m4), ("M5 雙開口弧", m5)]

def m6(bg=FIELD, mk=MARK):
    """三道同心開口弧：缺口依序旋轉，放射節奏最強"""
    def arc(r, a0, a1, w):
        p0 = (512+r*math.cos(math.radians(a0)), 512+r*math.sin(math.radians(a0)))
        p1 = (512+r*math.cos(math.radians(a1)), 512+r*math.sin(math.radians(a1)))
        large = 1 if (a1-a0) % 360 > 180 else 0
        return (f'<path d="M {p0[0]:.0f} {p0[1]:.0f} A {r} {r} 0 {large} 1 {p1[0]:.0f} {p1[1]:.0f}" '
                f'fill="none" stroke="{mk}" stroke-width="{w}" stroke-linecap="round"></path>')
    return (plate(bg) + arc(228, -46, -134, 50) + arc(150, 74, -14, 50)
            + arc(72, -166, 106, 50))
