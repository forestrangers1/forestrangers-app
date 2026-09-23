#!/usr/bin/env python3
# ════════════════════════════════════════════════════════════════
#  FOREST RANGERS — PDF des conditions générales
#
#  Le texte officiel vit à un seul endroit : le bloc <div class="cg-box">
#  de forestrangers-inscription.html (c'est celui que le client accepte).
#  Ce script le relit et en fabrique le PDF téléchargeable, pour que les
#  deux ne puissent pas diverger.
#
#  Utilisation :  python3 cgv/generer_cgv.py
#  Dépendances :  reportlab, polices Carlito (paquet fonts-crosextra-carlito)
# ════════════════════════════════════════════════════════════════
import html
import os
import re
import sys

from reportlab.lib.colors import HexColor
from reportlab.lib.enums import TA_CENTER, TA_JUSTIFY
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (BaseDocTemplate, Frame, Image, PageBreak,
                                PageTemplate, Paragraph, Spacer)

RACINE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(RACINE, 'forestrangers-inscription.html')
LOGO = os.path.join(RACINE, 'logo-forestrangers.png')
VERSION = 'octobre 2026'
SORTIE = os.path.join(RACINE, 'Conditions_Generales_Forest_Rangers_2026-10.pdf')  # racine du site : les sous-dossiers ne sont pas déployés

ORANGE = HexColor('#ff5f1f')
NOIR = HexColor('#1c1f14')
GRIS = HexColor('#6b7060')

POLICES = '/usr/share/fonts/truetype/crosextra/'
for nom, fichier in [('CG', 'Carlito-Regular.ttf'), ('CG-Bold', 'Carlito-Bold.ttf'),
                     ('CG-Italic', 'Carlito-Italic.ttf')]:
    chemin = os.path.join(POLICES, fichier)
    pdfmetrics.registerFont(TTFont(nom, chemin if os.path.exists(chemin)
                                   else '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'))


def lire_cgv():
    """Retourne la liste des éléments (type, texte) du bloc officiel."""
    src = open(SOURCE, encoding='utf-8').read()
    d = src.index('<div class="cg-box"')
    d = src.index('>', d) + 1
    f = src.index('</div>', d)
    bloc = src[d:f]
    out = []
    for m in re.finditer(r'<(h4|h5|p|li)[^>]*>(.*?)</\1>', bloc, re.S):
        texte = re.sub(r'<[^>]+>', '', m.group(2))
        texte = html.unescape(texte)
        texte = re.sub(r'\s+', ' ', texte).strip()
        if texte:
            out.append((m.group(1), texte))
    return out


STYLES = {
    'h4': ParagraphStyle('h4', fontName='CG-Bold', fontSize=13, leading=16, textColor=NOIR,
                         spaceBefore=14, spaceAfter=7),
    'h5': ParagraphStyle('h5', fontName='CG-Bold', fontSize=11, leading=14, textColor=NOIR,
                         spaceBefore=10, spaceAfter=5),
    'p': ParagraphStyle('p', fontName='CG', fontSize=9.5, leading=13.5, textColor=NOIR,
                        alignment=TA_JUSTIFY, spaceAfter=5, leftIndent=8 * mm,
                        bulletFontName='CG-Bold', bulletFontSize=9.5, bulletIndent=0),
    'p0': ParagraphStyle('p0', fontName='CG', fontSize=9.5, leading=13.5, textColor=NOIR,
                         alignment=TA_JUSTIFY, spaceAfter=5, leftIndent=8 * mm),
    'li': ParagraphStyle('li', fontName='CG', fontSize=9.5, leading=13.5, textColor=NOIR,
                         leftIndent=14 * mm, bulletIndent=8 * mm, spaceAfter=3),
}
TITRE = ParagraphStyle('titre', fontName='CG-Bold', fontSize=20, leading=24, alignment=TA_CENTER,
                       textColor=NOIR, spaceAfter=4)
MARQUE = ParagraphStyle('marque', fontName='CG-Bold', fontSize=15, leading=19, alignment=TA_CENTER,
                        textColor=ORANGE, spaceAfter=4)
SOUS = ParagraphStyle('sous', fontName='CG', fontSize=9.5, leading=13, alignment=TA_CENTER,
                      textColor=GRIS, spaceAfter=16)


def decouper_numero(texte):
    """« 6.4. Secteur… » → (numéro, reste). Le numéro devient la puce du
    paragraphe : il reste en gras et ne se répète pas si le texte passe à la
    page suivante."""
    m = re.match(r'^((?:\d+\.\d+\.)|(?:[A-Z]\)))\s+(.*)$', texte)
    if m:
        return m.group(1), m.group(2)
    return None, texte


def pied(canvas, doc):
    canvas.saveState()
    canvas.setFont('CG', 7.5)
    canvas.setFillColor(GRIS)
    canvas.drawCentredString(
        A4[0] / 2, 12 * mm,
        'Conditions Générales FOREST RANGERS — ARCANIN S.à r.l. — Version %s — page %d'
        % (VERSION, doc.page))
    canvas.restoreState()


def construire():
    elements = lire_cgv()
    if not elements:
        sys.exit('Texte des conditions générales introuvable dans ' + SOURCE)

    doc = BaseDocTemplate(SORTIE, pagesize=A4,
                          leftMargin=20 * mm, rightMargin=20 * mm,
                          topMargin=18 * mm, bottomMargin=20 * mm,
                          title='Conditions Générales FOREST RANGERS — %s' % VERSION,
                          author='ARCANIN S.à r.l.')
    cadre = Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id='corps')
    doc.addPageTemplates([PageTemplate(id='cg', frames=[cadre], onPage=pied)])

    flux = []
    if os.path.exists(LOGO):
        logo = Image(LOGO, width=26 * mm, height=26 * mm)
        logo.hAlign = 'CENTER'
        flux += [logo, Spacer(1, 8)]
    flux += [Paragraph('CONDITIONS GÉNÉRALES', TITRE),
             Paragraph('FOREST RANGERS', MARQUE),
             Paragraph('ARCANIN S.à r.l. &nbsp;—&nbsp; Version %s' % VERSION, SOUS)]

    for kind, texte in elements:
        if kind == 'li':
            flux.append(Paragraph(html.escape(texte), STYLES['li'], bulletText='•'))
        elif kind in ('h4', 'h5'):
            flux.append(Paragraph(html.escape(texte), STYLES[kind]))
        else:
            num, reste = decouper_numero(texte)
            if num:
                flux.append(Paragraph(html.escape(reste), STYLES['p'], bulletText=num))
            else:
                flux.append(Paragraph(html.escape(texte), STYLES['p0']))

    doc.build(flux)
    print('PDF écrit : %s (%d éléments)' % (SORTIE, len(elements)))


if __name__ == '__main__':
    construire()
