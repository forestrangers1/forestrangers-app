# Norwester + accents dessinés → « FR Display » (OFL : nom réservé, donc renommé)
from fontTools.ttLib import TTFont
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib.tables._g_l_y_f import GlyphComponent
import sys
SRC='/home/claude/app/forestrangers_app/norwester.woff'
f=TTFont(SRC); f.flavor=None
glyf=f['glyf']; hmtx=f['hmtx']; cmap=f.getBestCmap()
CAP, SC = 1638, 1434
T = 150      # épaisseur des accents

def poly(pen, pts):
    pen.moveTo(pts[0])
    for p in pts[1:]: pen.lineTo(p)
    pen.closePath()

def accent(name, draw):
    pen=TTGlyphPen(None); draw(pen); g=pen.glyph()
    glyf[name]=g; hmtx[name]=(0,0); f.glyphOrder.append(name) if name not in f.glyphOrder else None
    g.recalcBounds(glyf)

# Accents dessinés autour de x=0, posés sur y=0 (hauteur ~ 240)
H=230
accent('fr_acute',     lambda p: poly(p, [(-150,0),(-20,0),(170,H),(20,H)]))
accent('fr_grave',     lambda p: poly(p, [(20,0),(150,0),(-20,H),(-170,H)]))
accent('fr_circ',      lambda p: (poly(p,[(-230,0),(-80,0),(0,120),(80,0),(230,0),(70,H),(-70,H)])))
D=175
accent('fr_dier',      lambda p: (poly(p,[(-235,0),(-235+D,0),(-235+D,D),(-235,D)]), poly(p,[(60,0),(60+D,0),(60+D,D),(60,D)])))
# cédille : petite queue sous la ligne de base
accent('fr_cedil',     lambda p: poly(p, [(-60,0),(60,0),(60,-90),(150,-90),(150,-230),(-110,-230),(-110,-150),(20,-150),(20,-120),(-60,-120)]))

def compose(newname, base, acc, uni, gap=90, capScale=None):
    bg=glyf[base]; adv,lsb=hmtx[base]
    cx=(bg.xMin+bg.xMax)//2
    top = bg.yMax
    g=glyf.__class__.__dict__  # noqa
    from fontTools.ttLib.tables._g_l_y_f import Glyph
    ng=Glyph(); ng.numberOfContours=-1; ng.components=[]
    c1=GlyphComponent(); c1.glyphName=base; c1.x=0; c1.y=0; c1.flags=0x4
    c2=GlyphComponent(); c2.glyphName=acc; c2.x=cx; c2.y=(0 if acc=='fr_cedil' else top+gap); c2.flags=0
    ng.components=[c1,c2]
    glyf[newname]=ng; hmtx[newname]=(adv,lsb)
    if newname not in f.glyphOrder: f.glyphOrder.append(newname)
    ng.recalcBounds(glyf)
    for t in f['cmap'].tables:
        if t.isUnicode(): t.cmap[uni]=newname

M={'acute':'fr_acute','grave':'fr_grave','circ':'fr_circ','dier':'fr_dier','cedil':'fr_cedil'}
TAB = {
 'à':('a','grave'),'â':('a','circ'),'ä':('a','dier'),'é':('e','acute'),'è':('e','grave'),'ê':('e','circ'),'ë':('e','dier'),
 'î':('i','circ'),'ï':('i','dier'),'ô':('o','circ'),'ö':('o','dier'),'ù':('u','grave'),'û':('u','circ'),'ü':('u','dier'),
 'ç':('c','cedil'),'ÿ':('y','dier'),'á':('a','acute'),'í':('i','acute'),'ó':('o','acute'),'ú':('u','acute'),'ñ':None,
}
for ch,v in TAB.items():
    if not v: continue
    b,a=v
    compose('fr_'+hex(ord(ch))[2:], cmap[ord(b)], M[a], ord(ch))
    up=ch.upper(); B=b.upper()
    compose('fr_'+hex(ord(up))[2:], cmap[ord(B)], M[a], ord(up), gap=70)
# Œ œ absents : on laisse le repli
glyf.glyphOrder=f.glyphOrder
f.setGlyphOrder(f.glyphOrder)
f['maxp'].numGlyphs=len(f.glyphOrder)
# cales : GPOS/GSUB/GDEF inchangés (kerning des nouvelles lettres = aucun)
f['maxp'].maxComponentElements=max(getattr(f['maxp'],'maxComponentElements',0),2)
f['maxp'].maxComponentDepth=max(getattr(f['maxp'],'maxComponentDepth',0),1)
# Renommage (nom réservé « Norwester »)
for rec in f['name'].names:
    if rec.nameID in (1,4,16): rec.string='FR Display'
    elif rec.nameID==6: rec.string='FRDisplay-Regular'
    elif rec.nameID==3: rec.string='FR Display Regular; derived from Norwester'
if 'webf' in f: del f['webf']
f.save('frdisplay.ttf')
for fl in ('woff','woff2'):
    f.flavor=fl; f.save('frdisplay.'+fl)
print('ok', len(f.glyphOrder))
