"""Draws the MacDashboard app icon and writes Resources/AppIcon.icns.

A gauge (system status) above three bars (Claude / ChatGPT / Gemini usage limits)
on a blue squircle that follows the macOS icon grid (824 pt body on a 1024 pt canvas).

Requires Pillow; run from the repository root:
    python3 scripts/make_icon.py
"""
import math
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SCALE = 4                     # draw large, then downsample for smooth edges
CANVAS = 1024 * SCALE
BODY = (100 * SCALE, 100 * SCALE, 924 * SCALE, 924 * SCALE)
RADIUS = 185 * SCALE

ROOT = Path(__file__).resolve().parent.parent
OUT_ICNS = ROOT / "Resources" / "AppIcon.icns"
OUT_PNG = ROOT / "docs" / "images" / "icon.png"


def s(v: float) -> int:
    return int(round(v * SCALE))


def vertical_gradient(size, top, bottom):
    w, h = size
    grad = Image.new("RGBA", (1, h))
    for y in range(h):
        t = y / (h - 1)
        grad.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(4)))
    return grad.resize((w, h))


def body_mask():
    mask = Image.new("L", (CANVAS, CANVAS), 0)
    ImageDraw.Draw(mask).rounded_rectangle(BODY, RADIUS, fill=255)
    return mask


def arc_segment(draw, center, radius, width, start, end, color):
    """Thick arc with round caps (angles in degrees, 0 = 3 o'clock, clockwise)."""
    cx, cy = center
    box = (cx - radius, cy - radius, cx + radius, cy + radius)
    draw.arc(box, start, end, fill=color, width=width)
    inner = radius - width / 2
    for a in (start, end):
        x = cx + inner * math.cos(math.radians(a))
        y = cy + inner * math.sin(math.radians(a))
        r = width / 2
        draw.ellipse((x - r, y - r, x + r, y + r), fill=color)


def draw_icon() -> Image.Image:
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    mask = body_mask()

    # Soft drop shadow under the body, as in Apple's icon template.
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow_mask = mask.filter(ImageFilter.GaussianBlur(s(18)))
    shadow.paste((0, 0, 0, 90), (0, s(12)), shadow_mask)
    canvas = Image.alpha_composite(canvas, shadow)

    # Body: deep blue gradient with a glassy highlight at the top.
    body = vertical_gradient((CANVAS, CANVAS), (66, 104, 236, 255), (20, 28, 92, 255))
    highlight = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    ImageDraw.Draw(highlight).ellipse((s(40), s(-420), s(984), s(430)), fill=(255, 255, 255, 46))
    highlight = highlight.filter(ImageFilter.GaussianBlur(s(40)))
    body = Image.alpha_composite(body, highlight)
    canvas.paste(body, (0, 0), mask)

    layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    # Gauge: green → orange → pink arc, slightly more than a half circle.
    center = (s(512), s(548))
    radius, width = s(272), s(58)
    track = (255, 255, 255, 40)
    arc_segment(d, center, radius, width, 165, 375, track)
    arc_segment(d, center, radius, width, 165, 228, (52, 211, 120, 255))
    arc_segment(d, center, radius, width, 241, 299, (255, 176, 32, 255))
    arc_segment(d, center, radius, width, 312, 375, (255, 72, 110, 255))

    # Needle pointing into the orange zone, with a hub.
    angle = math.radians(258)
    tip = (center[0] + s(214) * math.cos(angle), center[1] + s(214) * math.sin(angle))
    perp = angle + math.pi / 2
    base_half = s(22)
    base_l = (center[0] + base_half * math.cos(perp), center[1] + base_half * math.sin(perp))
    base_r = (center[0] - base_half * math.cos(perp), center[1] - base_half * math.sin(perp))
    d.polygon([tip, base_l, base_r], fill=(255, 255, 255, 255))
    hub = s(46)
    d.ellipse((center[0] - hub, center[1] - hub, center[0] + hub, center[1] + hub), fill=(255, 255, 255, 255))
    dot = s(18)
    d.ellipse((center[0] - dot, center[1] - dot, center[0] + dot, center[1] + dot), fill=(36, 52, 150, 255))

    # Three usage bars in the providers' colors (Claude, ChatGPT, Gemini).
    left, right = s(262), s(762)
    bars = [(0.72, (232, 128, 92, 255)), (0.48, (32, 190, 150, 255)), (0.86, (96, 160, 255, 255))]
    for i, (fraction, color) in enumerate(bars):
        top = s(690 + i * 62)
        h = s(32)
        d.rounded_rectangle((left, top, right, top + h), h // 2, fill=(255, 255, 255, 46))
        d.rounded_rectangle((left, top, left + (right - left) * fraction, top + h), h // 2, fill=color)

    clipped = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    clipped.paste(layer, (0, 0), Image.composite(layer.getchannel("A"), Image.new("L", layer.size, 0), mask))
    canvas = Image.alpha_composite(canvas, clipped)
    return canvas.resize((1024, 1024), Image.LANCZOS)


def write_icns(icon: Image.Image) -> None:
    tmp = Path(tempfile.mkdtemp())
    iconset = tmp / "AppIcon.iconset"
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        icon.resize((size, size), Image.LANCZOS).save(iconset / f"icon_{size}x{size}.png")
        icon.resize((size * 2, size * 2), Image.LANCZOS).save(iconset / f"icon_{size}x{size}@2x.png")
    OUT_ICNS.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT_ICNS)], check=True)
    shutil.rmtree(tmp)


if __name__ == "__main__":
    image = draw_icon()
    OUT_PNG.parent.mkdir(parents=True, exist_ok=True)
    image.resize((256, 256), Image.LANCZOS).save(OUT_PNG)
    write_icns(image)
    print(f"wrote {OUT_ICNS} and {OUT_PNG}")
