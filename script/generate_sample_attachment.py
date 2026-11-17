#!/usr/bin/env python3
"""Generate the bundled, one-page demo attachment. Requires reportlab."""

from pathlib import Path

from reportlab.lib.colors import HexColor
from reportlab.lib.pagesizes import A4
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "postmere/postmere/Resources/Fieldnotes-direction.pdf"
OUTPUT.parent.mkdir(parents=True, exist_ok=True)

FONT_DIR = Path("/System/Library/Fonts/Supplemental")
FONTS = {"serif": "Times-Roman", "sans": "Helvetica", "bold": "Helvetica-Bold"}
for role, filename in [("serif", "Georgia.ttf"), ("sans", "Arial.ttf"), ("bold", "Arial Bold.ttf")]:
    if (FONT_DIR / filename).exists():
        name = "Fieldnotes-" + role
        pdfmetrics.registerFont(TTFont(name, str(FONT_DIR / filename)))
        FONTS[role] = name

PAPER = HexColor("#F4F0E6")
FOREST = HexColor("#243D32")
INK = HexColor("#24312A")
MUTED = HexColor("#6B7269")
BRASS = HexColor("#B89965")
RULE = HexColor("#D8D6CA")
WHITE = HexColor("#FFFDF7")
W, H = A4
LEFT, RIGHT = 44, W - 44

c = canvas.Canvas(str(OUTPUT), pagesize=A4, pageCompression=1, invariant=1)
c.setTitle("Fieldnotes - Sample identity direction")
c.setAuthor("Postmere Demo")
c.setSubject("A fictional design attachment for the Postmere local mail preview")
c.setFillColor(PAPER)
c.rect(0, 0, W, H, fill=1, stroke=0)


def text(value, x, y, size=10, font="sans", color=INK):
    c.setFillColor(color)
    c.setFont(FONTS[font], size)
    c.drawString(x, y, value)


def label(value, x, y, color=MUTED, size=8):
    c.setFillColor(color)
    t = c.beginText(x, y)
    t.setFont(FONTS["bold"], size)
    t.setCharSpace(1.1)
    t.textOut(value.upper())
    c.drawText(t)


def line(y):
    c.setStrokeColor(RULE)
    c.setLineWidth(0.6)
    c.line(LEFT, y, RIGHT, y)


label("Postmere demo", LEFT, H - 44)
label("Direction 01 / November 2026", 338, H - 44, size=7)
text("Fieldnotes", LEFT, H - 106, size=47, font="serif", color=FOREST)
text("Sample identity direction", LEFT + 2, H - 133, size=13, color=MUTED)
line(H - 155)

label("01  /  Wordmark", LEFT, H - 177)
c.setFillColor(FOREST)
c.roundRect(LEFT, H - 300, RIGHT - LEFT, 104, 2, fill=1, stroke=0)
c.setFont(FONTS["serif"], 46)
c.setFillColor(WHITE)
c.drawCentredString(W / 2, H - 254, "Fieldnotes")
c.setFillColor(BRASS)
c.circle(W / 2, H - 278, 2.1, fill=1, stroke=0)
text("A familiar serif, enough space to breathe, and one quiet accent.", LEFT, H - 320, 9, color=MUTED)

label("02  /  Typography", LEFT, H - 356)
text("Thoughtful by nature.", LEFT, H - 388, 21, font="serif", color=FOREST)
text("A confident serif for the moments that matter.", LEFT, H - 409, 8.5, color=MUTED)
text("A clear sans serif for everything around them.", LEFT, H - 423, 8.5, color=MUTED)

label("03  /  Palette", 342, H - 356)
swatches = [(FOREST, "Forest", "243D32"), (WHITE, "Paper", "FFFDF7"), (BRASS, "Brass", "B89965")]
for i, (color, name, code) in enumerate(swatches):
    x = 342 + i * 72
    c.setFillColor(color)
    c.setStrokeColor(RULE)
    c.roundRect(x, H - 404, 56, 33, 1, fill=1, stroke=1)
    text(name, x, H - 419, 8)
    text(code, x, H - 432, 6.5, color=MUTED)

line(H - 455)
label("04  /  Stationery", LEFT, H - 479)

# Small paper applications are vector artwork, not photographed assets.
c.setFillColor(FOREST)
c.roundRect(LEFT, H - 607, 225, 107, 2, fill=1, stroke=0)
text("Fieldnotes", LEFT + 19, H - 541, 25, "serif", WHITE)
label("Objects. Places. Stories.", LEFT + 20, H - 567, WHITE, 5.2)
text("A quieter way to make an impression.", LEFT + 20, H - 591, 6.7, color=WHITE)

c.setFillColor(WHITE)
c.setStrokeColor(RULE)
c.roundRect(303, H - 661, 248, 161, 2, fill=1, stroke=1)
text("Fieldnotes", 321, H - 529, 17, "serif", FOREST)
label("Studio correspondence", 321, H - 546, MUTED, 5)
c.setFillColor(BRASS)
c.rect(514, H - 534, 18, 18, fill=1, stroke=0)
c.setStrokeColor(RULE)
c.setLineWidth(0.65)
for offset, length in [(571, 194), (582, 194), (593, 174), (611, 194), (622, 149)]:
    c.line(321, H - offset, 321 + length, H - offset)
text("A plain letterhead lets the message lead.", 321, H - 646, 6.6, color=MUTED)

text("The essential version", LEFT, H - 630, 10, font="bold")
text("Warm paper. Forest ink. A single brass detail.", LEFT, H - 647, 8, color=MUTED)
text("Designed to work beautifully in one color, too.", LEFT, H - 661, 8, color=MUTED)

line(112)
label("For the next review", LEFT, 92)
text("Confirm the wordmark, compare the type pairing, and review a printed proof.", LEFT, 75, 9, color=MUTED)
line(56)
text("Fictional artwork created for Postmere's local email demo. Not a client deliverable.", LEFT, 39, 7, color=MUTED)
text("01 / 01", RIGHT - 29, 39, 7, color=MUTED)

c.showPage()
c.save()
print(f"Created {OUTPUT} ({OUTPUT.stat().st_size:,} bytes)")
