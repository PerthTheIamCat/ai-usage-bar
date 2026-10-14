# Regenerates Resources/dmg/background{,@2x}.png (needs Pillow and the Inter font). Run from the repo root.
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import math, random
S=4; W,H=660*S,400*S
def lerp(a,b,t): return tuple(int(a[i]+(b[i]-a[i])*t) for i in range(3))
base=Image.new("RGB",(W,H))
bp=base.load()
c0=(250,248,255); c1=(232,228,250)
for y in range(H):
    c=lerp(c0,c1,y/(H-1))
    for x in range(W): bp[x,y]=c
img=base.convert("RGBA")
def blob(cx,cy,r,col,alpha):
    layer=Image.new("RGBA",(W,H),col+(0,))
    d=ImageDraw.Draw(layer)
    d.ellipse([cx*S-r*S,cy*S-r*S,cx*S+r*S,cy*S+r*S],fill=col+(alpha,))
    layer=layer.filter(ImageFilter.GaussianBlur(r*S*0.55))
    return Image.alpha_composite(img,layer)
img=blob(70,40,150,(156,141,255),150)
img=blob(600,330,170,(255,170,140),130)
img=blob(560,30,120,(120,190,255),110)
img=blob(90,380,130,(255,150,210),90)
img=blob(330,200,110,(255,255,255),140)
d=ImageDraw.Draw(img)
def F(name,sz): return ImageFont.truetype(f"/usr/share/fonts/opentype/inter/{name}.otf",int(sz*S))
# glass pedestals under icon slots
def glass(cx,cy,r):
    global img
    sh=Image.new("RGBA",(W,H),(60,40,140,0))
    ImageDraw.Draw(sh).ellipse([cx*S-r*S,(cy+8)*S-r*S,cx*S+r*S,(cy+8)*S+r*S],fill=(60,40,140,60))
    sh=sh.filter(ImageFilter.GaussianBlur(14*S))
    img=Image.alpha_composite(img,sh)
    g=Image.new("RGBA",(W,H),(255,255,255,0))
    gd=ImageDraw.Draw(g)
    gd.ellipse([cx*S-r*S,cy*S-r*S,cx*S+r*S,cy*S+r*S],fill=(255,255,255,150),outline=(255,255,255,230),width=2*S)
    img=Image.alpha_composite(img,g)
glass(170,205,84); glass(490,205,84)
d=ImageDraw.Draw(img)
# arrow: dotted trail with gradient + head
x0,x1,y=262,398,205
n=14
for i in range(n):
    t=i/(n-1)
    col=lerp((156,141,255),(255,140,120),t)
    x=x0+(x1-x0-26)*t
    r=2.2+2.0*t
    d.ellipse([(x-r)*S,(y-r)*S,(x+r)*S,(y+r)*S],fill=col+(255,))
hx=x1; col=(255,140,120)
d.polygon([(hx*S,y*S),((hx-20)*S,(y-14)*S),((hx-14)*S,y*S),((hx-20)*S,(y+14)*S)],fill=col+(255,))
# title
d.text((W//2,50*S),"AI Usage Bar",font=F("InterDisplay-SemiBold",30),fill=(36,28,92),anchor="mm")
d.text((W//2,82*S),"Your Claude, Codex & Gemini limits, always in the menu bar",font=F("Inter-Regular",12.5),fill=(104,96,150),anchor="mm")
# footer usage-meter capsule with caption
mx0,mx1,my=205,455,350
d.rounded_rectangle([mx0*S,(my-6)*S,mx1*S,(my+6)*S],radius=6*S,fill=(255,255,255,190),outline=(255,255,255,255),width=S)
fill_w=(mx1-mx0)*0.62
cap=Image.new("RGBA",(W,H),(0,0,0,0)); cd=ImageDraw.Draw(cap)
for i in range(int(fill_w*S)):
    t=i/(fill_w*S)
    cd.line([(mx0*S+i,(my-5)*S),(mx0*S+i,(my+5)*S)],fill=lerp((156,141,255),(255,150,130),t)+(255,))
mask=Image.new("L",(W,H),0)
ImageDraw.Draw(mask).rounded_rectangle([mx0*S+S,(my-5)*S,(mx0+fill_w)*S,(my+5)*S],radius=5*S,fill=255)
img.paste(cap,(0,0),mask)
d=ImageDraw.Draw(img)
d.text((W//2,372*S),"Drag to Applications to install",font=F("Inter-Medium",11.5),fill=(104,96,150),anchor="mm")
out=img.convert("RGB")
out.resize((1320,800),Image.LANCZOS).save("Resources/dmg/background@2x.png")
out.resize((660,400),Image.LANCZOS).save("Resources/dmg/background.png")
