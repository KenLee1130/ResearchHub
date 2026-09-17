# 環＝放大鏡鏡框。底圖有幾條淡淡的條紋，穿過鏡片時被「折射」：
# 往外撐開（放大）＋ 微微弓起，鏡緣因此出現錯位＝一眼看出是透鏡。
def defs(p, bg, accent, r):
    return f'''    <defs>
      <radialGradient id="{p}depth" cx="30%" cy="20%" r="98%">
        <stop offset="0%" stop-color="#ffffff" stop-opacity="0.18"></stop>
        <stop offset="58%" stop-color="#000000" stop-opacity="0.04"></stop>
        <stop offset="100%" stop-color="#000000" stop-opacity="0.32"></stop>
      </radialGradient>
      <clipPath id="{p}sq"><rect x="100" y="100" width="824" height="824" rx="185"></rect></clipPath>
      <clipPath id="{p}lensClip"><circle cx="512" cy="512" r="{r}"></circle></clipPath>
      <linearGradient id="{p}page" x1="0.2" y1="0" x2="0.8" y2="1">
        <stop offset="0%" stop-color="#FDFEFE"></stop>
        <stop offset="100%" stop-color="#DCEBE6"></stop>
      </linearGradient>
      <radialGradient id="{p}glass" cx="32%" cy="24%" r="86%">
        <stop offset="0%" stop-color="#ffffff" stop-opacity="0.42"></stop>
        <stop offset="48%" stop-color="#ffffff" stop-opacity="0.04"></stop>
        <stop offset="100%" stop-color="#0B4643" stop-opacity="0.16"></stop>
      </radialGradient>
    </defs>'''

def bgplate(p, bg):
    return f'''    <g clip-path="url(#{p}sq)">
      <rect x="100" y="100" width="824" height="824" fill="{bg}"></rect>
      <rect x="100" y="100" width="824" height="824" fill="url(#{p}depth)"></rect>
    </g>'''

def bg_stripes(p, accent, ys, w=28):
    """底圖條紋：水平、等距、低透明度；穿到鏡片外才看得到"""
    ls = "\n".join(
        f'      <line x1="176" y1="{y}" x2="848" y2="{y}"></line>' for y in ys)
    return f'''    <g clip-path="url(#{p}sq)">
      <g stroke="{accent}" stroke-opacity="0.34" stroke-width="{w}" stroke-linecap="round">
{ls}
      </g>
    </g>'''

def lens(p, r, ys, spread=1.55, bow=40, empty=False):
    """鏡片內：紙面 ＋ 被放大折射的條紋（往外撐開、微微弓起）＋ 玻璃高光"""
    import math
    out = [f'    <circle cx="512" cy="512" r="{r}" fill="url(#{p}page)"></circle>']
    if not empty:
        paths = []
        for y in ys:
            d = (y - 512) * spread
            yy = 512 + d
            half = r * r - d * d
            half = math.sqrt(half) if half > 0 else 0
            half = max(0.0, half - 16)          # 留一點邊，不要貼死鏡緣
            x1, x2 = 512 - half, 512 + half
            if abs(d) < 1:
                paths.append(f'        <path d="M {x1:.0f} {yy:.0f} L {x2:.0f} {yy:.0f}"></path>')
            else:
                cy = yy + (bow if d > 0 else -bow)   # 往外弓＝桶形畸變
                paths.append(
                    f'        <path d="M {x1:.0f} {yy:.0f} Q 512 {cy:.0f} {x2:.0f} {yy:.0f}"></path>')
        body = "\n".join(paths)
        out.append(f'''    <g clip-path="url(#{p}lensClip)">
      <g stroke="#0E5350" stroke-opacity="0.46" stroke-width="42" stroke-linecap="round" fill="none">
{body}
      </g>
    </g>''')
    out.append(f'    <circle cx="512" cy="512" r="{r}" fill="url(#{p}glass)"></circle>')
    out.append('    <path d="M 348 432 A 230 230 0 0 1 452 308" fill="none" stroke="#ffffff" stroke-opacity="0.75" stroke-width="16" stroke-linecap="round"></path>')
    out.append('    <path d="M 610 666 A 230 230 0 0 0 670 586" fill="none" stroke="#ffffff" stroke-opacity="0.32" stroke-width="11" stroke-linecap="round"></path>')
    return "\n".join(out)

def ring(p, accent):
    """開口環 ＋ 和軌道同寬的白球（乾淨平面白＋柔和落影，不做金屬感漸層）"""
    return f'''    <path d="M 653 247 A 300 300 0 1 1 371 247" fill="none" stroke="{accent}" stroke-width="64" stroke-linecap="round"></path>
    <circle cx="653" cy="252" r="32" fill="#04302E" opacity="0.22"></circle>
    <circle cx="653" cy="247" r="32" fill="#FFFFFF"></circle>'''

def icon_svg(p, r=250, ys=(404, 512, 620), empty=False, bg="{{bg}}", accent="{{accent}}"):
    parts = [defs(p, bg, accent, r), bgplate(p, bg)]
    if not empty:
        parts.append(bg_stripes(p, accent, ys))
    parts.append(lens(p, r, ys, empty=empty))
    parts.append(ring(p, accent))
    return "\n".join(parts)
