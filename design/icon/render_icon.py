from PIL import Image, ImageDraw
import math

FIELD = (0x14, 0x51, 0x4B)
MARK  = (0xF1, 0xEE, 0xE4)

# 定案規格（數學慣例：0°＝正右、逆時鐘為正）
W   = 60
ARCS = [                       # (r, th0, th1, clockwise?)
    (300, 130,  50, False),    # 外環
    (200,  35, 250, False),    # 第二環 第一部分
    (180, 300, 320, False),    # 第二環 第二部分
    ( 85,  60, 225, True),     # 第三環
]

def draw_mark(d, cx, cy, scale, w, arcs):
    """PIL 角度由 3 點鐘起、順時鐘遞增；數學角 θ 對應 PIL 角 -θ"""
    for r, t0, t1, cw in arcs:
        R = r * scale
        # PIL 的 arc 粗細由外緣往內長，包圍盒要往外推半個筆畫寬，
        # 弧線才會以半徑 R 為中心（圓端也才對得上）
        Ro = R + w/2
        box = [cx - Ro, cy - Ro, cx + Ro, cy + Ro]
        if cw:
            s, e = (-t0) % 360, (-t1) % 360
        else:
            s, e = (-t1) % 360, (-t0) % 360
        d.arc(box, s, e, fill=MARK, width=int(round(w)))
        for t in (t0, t1):                     # 圓端
            x = cx + R*math.cos(math.radians(t))
            y = cy - R*math.sin(math.radians(t))
            d.ellipse([x-w/2, y-w/2, x+w/2, y+w/2], fill=MARK)

def render(size, full_bleed=False, ss=4):
    """full_bleed=True 給 iOS（滿版、不透明、不畫圓角）；否則 macOS 圓角方塊＋邊距"""
    C = size * ss
    img = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if full_bleed:
        d.rectangle([0, 0, C, C], fill=FIELD + (255,))
        scale = C / 1024 * (1024 / 824)        # 記號對「圓角方塊」維持同比例
        cx = cy = C / 2
    else:
        u = C / 1024
        d.rounded_rectangle([100*u, 100*u, 924*u, 924*u], radius=185*u, fill=FIELD + (255,))
        scale = u
        cx = cy = C / 2
    draw_mark(d, cx, cy, scale, W * scale, ARCS)
    out = img.resize((size, size), Image.LANCZOS)
    if full_bleed:
        out = out.convert("RGB")               # iOS 不接受 alpha
    return out

if __name__ == "__main__":
    import sys
    if "--check" in sys.argv:
        sheet = Image.new("RGB", (820, 300), (0xED, 0xEE, 0xF0))
        x = 24
        for s in (256, 128, 64, 32, 16):
            im = render(s)
            sheet.paste(im, (x, (300 - s)//2), im)
            x += s + 28
        ios = render(180, full_bleed=True)
        sheet.paste(ios, (x + 20, (300-180)//2))
        sheet.save("icon_check.png")
        print("wrote icon_check.png")
