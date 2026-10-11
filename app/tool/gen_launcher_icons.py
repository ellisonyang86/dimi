"""Generate all DIMI brand assets from one geometric mark (Pillow required)."""
from pathlib import Path
from math import cos, sin, radians
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / 'app/assets/brand'
RES = ROOT / 'app/android/app/src/main/res'
PRIMARY, CREAM = '#536B61', '#F7F8F5'
# Launcher contrast is independent of the soft in-app palette.
ICON_BG, ICON_MARK = '#304F43', '#FFFFFF'
RING = 'M74.514 70.569 A32 32 0 1 1 74.514 29.431'
PEOPLE = 'M34 62 C34 49 50 49 50 62 M50 62 C50 49 66 49 66 62'
DENSITIES = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}


def mark(size=512, color=PRIMARY):
    factor = size * 4 / 100
    img = Image.new('RGBA', (size * 4, size * 4))
    d = ImageDraw.Draw(img)

    def dot(x, y, r):
        d.ellipse(((x-r)*factor, (y-r)*factor, (x+r)*factor, (y+r)*factor), fill=color)

    def stroke(points, width):
        d.line([(x*factor, y*factor) for x, y in points], fill=color,
               width=round(width*factor), joint='curve')
        # Overlapping disks avoid Pillow polyline seams on dense curves.
        for x,y in points:
            dot(x,y,width/2)

    ring = [(50+32*cos(radians(a/4)),50+32*sin(radians(a/4))) for a in range(160,1281)]
    stroke(ring,7)
    for left in (34,50):
        points=[]
        for i in range(121):
            t=i/120; u=1-t
            points.append((u**3*left+3*u*u*t*left+3*u*t*t*(left+16)+t**3*(left+16),
                           u**3*62+3*u*u*t*49+3*u*t*t*49+t**3*62))
        stroke(points,6)
    dot(42,42,4)
    dot(58,42,4)
    return img.resize((size,size),Image.Resampling.LANCZOS)


def svg(background=False, launcher=False):
    bg_color = ICON_BG if launcher else '#DFE9E2'
    bg=f'<rect width="100" height="100" rx="22" fill="{bg_color}"/>' if background else ''
    color=ICON_MARK if launcher else PRIMARY
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" role="img" aria-label="DIMI 重逢标识">
{bg}<g fill="none" stroke="{color}" stroke-linecap="round" stroke-linejoin="round">
<path d="{RING}" stroke-width="7"/><path d="{PEOPLE}" stroke-width="6"/>
</g><g fill="{color}"><circle cx="42" cy="42" r="4"/><circle cx="58" cy="42" r="4"/></g></svg>
'''


def icon(size=1024):
    img=Image.new('RGBA',(size*4,size*4))
    ImageDraw.Draw(img).rounded_rectangle((0,0,size*4-1,size*4-1),radius=round(size*.88),fill=ICON_BG)
    img=img.resize((size,size),Image.Resampling.LANCZOS)
    img.alpha_composite(mark(size, ICON_MARK))
    return img


def write(path, text):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(text,encoding='utf-8')


def main():
    ASSETS.mkdir(parents=True,exist_ok=True)
    mark().save(ASSETS/'dimi_mark.png')
    write(ASSETS/'dimi_mark.svg',svg())
    write(ASSETS/'dimi_icon.svg',svg(True, launcher=True))
    write(ROOT/'h5/assets/dimi-logo.svg',svg(True))
    master=icon()
    master.save(ASSETS/'dimi_icon_1024.png')
    master.save(ROOT/'app/tool/ic_launcher_master.png')
    for density,size in DENSITIES.items():
        path=RES/f'mipmap-{density}/ic_launcher.png'
        path.parent.mkdir(parents=True,exist_ok=True)
        master.resize((size,size),Image.Resampling.LANCZOS).save(path)
    vector=f'''<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="108dp" android:height="108dp" android:viewportWidth="108" android:viewportHeight="108">
  <group android:scaleX="0.75" android:scaleY="0.75" android:translateX="16.5" android:translateY="16.5">
    <path android:pathData="{RING}" android:strokeColor="{ICON_MARK}" android:strokeWidth="7" android:strokeLineCap="round"/>
    <path android:pathData="{PEOPLE}" android:strokeColor="{ICON_MARK}" android:strokeWidth="6" android:strokeLineCap="round"/>
    <path android:fillColor="{ICON_MARK}" android:pathData="M38 42 A4 4 0 1 0 46 42 A4 4 0 1 0 38 42 M54 42 A4 4 0 1 0 62 42 A4 4 0 1 0 54 42"/>
  </group>
</vector>
'''
    write(RES/'drawable/ic_launcher_foreground.xml',vector)
    write(RES/'values/brand_colors.xml',f'<resources><color name="dimi_icon_background">{ICON_BG}</color></resources>\n')
    for qualifier,mono in [('v26',''),('v33','  <monochrome android:drawable="@drawable/ic_launcher_foreground"/>\n')]:
        write(RES/f'mipmap-anydpi-{qualifier}/ic_launcher.xml',f'''<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
  <background android:drawable="@color/dimi_icon_background"/>
  <foreground android:drawable="@drawable/ic_launcher_foreground"/>
{mono}</adaptive-icon>
''')
    board=Image.new('RGB',(1200,760),CREAM)
    draw=ImageDraw.Draw(board)
    font_path=Path('C:/Windows/Fonts/msyh.ttc')
    font=lambda n: ImageFont.truetype(str(font_path),n) if font_path.exists() else ImageFont.load_default()
    draw.text((64,40),'DIMI  /  重逢',font=font(36),fill=PRIMARY)
    draw.text((64,98),'一个开口，让走散的人重新相遇。',font=font(21),fill='#6F6F6F')
    board.paste(icon(360),(80,185),icon(360))
    bare=mark(300,PRIMARY); board.paste(bare,(550,210),bare)
    draw.text((125,575),'APP 图标',font=font(22),fill=PRIMARY)
    draw.text((593,575),'页面品牌标识',font=font(22),fill=PRIMARY)
    x=910
    for size in (80,48,32):
        asset=icon(size); board.paste(asset,(x,240),asset)
        draw.text((x,340),str(size),font=font(16),fill=PRIMARY)
        x+=size+20
    draw.text((914,575),'小尺寸识别',font=font(22),fill=PRIMARY)
    draw.line((64,653,1136,653),fill='#E0DDD5',width=1)
    draw.text((64,685),'深黛绿桌面图标  ·  白色重逢标识  ·  页面保持柔和配色',font=font(19),fill=PRIMARY)
    board.save(ASSETS/'brand_preview.png')
    print('Generated DIMI brand assets, launcher densities and adaptive icons.')


if __name__=='__main__':
    main()
