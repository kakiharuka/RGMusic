from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets"
ASSETS.mkdir(parents=True, exist_ok=True)

W, H = 240, 180
S = 4
CW, CH = W * S, H * S
OUT = ASSETS / "RG Music.png"

img = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))

# Soft shadow behind the rounded app tile.
shadow = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle(
    (16*S, 15*S, 226*S, 171*S), radius=30*S, fill=(2, 28, 37, 105)
)
img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(8*S)))

# Teal gradient tile.
gradient = Image.new("RGB", (CW, CH))
gp = gradient.load()
c1 = (12, 91, 112)
c2 = (26, 174, 166)
for y in range(CH):
    t = y / (CH - 1)
    color = tuple(round(a * (1-t) + b * t) for a, b in zip(c1, c2))
    for x in range(CW):
        gp[x, y] = color

tile_mask = Image.new("L", (CW, CH), 0)
ImageDraw.Draw(tile_mask).rounded_rectangle(
    (12*S, 10*S, 228*S, 170*S), radius=31*S, fill=255
)
tile = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
tile.paste(gradient.convert("RGBA"), (0, 0), tile_mask)
img.alpha_composite(tile)

# Translucent highlights must be composited from a separate layer.
glow = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
gd.ellipse((150*S, -30*S, 270*S, 90*S), fill=(255, 255, 255, 20))
gd.ellipse((-25*S, 128*S, 76*S, 229*S), fill=(255, 255, 255, 14))
img.alpha_composite(glow)

d = ImageDraw.Draw(img)
PANEL = (247, 252, 249, 255)
INK = (13, 65, 80, 255)
MINT = (39, 170, 159, 255)
MUTED = (116, 170, 167, 255)

# Two rounded screens, matching the handheld's dual-screen layout.
d.rounded_rectangle((37*S, 28*S, 118*S, 154*S), radius=15*S, fill=(6, 67, 80, 255))
d.rounded_rectangle((124*S, 28*S, 205*S, 154*S), radius=15*S, fill=(6, 67, 80, 255))
d.rounded_rectangle((34*S, 24*S, 115*S, 150*S), radius=15*S, fill=PANEL)
d.rounded_rectangle((121*S, 24*S, 202*S, 150*S), radius=15*S, fill=PANEL)

# Music note on the left screen.
d.rounded_rectangle((78*S, 49*S, 85*S, 105*S), radius=4*S, fill=INK)
d.ellipse((58*S, 92*S, 83*S, 110*S), fill=INK)
d.polygon([(81*S, 50*S), (102*S, 48*S), (99*S, 68*S), (86*S, 65*S)], fill=INK)

# Track metadata, waveform and progress on the right screen.
d.rounded_rectangle((138*S, 45*S, 185*S, 51*S), radius=3*S, fill=INK)
d.rounded_rectangle((138*S, 60*S, 169*S, 65*S), radius=2*S, fill=MUTED)
heights = (14, 28, 20, 39, 25, 33, 18, 29, 22)
for i, hh in enumerate(heights):
    x = (138 + i * 7) * S
    d.rounded_rectangle(
        (x, (107 - hh//2)*S, x + 4*S, (107 + hh//2)*S),
        radius=2*S,
        fill=MINT,
    )
d.rounded_rectangle((138*S, 130*S, 185*S, 134*S), radius=2*S, fill=(196, 222, 216, 255))
d.rounded_rectangle((138*S, 130*S, 168*S, 134*S), radius=2*S, fill=MINT)
d.ellipse((164*S, 128*S, 172*S, 136*S), fill=INK)

img = img.resize((W, H), Image.Resampling.LANCZOS)
img.save(OUT, "PNG", optimize=True)
print(OUT)