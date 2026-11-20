"""Generate the app icon set.

Draws the DSH Mobile mark: a diamond outline around a solid diamond, on a deep
navy field with a soft accent glow. Everything is rendered at 4x and downsampled
so the layered icon stays crisp on high density screens.

Run:  python scripts/make_icons.py
"""

from __future__ import annotations

import os

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 4  # supersample factor

ACCENT = (107, 166, 255)
ACCENT_SOFT = (150, 195, 255)
INK_TOP = (16, 19, 25)
INK_BOTTOM = (26, 32, 44)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULE_MEDIA = os.path.join(ROOT, "entry", "src", "main", "resources", "base", "media")
APP_MEDIA = os.path.join(ROOT, "AppScope", "resources", "base", "media")


def lerp(a: int, b: int, t: float) -> int:
    return int(round(a + (b - a) * t))


def make_background(size: int) -> Image.Image:
    """Vertical gradient plus a blurred radial accent glow behind the mark."""
    big = size * SS
    img = Image.new("RGBA", (big, big), (0, 0, 0, 255))
    draw = ImageDraw.Draw(img)
    for y in range(big):
        t = y / max(1, big - 1)
        draw.line(
            [(0, y), (big, y)],
            fill=(
                lerp(INK_TOP[0], INK_BOTTOM[0], t),
                lerp(INK_TOP[1], INK_BOTTOM[1], t),
                lerp(INK_TOP[2], INK_BOTTOM[2], t),
                255,
            ),
        )

    # Radial glow: a light disc, heavily blurred, composited in accent colour.
    glow_mask = Image.new("L", (big, big), 0)
    gdraw = ImageDraw.Draw(glow_mask)
    inset = int(big * 0.18)
    gdraw.ellipse([inset, inset, big - inset, big - inset], fill=110)
    glow_mask = glow_mask.filter(ImageFilter.GaussianBlur(big * 0.09))

    glow = Image.new("RGBA", (big, big), (ACCENT[0], ACCENT[1], ACCENT[2], 0))
    glow.putalpha(glow_mask.point(lambda v: int(v * 0.30)))
    img = Image.alpha_composite(img, glow)

    # A faint vignette keeps the corners from looking flat.
    vignette = Image.new("L", (big, big), 0)
    vdraw = ImageDraw.Draw(vignette)
    vdraw.ellipse([-big * 0.15, -big * 0.15, big * 1.15, big * 1.15], fill=255)
    vignette = vignette.filter(ImageFilter.GaussianBlur(big * 0.10))
    dark = Image.new("RGBA", (big, big), (0, 0, 0, 120))
    dark.putalpha(vignette.point(lambda v: int((255 - v) * 0.55)))
    img = Image.alpha_composite(img, dark)

    return img.resize((size, size), Image.LANCZOS).convert("RGBA")


def diamond(px: int, radius: float, width: int, color: tuple[int, int, int, int]) -> Image.Image:
    """A rounded square rotated 45 degrees, i.e. a soft diamond outline."""
    layer = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    half = px // 2
    r = int(px * radius)
    draw.rounded_rectangle(
        [half - r, half - r, half + r, half + r],
        radius=int(px * 0.075),
        outline=color,
        width=max(1, width),
    )
    layer = layer.rotate(45, resample=Image.BICUBIC, center=(half, half))
    return layer


def make_foreground(size: int) -> Image.Image:
    """Transparent mark: diamond outline plus a solid inner diamond."""
    big = size * SS
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))

    outer = diamond(big, 0.268, 20 * SS, (ACCENT[0], ACCENT[1], ACCENT[2], 255))
    img = Image.alpha_composite(img, outer)

    inner = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    idraw = ImageDraw.Draw(inner)
    half = big // 2
    r = int(big * 0.112)
    idraw.rounded_rectangle(
        [half - r, half - r, half + r, half + r],
        radius=int(big * 0.030),
        fill=(ACCENT_SOFT[0], ACCENT_SOFT[1], ACCENT_SOFT[2], 255),
    )
    inner = inner.rotate(45, resample=Image.BICUBIC, center=(half, half))
    img = Image.alpha_composite(img, inner)

    return img.resize((size, size), Image.LANCZOS)


def make_start_icon(size: int) -> Image.Image:
    """Start-window icon: the whole tile including its rounded background."""
    big = size * SS
    bg = make_background(size).resize((big, big), Image.LANCZOS)
    mark = make_foreground(size).resize((big, big), Image.LANCZOS)

    mask = Image.new("L", (big, big), 0)
    mdraw = ImageDraw.Draw(mask)
    mdraw.rounded_rectangle([0, 0, big - 1, big - 1], radius=int(big * 0.22), fill=255)

    tile = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    tile.paste(bg, (0, 0), mask)
    tile = Image.alpha_composite(tile, Image.composite(mark, Image.new("RGBA", (big, big), (0, 0, 0, 0)), mask))
    return tile.resize((size, size), Image.LANCZOS)


def save(img: Image.Image, path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, "PNG", optimize=True)
    print(f"wrote {path} ({os.path.getsize(path)} bytes)")


def main() -> None:
    background = make_background(SIZE)
    foreground = make_foreground(SIZE)
    start_icon = make_start_icon(512)

    for media in (MODULE_MEDIA, APP_MEDIA):
        save(background, os.path.join(media, "background.png"))
        save(foreground, os.path.join(media, "foreground.png"))

    save(start_icon, os.path.join(MODULE_MEDIA, "startIcon.png"))


if __name__ == "__main__":
    main()
