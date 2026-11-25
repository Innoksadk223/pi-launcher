#!/usr/bin/env python3
"""从透明头像生成 macOS 应用图标（.icns）。

几何（与已确认的预览一致）：
- 画布 1024，角色最长边占 83.6%（实测系统图标的内容占比）。
- 形状用超椭圆（squircle）近似 macOS 圆角：n=5 时边缘剖面与系统图标接近，
  且不会裁到角色（已数值校验：裁切像素 = 0）。

小尺寸自适应（真实改进）：
- 16px 用纯色底 —— 8 格棋盘在 16px 下每格仅 2px，会退化成噪点。
- 32px 用 4 格低对比；64px 及以上用 8 格。

用法：python3 make-icon.py
"""
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image

PROJ = Path(__file__).resolve().parent.parent
AVATAR = PROJ / "assets" / "avatar.png"
OUT = PROJ / "assets/icon"

CANVAS = 1024
CONTENT_RATIO = 0.836
SQUIRCLE_N = 5.0
CHECK_A = (240, 241, 245)
CHECK_B = (219, 221, 230)
CHECK_SUBTLE_B = (230, 232, 239)
PLATE_WHITE = (255, 255, 255)


def squircle_mask(size: int, n: float = SQUIRCLE_N) -> Image.Image:
    y, x = np.mgrid[0:size, 0:size]
    c = (size - 1) / 2.0
    a = size / 2.0
    u = np.abs((x - c) / a)
    v = np.abs((y - c) / a)
    m = np.zeros((size, size), dtype=np.uint8)
    m[(u ** n + v ** n) <= 1.0] = 255
    return Image.fromarray(m, "L")


def tight_subject() -> Image.Image:
    im = Image.open(AVATAR).convert("RGBA")
    a = np.asarray(im)[:, :, 3]
    ys, xs = np.where(a > 8)
    return im.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))


def checker(dim: int, squares: int, ca, cb) -> Image.Image:
    layer = Image.new("RGB", (dim, dim), ca)
    px = layer.load()
    tile = dim / squares
    for gy in range(squares):
        for gx in range(squares):
            if (gx + gy) % 2:
                for y in range(int(gy * tile), int((gy + 1) * tile)):
                    for x in range(int(gx * tile), int((gx + 1) * tile)):
                        px[x, y] = cb
    return layer


def bg_plate(dim: int, variant: str) -> Image.Image:
    """图标底色。white 为纯白（各尺寸都统一，无小尺寸退化问题）。"""
    if variant == "white":
        return Image.new("RGB", (dim, dim), PLATE_WHITE).convert("RGBA")
    # checker：按尺寸自适应，避免 16px 下棋盘退化噪点
    if dim <= 16:
        return Image.new("RGB", (dim, dim), CHECK_A).convert("RGBA")
    if dim <= 32:
        return checker(dim, 4, CHECK_A, CHECK_SUBTLE_B).convert("RGBA")
    return checker(dim, 8, CHECK_A, CHECK_B).convert("RGBA")


def subject_on_canvas(dim: int, subject: Image.Image) -> Image.Image:
    target = round(dim * CONTENT_RATIO)
    s = target / max(subject.size)
    subj = subject.resize((max(1, round(subject.size[0] * s)),
                           max(1, round(subject.size[1] * s))), Image.LANCZOS)
    canvas = Image.new("RGBA", (dim, dim), (0, 0, 0, 0))
    canvas.alpha_composite(subj, ((dim - subj.size[0]) // 2, (dim - subj.size[1]) // 2))
    return canvas


def render(dim: int, subject: Image.Image, variant: str) -> Image.Image:
    canvas = subject_on_canvas(dim, subject)
    if variant == "clear":
        return canvas
    plate = bg_plate(dim, variant)
    plate.alpha_composite(canvas)
    plate.putalpha(squircle_mask(dim))
    return plate


def write_icns(variant: str, subject: Image.Image) -> None:
    name = f"AppIcon-{variant}"
    iconset = OUT / f"{name}.iconset"
    iconset.mkdir(parents=True, exist_ok=True)
    for px, scale in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                      (256, 1), (256, 2), (512, 1), (512, 2)]:
        dim = px * scale
        img = render(dim, subject, variant)
        img.save(iconset / f"icon_{px}x{px}{'@2x' if scale == 2 else ''}.png")
        if dim == 1024:
            img.save(OUT / f"{name}-1024.png")
    subprocess.run(["iconutil", "-c", "icns", str(iconset),
                    "-o", str(OUT / f"{name}.icns")], check=True)
    subprocess.run(["rm", "-rf", str(iconset)], check=True)
    print(f"  {name}.icns")


OUT.mkdir(parents=True, exist_ok=True)
subject = tight_subject()
print(f"角色（裁紧后）: {subject.size[0]}x{subject.size[1]}")

print("生成：")
for variant in ("white", "checker", "clear"):
    write_icns(variant, subject)

# ── 校验 ────────────────────────────────────────────────
print("\n校验：")
mask = np.asarray(squircle_mask(CANVAS))
raw = np.asarray(subject_on_canvas(CANVAS, subject))[:, :, 3]
clipped = int(((raw > 8) & (mask <= 128)).sum())
print(f"  角色被圆角裁切的像素: {clipped}")

for variant in ("white", "checker"):
    im = Image.open(OUT / f"AppIcon-{variant}-1024.png").convert("RGBA")
    a = np.asarray(im)[:, :, 3]
    print(f"  {variant:8s} 四角 alpha: {a[0,0]},{a[0,-1]},{a[-1,0]},{a[-1,-1]}"
          f"   不透明占比 {100*(a>230).mean():.0f}%")

print("\n小尺寸背景噪点（棋盘格退化风险，越低越好）：")
im = Image.open(OUT / "AppIcon-checker-1024.png").convert("RGBA")
for dim in (16, 32, 64):
    sm = np.asarray(im.resize((dim, dim), Image.LANCZOS)).astype(float)
    ds = [abs(sm[i, j, 0] - sm[i, j + 1, 0])
          for i in range(dim) for j in range(dim - 1)
          if sm[i, j, 3] > 200 and sm[i, j + 1, 3] > 200
          and (abs(i - dim / 2) > dim * 0.42 or abs(j - dim / 2) > dim * 0.42)]
    print(f"  {dim:3d}px  背景区相邻色差均值: {np.mean(ds) if ds else 0:.1f}")

print("\n输出：", OUT)
