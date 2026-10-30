@echo off & goto :bat
"""
:bat
setlocal
title Roblox GUI Overlay
set "PY="
python --version >nul 2>nul && set "PY=python" && set "PYW=pythonw"
if not defined PY py --version >nul 2>nul && set "PY=py" && set "PYW=pyw"
if not defined PY goto :nopy
%PY% -c "import PIL, tkinter" >nul 2>nul || %PY% -m pip install --disable-pip-version-check --quiet pillow
%PY% -c "import PIL, tkinter" >nul 2>nul || goto :nolib
start "" %PYW% -x "%~f0"
exit /b
:nopy
echo Python was not found. Install it from python.org and tick Add python.exe to PATH, then run this again.
pause
exit /b 1
:nolib
echo Could not install the Pillow package or tkinter is missing. Reinstall Python with tcl/tk enabled.
pause
exit /b 1
"""
import os
import sys
import io
import math
import glob
import time
import json
import base64
import ctypes
import queue
import threading
import traceback
from PIL import Image, ImageDraw, ImageFont, ImageChops

SS = 4
_font_files = None
_font_cache = {}
_mask_cache = {}
_icon_cache = {}


def _discover_fonts():
    found = {}
    names = []
    for env in ("LOCALAPPDATA", "ProgramFiles(x86)", "ProgramFiles", "ProgramW6432"):
        base = os.environ.get(env)
        if base:
            pattern = os.path.join(base, "Roblox", "Versions", "*", "content", "fonts", "**", "BuilderSans*")
            names += glob.glob(pattern, recursive=True)
    try:
        names.sort(key=os.path.getmtime, reverse=True)
    except Exception:
        pass
    for p in names:
        low = os.path.basename(p).lower()
        if not low.endswith((".otf", ".ttf")) or "italic" in low:
            continue
        if "extrabold" in low or "black" in low:
            key = "x"
        elif "bold" in low:
            key = "b"
        elif "medium" in low:
            key = "m"
        elif "regular" in low:
            key = "r"
        else:
            continue
        found.setdefault(key, p)
    return found


def _fallback_list(weight):
    windir = os.environ.get("WINDIR", "C:\\Windows")
    wf = os.path.join(windir, "Fonts")
    table = {
        "r": [os.path.join(wf, "segoeui.ttf"), "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"],
        "m": [os.path.join(wf, "seguisb.ttf"), os.path.join(wf, "segoeui.ttf"), "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"],
        "b": [os.path.join(wf, "segoeuib.ttf"), os.path.join(wf, "seguisb.ttf"), "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"],
    }
    return table[weight]


def font(weight, px):
    global _font_files
    px = max(6, int(px))
    key = (weight, px)
    f = _font_cache.get(key)
    if f is not None:
        return f
    if _font_files is None:
        _font_files = _discover_fonts()
    order = {"r": ("r", "m"), "m": ("m", "r", "b"), "b": ("b", "x", "m")}[weight]
    cands = [_font_files[k] for k in order if k in _font_files] + _fallback_list(weight)
    f = None
    for path in cands:
        try:
            f = ImageFont.truetype(path, px)
            break
        except Exception:
            continue
    if f is None:
        f = ImageFont.load_default(px)
    _font_cache[key] = f
    return f


def rrmask(w, h, r, ring=0):
    w = max(1, int(w))
    h = max(1, int(h))
    r = max(0, min(int(r), w // 2, h // 2))
    key = (w, h, r, ring)
    m = _mask_cache.get(key)
    if m is not None:
        return m
    big = Image.new("L", (w * SS, h * SS), 0)
    d = ImageDraw.Draw(big)
    d.rounded_rectangle((0, 0, w * SS - 1, h * SS - 1), radius=r * SS, fill=255)
    if ring > 0 and w > ring * 2 and h > ring * 2:
        d.rounded_rectangle(
            (ring * SS, ring * SS, w * SS - 1 - ring * SS, h * SS - 1 - ring * SS),
            radius=max(0, r - ring) * SS,
            fill=0,
        )
    m = big.resize((w, h), Image.BOX)
    if len(_mask_cache) > 600:
        _mask_cache.clear()
    _mask_cache[key] = m
    return m


def colorize(mask, color, alpha=1.0):
    r, g, b = color[0], color[1], color[2]
    a = (color[3] if len(color) > 3 else 255) * alpha / 255.0
    if a < 0.999:
        mask = mask.point([int(i * a + 0.5) for i in range(256)])
    layer = Image.new("RGBA", mask.size, (r, g, b, 0))
    layer.putalpha(mask)
    return layer


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


class Cv:
    def __init__(self, w, h, S=1.0, physical=False):
        self.S = S
        if physical:
            self.W = max(1, int(w))
            self.H = max(1, int(h))
            self.w = self.W / S
            self.h = self.H / S
        else:
            self.w = w
            self.h = h
            self.W = max(1, int(math.ceil(w * S)))
            self.H = max(1, int(math.ceil(h * S)))
        self.im = Image.new("RGBA", (self.W, self.H), (0, 0, 0, 0))

    def p(self, v):
        return int(round(v * self.S))

    def comp(self, layer, x, y):
        lw, lh = layer.size
        x0 = max(0, x)
        y0 = max(0, y)
        x1 = min(self.W, x + lw)
        y1 = min(self.H, y + lh)
        if x1 <= x0 or y1 <= y0:
            return
        if (x0, y0, x1, y1) != (x, y, x + lw, y + lh):
            layer = layer.crop((x0 - x, y0 - y, x1 - x, y1 - y))
        self.im.alpha_composite(layer, (x0, y0))

    def fill(self, color):
        self.comp(Image.new("RGBA", (self.W, self.H), tuple(color)), 0, 0)

    def rr(self, x, y, w, h, r, color, ring=0):
        X = self.p(x)
        Y = self.p(y)
        Wd = max(1, self.p(x + w) - X)
        Hd = max(1, self.p(y + h) - Y)
        mask = rrmask(Wd, Hd, self.p(r), self.p(ring) if ring else 0)
        self.comp(colorize(mask, color), X, Y)

    def circle(self, cx, cy, d, color, ring=0):
        self.rr(cx - d / 2.0, cy - d / 2.0, d, d, d / 2.0, color, ring)

    def line_h(self, x, y, w, color, t=1):
        self.rr(x, y, w, t, 0, color)

    def text(self, x, y, s, weight="r", size=14, color=(255, 255, 255, 255), anchor="l", stroke=None, maxw=None):
        if not s:
            return 0
        px = self.p(size)
        f = font(weight, px)
        if maxw is not None:
            s = fit_text(s, weight, size, maxw, self.S)
        tw = int(math.ceil(f.getlength(s)))
        sw = self.p(stroke[0]) if stroke else 0
        pad = sw + 3
        mw = tw + pad * 2
        mh = int(px * 2.4) + pad * 2
        mask = Image.new("L", (mw, mh), 0)
        d = ImageDraw.Draw(mask)
        d.text((pad, mh // 2), s, font=f, fill=255, anchor="lm")
        if anchor == "l":
            lx = self.p(x) - pad
        elif anchor == "m":
            lx = self.p(x) - tw // 2 - pad
        else:
            lx = self.p(x) - tw - pad
        ly = self.p(y) - mh // 2
        if stroke:
            sm = Image.new("L", (mw, mh), 0)
            ImageDraw.Draw(sm).text((pad, mh // 2), s, font=f, fill=255, anchor="lm", stroke_width=sw, stroke_fill=255)
            self.comp(colorize(sm, stroke[1]), lx, ly)
        self.comp(colorize(mask, color), lx, ly)
        return tw / self.S

    def icon(self, name, cx, cy, size, color, **kw):
        sz = max(4, self.p(size))
        key = (name, sz, tuple(sorted(kw.items())))
        m = _icon_cache.get(key)
        if m is None:
            big = Image.new("L", (sz * SS, sz * SS), 0)
            ICONS[name](big, sz * SS / 24.0, **kw)
            m = big.resize((sz, sz), Image.BOX)
            _icon_cache[key] = m
        self.comp(colorize(m, color), self.p(cx) - sz // 2, self.p(cy) - sz // 2)

    def blit(self, other, x, y, alpha=1.0):
        im = other.im
        if alpha < 0.999:
            a = im.getchannel("A").point([int(i * alpha + 0.5) for i in range(256)])
            im = im.copy()
            im.putalpha(a)
        self.comp(im, self.p(x), self.p(y))

    def paste_img(self, img, x, y, w, h, alpha=1.0):
        W = max(1, self.p(x + w) - self.p(x))
        H = max(1, self.p(y + h) - self.p(y))
        im = img if img.size == (W, H) else img.resize((W, H), Image.LANCZOS)
        if alpha < 0.999:
            a = im.getchannel("A").point([int(i * alpha + 0.5) for i in range(256)])
            im = im.copy()
            im.putalpha(a)
        self.comp(im, self.p(x), self.p(y))

    def round_clip(self, r, rect_h=None):
        m = rrmask(self.W, self.H if rect_h is None else rect_h, self.p(r))
        if rect_h is not None and rect_h != self.H:
            full = Image.new("L", (self.W, self.H), 255)
            full.paste(m, (0, 0))
            m = full
        a = ImageChops.multiply(self.im.getchannel("A"), m)
        self.im.putalpha(a)


def fit_text(s, weight, size, maxw, S=1.0):
    f = font(weight, int(round(size * S)))
    limit = maxw * S
    if f.getlength(s) <= limit:
        return s
    lo = 0
    hi = len(s)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if f.getlength(s[:mid] + "...") <= limit:
            lo = mid
        else:
            hi = mid - 1
    return s[:lo].rstrip() + "..."


def text_w(s, weight, size, S=1.0):
    return font(weight, int(round(size * S))).getlength(s) / S


def _pl(m, k, pts, w):
    d = ImageDraw.Draw(m)
    pp = [(x * k, y * k) for x, y in pts]
    d.line(pp, fill=255, width=max(1, int(round(w * k))), joint="curve")
    r = w * k / 2.0
    for x, y in (pp[0], pp[-1]):
        d.ellipse((x - r, y - r, x + r, y + r), fill=255)


def _el(m, k, box, w, fill=False, val=255):
    d = ImageDraw.Draw(m)
    b = [v * k for v in box]
    if fill:
        d.ellipse(b, fill=val)
    else:
        d.ellipse(b, outline=val, width=max(1, int(round(w * k))))


def _rrect(m, k, box, r, w, fill=False, val=255):
    d = ImageDraw.Draw(m)
    b = [v * k for v in box]
    if fill:
        d.rounded_rectangle(b, radius=r * k, fill=val)
    else:
        d.rounded_rectangle(b, radius=r * k, outline=val, width=max(1, int(round(w * k))))


def _arc(m, k, box, a0, a1, w):
    d = ImageDraw.Draw(m)
    d.arc([v * k for v in box], a0, a1, fill=255, width=max(1, int(round(w * k))))


def _poly(m, k, pts, w, close=True):
    pp = list(pts)
    if close:
        pp.append(pp[0])
    _pl(m, k, pp, w)


def i_roblox(m, k):
    sq = Image.new("L", (m.width, m.height), 0)
    _rrect(sq, k, (1.6, 1.6, 22.4, 22.4), 3.2, 0, fill=True)
    _rrect(sq, k, (9.3, 9.3, 14.7, 14.7), 0.6, 0, fill=True, val=0)
    sq = sq.rotate(-13, resample=Image.BICUBIC, center=(12 * k, 12 * k))
    m.paste(sq, (0, 0))


def i_menu(m, k):
    for y in (5.2, 12, 18.8):
        _pl(m, k, [(1.6, y), (22.4, y)], 1.75)


def i_chat(m, k):
    _rrect(m, k, (1.5, 2.5, 22.5, 18.5), 2.2, 0, fill=True)
    ImageDraw.Draw(m).polygon([(9.2 * k, 18 * k), (14.8 * k, 18 * k), (12 * k, 22.2 * k)], fill=255)
    _pl(m, k, [(7.3, 8.6), (16.7, 8.6)], 1.7)
    _pl(m, k, [(9.8, 12.6), (14.2, 12.6)], 1.7)
    d = ImageDraw.Draw(m)
    for pts in ([(7.3, 8.6), (16.7, 8.6)], [(9.8, 12.6), (14.2, 12.6)]):
        d.line([(x * k, y * k) for x, y in pts], fill=0, width=int(1.7 * k))


def i_phones(m, k):
    _arc(m, k, (3.2, 2.2, 20.8, 19.8), 180, 360, 1.5)
    _pl(m, k, [(3.2, 11), (3.2, 15)], 1.5)
    _pl(m, k, [(20.8, 11), (20.8, 15)], 1.5)
    _rrect(m, k, (2.2, 13.6, 7.6, 21.4), 2.6, 1.5)
    _rrect(m, k, (16.4, 13.6, 21.8, 21.4), 2.6, 1.5)
    _pl(m, k, [(12, 17.2), (12, 8.4)], 1.5)
    _pl(m, k, [(8.8, 11.4), (12, 8.2), (15.2, 11.4)], 1.5)


def i_mic(m, k):
    _rrect(m, k, (8.2, 1.8, 15.8, 14.6), 3.8, 1.6)
    _arc(m, k, (4.8, 6.2, 19.2, 20.2), 0, 180, 1.6)
    _pl(m, k, [(12, 20.2), (12, 22.6)], 1.6)
    _pl(m, k, [(8, 22.6), (16, 22.6)], 1.6)


def i_slash(m, k):
    _pl(m, k, [(2.6, 21.2), (21.4, 2.6)], 2.4)


def i_x(m, k):
    _pl(m, k, [(5, 5), (19, 19)], 1.9)
    _pl(m, k, [(19, 5), (5, 19)], 1.9)


def i_shop(m, k):
    _arc(m, k, (7.4, 2.4, 16.6, 13), 180, 360, 1.6)
    _rrect(m, k, (2.4, 8.4, 21.6, 11.4), 1.4, 1.6)
    _poly(m, k, [(4.2, 11.4), (5.8, 20.6), (18.2, 20.6), (19.8, 11.4)], 1.6, close=False)


def i_selfview(m, k):
    _rrect(m, k, (2.6, 5.4, 21.4, 20.6), 3.2, 1.6)
    _pl(m, k, [(8.4, 5.4), (9.6, 3), (14.4, 3), (15.6, 5.4)], 1.6)
    _el(m, k, (8.6, 10, 10.6, 12), 0, fill=True)
    _el(m, k, (13.4, 10, 15.4, 12), 0, fill=True)
    _arc(m, k, (8.4, 9.6, 15.6, 17.6), 20, 160, 1.5)


def i_avatar(m, k):
    _el(m, k, (2.4, 2.4, 21.6, 21.6), 1.6)
    _el(m, k, (9.3, 6.6, 14.7, 12), 1.5)
    _arc(m, k, (6.4, 13.2, 17.6, 25), 215, 325, 1.5)


def i_music(m, k):
    _el(m, k, (3.8, 16, 9.2, 21.4), 1.6)
    _el(m, k, (14.2, 14, 19.6, 19.4), 1.6)
    _pl(m, k, [(9.2, 18.4), (9.2, 5.4), (19.6, 3), (19.6, 16.4)], 1.6)
    _pl(m, k, [(9.2, 9.6), (19.6, 7.2)], 1.6)


def i_capture(m, k):
    _rrect(m, k, (2.6, 7, 21.4, 20.6), 3.2, 1.6)
    _pl(m, k, [(8.4, 7), (9.8, 4.4), (14.2, 4.4), (15.6, 7)], 1.6)
    _rrect(m, k, (9.2, 10.8, 14.8, 16.4), 1.4, 1.5)


def i_flag(m, k):
    _pl(m, k, [(5.2, 3), (5.2, 21.6)], 1.6)
    _pl(m, k, [(5.2, 4.8), (11.2, 3.2), (14.6, 5.4), (19.8, 4), (18.4, 9.2), (19.8, 14.2), (14.6, 15.6), (11.2, 13.4), (5.2, 14.8)], 1.5)


def i_trophy(m, k):
    d = ImageDraw.Draw(m)
    d.polygon([(6.2 * k, 3.2 * k), (17.8 * k, 3.2 * k), (17 * k, 11 * k), (14.2 * k, 14 * k), (9.8 * k, 14 * k), (7 * k, 11 * k)], fill=255)
    _rrect(m, k, (10.4, 13, 13.6, 18), 0.6, 0, fill=True)
    _rrect(m, k, (7.2, 17.6, 16.8, 21), 1.2, 0, fill=True)
    _arc(m, k, (2.4, 4.4, 8.6, 10.6), 90, 270, 1.6)
    _arc(m, k, (15.4, 4.4, 21.6, 10.6), 270, 450, 1.6)


def i_backpack(m, k):
    _rrect(m, k, (4.4, 7, 19.6, 21.6), 4.4, 1.6)
    _arc(m, k, (8.6, 2.2, 15.4, 9.6), 180, 360, 1.6)
    _rrect(m, k, (8.2, 13.6, 15.8, 18.6), 1.6, 1.5)


def i_respawn(m, k):
    _arc(m, k, (4, 4, 20, 20), 40, 330, 1.7)
    _pl(m, k, [(15.2, 2.6), (19.2, 5.4), (15.6, 8.8)], 1.7)


def i_people(m, k):
    _el(m, k, (4.4, 3.4, 11, 10), 1.5)
    _arc(m, k, (1.6, 12.8, 13.8, 26), 200, 340, 1.5)
    _el(m, k, (13.4, 4.4, 19, 10), 1.5)
    _arc(m, k, (13.2, 12.8, 22.6, 24), 250, 340, 1.5)
    _pl(m, k, [(3.4, 20.4), (3.4, 18.6)], 1.5)


def i_gear(m, k):
    pts = []
    n = 8
    for i in range(n):
        a0 = (i / n) * 2 * math.pi
        step = 2 * math.pi / n
        for off, rad in ((0.0, 8.2), (0.16, 10.8), (0.34, 10.8), (0.5, 8.2)):
            a = a0 + off * step * 1.9
            pts.append((12 + rad * math.cos(a), 12 + rad * math.sin(a)))
    _poly(m, k, pts, 1.5)
    _el(m, k, (8.4, 8.4, 15.6, 15.6), 1.5)


def i_gallery(m, k):
    _rrect(m, k, (2.6, 3.6, 21.4, 20.4), 2.6, 1.6)
    _pl(m, k, [(2.8, 17.4), (8.6, 11.4), (13.4, 16), (16.6, 13), (21.2, 17.2)], 1.5)
    _el(m, k, (13.8, 6.4, 17.6, 10.2), 1.4)


def i_help(m, k):
    _el(m, k, (2.4, 2.4, 21.6, 21.6), 1.6)
    f = font("b", int(14 * k))
    ImageDraw.Draw(m).text((12 * k, 12.6 * k), "?", font=f, fill=255, anchor="mm")


def i_magnify(m, k):
    _el(m, k, (2.4, 2.4, 17.2, 17.2), 1.7)
    _pl(m, k, [(15.6, 15.6), (21.6, 21.6)], 2.0)
    _pl(m, k, [(6.4, 9.8), (13.2, 9.8)], 1.5)
    _pl(m, k, [(9.8, 6.4), (9.8, 13.2)], 1.5)


def i_chev(m, k):
    _pl(m, k, [(15.4, 4.4), (7.6, 12), (15.4, 19.6)], 2.0)


def i_chev_r(m, k):
    _pl(m, k, [(8.6, 4.4), (16.4, 12), (8.6, 19.6)], 2.0)


def i_grid(m, k):
    _rrect(m, k, (3, 3, 21, 21), 2.2, 1.6)
    _pl(m, k, [(12, 3), (12, 21)], 1.5)
    _pl(m, k, [(3, 12), (21, 12)], 1.5)


def i_list(m, k):
    for y in (6.6, 12, 17.4):
        _el(m, k, (2.8, y - 1.1, 5, y + 1.1), 0, fill=True)
        _pl(m, k, [(8.4, y), (21, y)], 1.6)


def i_hammer(m, k):
    _pl(m, k, [(4.6, 19.4), (12.6, 11.4)], 3.0)
    cx, cy = 13.8, 9.4
    ux, uy = 0.7071, 0.7071
    nx, ny = 0.7071, -0.7071
    hl, hw = 5.0, 2.7
    pts = []
    for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
        pts.append(((cx + ux * hl * sx + nx * hw * sy) * k, (cy + uy * hl * sx + ny * hw * sy) * k))
    ImageDraw.Draw(m).polygon(pts, fill=255)
    _pl(m, k, [(17.2, 15.4), (16, 16.8), (17.2, 18.2)], 0.9)
    _pl(m, k, [(20, 15.4), (21.2, 16.8), (20, 18.2)], 0.9)


def i_robux(m, k):
    pts = [(12 + 10.4 * math.cos(math.radians(a)), 12 + 10.4 * math.sin(math.radians(a))) for a in range(30, 390, 60)]
    _poly(m, k, pts, 1.7)
    _el(m, k, (8.2, 8.2, 15.8, 15.8), 1.7)


def i_badge(m, k):
    _rrect(m, k, (3.6, 3.6, 20.4, 20.4), 3.4, 0, fill=True)
    sq = Image.new("L", m.size, 0)
    _rrect(sq, k, (3.6, 3.6, 20.4, 20.4), 3.4, 0, fill=True)
    sq = sq.rotate(45, resample=Image.BICUBIC, center=(12 * k, 12 * k))
    m.paste(ImageChops.lighter(m, sq), (0, 0))


def i_check(m, k):
    _pl(m, k, [(6.6, 12.6), (10.6, 16.4), (17.6, 8.2)], 2.4)


def i_arrow_up(m, k):
    _pl(m, k, [(12, 19.4), (12, 5.4)], 2.3)
    _pl(m, k, [(6.2, 11.2), (12, 5.4), (17.8, 11.2)], 2.3)


def i_logo_small(m, k):
    sq = Image.new("L", m.size, 0)
    _rrect(sq, k, (3, 3, 21, 21), 3, 0, fill=True)
    _rrect(sq, k, (9.6, 9.6, 14.4, 14.4), 0.5, 0, fill=True, val=0)
    sq = sq.rotate(-13, resample=Image.BICUBIC, center=(12 * k, 12 * k))
    m.paste(sq, (0, 0))


def i_dots(m, k):
    for x in (4.5, 12, 19.5):
        _el(m, k, (x - 1.7, 10.3, x + 1.7, 13.7), 0, fill=True)


ICONS = {
    "roblox": i_roblox, "menu": i_menu, "chat": i_chat, "phones": i_phones, "mic": i_mic,
    "slash": i_slash, "x": i_x, "shop": i_shop, "selfview": i_selfview, "avatar": i_avatar,
    "music": i_music, "capture": i_capture, "flag": i_flag, "trophy": i_trophy,
    "backpack": i_backpack, "respawn": i_respawn, "people": i_people, "gear": i_gear,
    "gallery": i_gallery, "help": i_help, "magnify": i_magnify, "chev": i_chev,
    "chev_r": i_chev_r, "grid": i_grid, "list": i_list, "hammer": i_hammer,
    "robux": i_robux, "badge": i_badge, "check": i_check, "arrow_up": i_arrow_up,
    "logo_small": i_logo_small, "dots": i_dots,
}


def name_color(name):
    palette = [(253, 41, 67), (1, 162, 255), (2, 184, 87), (107, 50, 124), (218, 133, 65), (245, 205, 48), (232, 186, 200), (215, 197, 154)]
    n = len(name)
    v = 0
    for i in range(1, n + 1):
        c = ord(name[i - 1]) % 256
        rev = n - i + 1
        if n % 2 == 1:
            rev -= 1
        if rev % 4 >= 2:
            c = -c
        v += c
    return palette[v % len(palette)]


PANEL = (21, 23, 26, 178)
TOPC = (14, 17, 18, 236)
TILEC = (36, 39, 46, 255)
BTNC = (45, 46, 49, 255)
BLUE = (54, 88, 243, 255)
WHITE = (255, 255, 255, 255)
GRAY = (156, 158, 161, 255)
MENU_ITEMS = [
    ("shop", "Shop", "shop"),
    ("selfview", "Self View", "selfview"),
    ("avatar", "Switch avatar", "avatar"),
    ("music", "Music", "music"),
    ("capture", "Captures", "capture"),
    ("report", "Report", "flag"),
    ("leaderboard", "Leaderboard", "trophy"),
    ("inventory", "Inventory", "backpack"),
    ("respawn", "Respawn", "respawn"),
]
TABS = [("people", "People", "people"), ("settings", "Settings", "gear"), ("gallery", "Gallery", "gallery"), ("report", "Report", "flag"), ("help", "Help", "help")]
SETTINGS = [
    ("Fullscreen", "toggle", "fullscreen"),
    ("Show Chat", "toggle", "chat"),
    ("Show Player List", "toggle", "plist"),
    ("Camera Inverted", "toggle", "invert"),
    ("Shift Lock Switch", "toggle", "shiftlock"),
    ("Performance Stats", "toggle", "stats"),
    ("Master Volume", "slider", "volume"),
    ("Camera Sensitivity", "slider", "sens"),
    ("Graphics Quality", "slider", "quality"),
    ("Graphics Mode", "value", "Automatic"),
]
HELP_ROWS = [
    ("Move", ["W", "A", "S", "D"]),
    ("Jump", ["Space"]),
    ("Chat", ["/"]),
    ("Menu", ["Esc"]),
    ("Zoom In / Out", ["I", "O"]),
    ("Rotate Camera", ["Right Mouse"]),
    ("Toggle Mouse Lock", ["Shift"]),
    ("Respawn", ["R"]),
    ("Leave", ["L"]),
]
ITEMS = [
    (None, "Classic Pants", "cold ribbon", False),
    ("Brown Scene Hair", "Hair", "Roblox", True),
    ("Classic Shirt", "Classic Shirt", "cold ribbon", False),
    ("Smile", "Face", "Roblox", True),
    ("Man Head", "Head", "Roblox", True),
]


def prep_avatar(img):
    img = img.convert("RGBA")
    bb = img.getchannel("A").getbbox() or (0, 0, img.width, img.height)
    body = img.crop(bb)
    bw, bh = body.size
    hw = int(bw * 0.78)
    hh = int(hw / 1.477)
    x0 = max(0, (bw - hw) // 2)
    head = Image.new("RGBA", (hw, hh), (0, 0, 0, 0))
    head.paste(body.crop((x0, 0, min(bw, x0 + hw), min(bh, hh))), (0, int(hh * 0.08)))
    return body, head


class Ui:
    def __init__(self, display, username, avatar_img):
        self.display = display
        self.username = username
        self.body, self.head = prep_avatar(avatar_img)
        self.ncolor = name_color(username)
        self.msgs = [{"sys": True, "text": "Roblox automatically translates supported languages in chat"}]
        self.chat_vis = True
        self.focus = False
        self.text = ""
        self.caret = 0
        self.caret_on = True
        self.blink = 0.0
        self.plist = True
        self.popup = False
        self.dd = False
        self.voice = 0
        self.toast = None
        self.menu = False
        self.tab = "people"
        self.view = "grid"
        self.page = False
        self.selfview = False
        self.fade = 0.0
        self.last = time.time()
        self.scr = {}
        self.smax = {}
        self.tog = {"fullscreen": False, "invert": False, "shiftlock": True, "stats": False}
        self.val = {"volume": 0.5, "sens": 0.5, "quality": 0.6}
        self.sgeom = {}
        self.regions = []
        self.hover = None
        self.quit = False
        self.W = 0
        self.H = 0
        self.imgcache = {}

    @property
    def needs_kbd(self):
        return self.focus or self.menu or self.page

    def reg(self, name, x, y, w, h, cur="hand", sc=None, modal=False, clip=None):
        if clip is not None:
            cx, cy, cw, chh = clip
            nx = max(x, cx)
            ny = max(y, cy)
            ex = min(x + w, cx + cw)
            ey = min(y + h, cy + chh)
            if ex <= nx or ey <= ny:
                return
            x, y, w, h = nx, ny, ex - nx, ey - ny
        self.regions.append({"n": name, "r": (x, y, w, h), "cur": cur, "sc": sc, "modal": modal})

    def hit(self, x, y):
        for r in reversed(self.regions):
            rx, ry, rw, rh = r["r"]
            if rx <= x < rx + rw and ry <= y < ry + rh:
                return r
        return None

    def set_hover(self, name):
        if name != self.hover:
            self.hover = name
            return True
        return False

    def say(self, title, body, secs=4.0, w=None):
        self.toast = {"title": title, "body": body, "until": time.time() + secs, "w": w}

    def close_menus(self):
        self.menu = False
        self.page = False
        self.dd = False
        self.popup = False

    def open_menu(self, tab=None):
        self.dd = False
        self.popup = False
        self.page = False
        self.focus = False
        if tab:
            self.tab = tab
            self.scr["body"] = 0
        if not self.menu:
            self.menu = True
            self.fade = 0.0
            self.last = time.time()

    def send(self):
        t = self.text.strip()
        self.text = ""
        self.caret = 0
        self.focus = False
        if t:
            self.msgs.append({"name": self.display, "color": self.ncolor, "text": t[:200]})
            if len(self.msgs) > 120:
                del self.msgs[1:20]
            self.scr.pop("chat", None)

    def on_char(self, ch):
        if not self.focus:
            return False
        if ord(ch[0]) < 32 or ord(ch[0]) == 127:
            return False
        if len(self.text) >= 200:
            return True
        self.text = self.text[: self.caret] + ch + self.text[self.caret:]
        self.caret += len(ch)
        self.caret_on = True
        self.blink = time.time()
        return True

    def paste(self, s):
        s = " ".join(s.replace("\r", " ").replace("\n", " ").split())
        room = 200 - len(self.text)
        s = s[:room]
        self.text = self.text[: self.caret] + s + self.text[self.caret:]
        self.caret += len(s)

    def on_key(self, vk, ctrl=False):
        if self.focus:
            if vk == 13:
                self.send()
            elif vk == 27:
                self.focus = False
            elif vk == 8:
                if self.caret > 0:
                    self.text = self.text[: self.caret - 1] + self.text[self.caret:]
                    self.caret -= 1
            elif vk == 46:
                self.text = self.text[: self.caret] + self.text[self.caret + 1:]
            elif vk == 37:
                self.caret = max(0, self.caret - 1)
            elif vk == 39:
                self.caret = min(len(self.text), self.caret + 1)
            elif vk == 36:
                self.caret = 0
            elif vk == 35:
                self.caret = len(self.text)
            elif vk == 0x56 and ctrl:
                return "paste"
            self.caret_on = True
            self.blink = time.time()
            return None
        if vk == 27:
            self.esc()
        elif self.menu:
            if vk == 0x4C:
                self.quit = True
            elif vk == 0x52:
                self.close_menus()
        return None

    def esc(self):
        if self.focus:
            self.focus = False
        elif self.page:
            self.page = False
        elif self.menu:
            self.menu = False
        elif self.dd:
            self.dd = False
        elif self.popup:
            self.popup = False
        else:
            self.open_menu()

    def slash(self):
        if self.menu or self.page:
            return
        self.chat_vis = True
        self.focus = True
        self.dd = False
        self.popup = False
        self.caret = len(self.text)
        self.caret_on = True
        self.blink = time.time()

    def lost_focus(self):
        self.focus = False

    def down(self, name):
        if self.focus and not (name and name.startswith("chat")):
            self.focus = False
        if self.dd and not (name and (name.startswith("dd") or name == "tb_menu")):
            self.dd = False
        if self.popup and not (name and (name.startswith("popup") or name == "pl_row")):
            self.popup = False

    def click(self, name):
        if not name:
            return
        if name == "logo":
            if self.menu or self.page:
                self.close_menus()
            else:
                self.open_menu("people")
        elif name == "tb_menu":
            if self.menu or self.page:
                self.close_menus()
                self.dd = True
            else:
                self.dd = not self.dd
            self.popup = False
            self.scr["dd"] = 0
        elif name == "tb_chat":
            self.chat_vis = not self.chat_vis
            if not self.chat_vis:
                self.focus = False
        elif name == "tb_voice":
            if self.voice == 0:
                self.voice = 1
                self.say("You're connected to Voice Chat", "Voice chat & recording are enabled for trusted friends and\npeople in similar age groups. Your voice may be shared.", 6.0, 403)
            elif self.voice == 1:
                self.voice = 2
            else:
                self.voice = 1
        elif name == "chat_input":
            self.focus = True
            self.caret = len(self.text)
            self.caret_on = True
            self.blink = time.time()
        elif name == "chat_send":
            self.send()
        elif name == "chat_dots":
            self.msgs = self.msgs[:1]
            self.scr.pop("chat", None)
        elif name == "pl_close":
            self.plist = False
            self.popup = False
        elif name == "pl_row":
            self.popup = not self.popup
        elif name == "popup_examine":
            self.popup = False
            self.page = True
            self.fade = 0.0
            self.scr["page"] = 0
            self.last = time.time()
        elif name.startswith("dd_"):
            self.dd_action(name[3:])
        elif name == "dim":
            self.close_menus()
        elif name.startswith("tab_"):
            self.tab = name[4:]
            self.scr["body"] = 0
        elif name == "view_grid":
            self.view = "grid"
        elif name == "view_list":
            self.view = "list"
        elif name.startswith("tile_"):
            self.menu = False
            self.page = True
            self.fade = 0.0
            self.scr["page"] = 0
            self.last = time.time()
        elif name == "btn_leave":
            self.quit = True
        elif name in ("btn_respawn", "btn_resume"):
            self.close_menus()
        elif name == "page_back":
            self.page = False
        elif name == "buy":
            self.say("Buy items", "The Avatar Shop isn't available in this overlay.", 3.5)
        elif name.startswith("set_"):
            key = name[4:]
            if key == "chat":
                self.chat_vis = not self.chat_vis
            elif key == "plist":
                self.plist = not self.plist
            else:
                self.tog[key] = not self.tog[key]
        elif name.startswith("rep_"):
            self.say("Report", "Reporting isn't available in this overlay.", 3.5)
        elif name == "gal_take":
            self.say("Captures", "Captures aren't available in this overlay.", 3.5)

    def dd_action(self, key):
        if key == "shop":
            self.dd = False
            self.say("Shop", "The Avatar Shop isn't available in this overlay.", 3.5)
        elif key == "selfview":
            self.dd = False
            self.selfview = not self.selfview
        elif key == "avatar":
            self.dd = False
            self.page = True
            self.fade = 0.0
            self.scr["page"] = 0
            self.last = time.time()
        elif key == "music":
            self.dd = False
            self.say("Music", "No music is playing in this experience.", 3.5)
        elif key == "capture":
            self.open_menu("gallery")
        elif key == "report":
            self.open_menu("report")
        elif key == "leaderboard":
            self.dd = False
            self.plist = not self.plist
            if not self.plist:
                self.popup = False
        elif key == "inventory":
            self.dd = False
            self.say("Inventory", "Your inventory is empty.", 3.5)
        elif key == "respawn":
            self.dd = False

    def wheel(self, x, y, delta):
        for r in reversed(self.regions):
            rx, ry, rw, rh = r["r"]
            if rx <= x < rx + rw and ry <= y < ry + rh:
                if r["sc"]:
                    k = r["sc"]
                    mx = self.smax.get(k, 0)
                    cur = self.scr.get(k)
                    if k == "chat" and cur is None:
                        cur = mx
                    cur = cur or 0
                    nxt = max(0, min(mx, cur - delta / 120.0 * 40))
                    if k == "chat":
                        self.scr["chat"] = None if nxt >= mx else nxt
                    else:
                        self.scr[k] = nxt
                    return True
                if r["modal"]:
                    return False
        return False

    def slider_set(self, key, x):
        g = self.sgeom.get(key)
        if not g:
            return False
        v = max(0.0, min(1.0, (x - g[0]) / float(g[1])))
        if abs(v - self.val[key]) > 0.002:
            self.val[key] = v
            return True
        return False

    def step(self, now):
        ch = False
        if self.focus and now - self.blink > 0.53:
            self.caret_on = not self.caret_on
            self.blink = now
            ch = True
        if self.toast and now > self.toast["until"]:
            self.toast = None
            ch = True
        target = 1.0 if (self.menu or self.page) else 0.0
        if target > self.fade:
            self.fade = min(1.0, self.fade + (now - self.last) / 0.14)
            ch = True
        elif target < self.fade:
            self.fade = 0.0
            ch = True
        self.last = now
        return ch

    def scaled(self, img, key, w, h, S):
        W = max(1, int(round(w * S)))
        H = max(1, int(round(h * S)))
        k = (key, W, H)
        r = self.imgcache.get(k)
        if r is None:
            r = img.resize((W, H), Image.LANCZOS)
            if len(self.imgcache) > 40:
                self.imgcache.clear()
            self.imgcache[k] = r
        return r

    def fit_body(self, h, S):
        w = h * self.body.width / float(self.body.height)
        return self.scaled(self.body, "body", w, h, S), w

    def render(self, PW, PH, S, now):
        self.regions = []
        cv = Cv(PW, PH, S, physical=True)
        W, H = cv.w, cv.h
        self.W, self.H = W, H
        hv = self.hover
        if self.chat_vis:
            self.d_chat(cv, hv, S)
        if self.plist:
            self.d_plist(cv, hv, S)
        if self.selfview:
            self.d_selfview(cv, W, S)
        if self.popup and self.plist:
            self.d_popup(cv, W, hv, S)
        if self.toast:
            self.d_toast(cv, W)
        modal = self.menu or self.page
        if modal:
            a = 0.5 * max(self.fade, 0.001)
            cv.comp(Image.new("RGBA", (cv.W, cv.H), (0, 0, 0, int(255 * a))), 0, 0)
            self.reg("dim", 0, 0, W, H, cur="arrow", modal=True)
            if self.menu:
                self.d_menu(cv, W, H, hv, S)
            else:
                self.d_page(cv, W, H, hv, S)
        self.d_top(cv, hv, modal)
        if self.dd and not modal:
            self.d_dd(cv, H, hv, S)
        return cv.im

    def d_top(self, cv, hv, modal):
        hl = (255, 255, 255, 30)
        cv.circle(39, 33, 44, TOPC)
        if hv == "logo":
            cv.circle(39, 33, 44, hl)
        cv.icon("roblox", 39, 33, 26, WHITE)
        self.reg("logo", 17, 11, 44, 44)
        cv.rr(70, 11, 140, 44, 22, TOPC)
        cx = [96, 141, 185]
        dim = 0.38 if modal else 1.0
        col = (255, 255, 255, int(255 * dim))
        names = ["tb_menu", "tb_chat", "tb_voice"]
        for i, n in enumerate(names):
            sel = (i == 0 and self.dd)
            if sel:
                cv.circle(cx[i], 33, 38, (255, 255, 255, 40))
            elif hv == n and (not modal or i == 0):
                cv.circle(cx[i], 33, 38, (255, 255, 255, 26))
        cv.icon("x" if self.dd else "menu", cx[0], 33, 24, WHITE)
        cv.icon("chat", cx[1], 33, 24, col if self.chat_vis else (255, 255, 255, int(255 * dim * 0.5)))
        if self.voice == 0:
            cv.icon("phones", cx[2], 33, 24, col)
        else:
            cv.icon("mic", cx[2], 33, 24, col)
            if self.voice == 1:
                cv.icon("slash", cx[2], 33, 24, (244, 67, 96, int(255 * dim)))
        for i, n in enumerate(names):
            if modal and i > 0:
                self.reg("tb_dead", cx[i] - 22, 11, 44, 44, cur="arrow")
            else:
                self.reg(n, cx[i] - 22, 11, 44, 44)

    def lines(self, maxw, S):
        out = []
        sp = text_w(" ", "m", 14, S)
        for m in self.msgs:
            words = []
            if m.get("sys"):
                for w in m["text"].split(" "):
                    words.append((w, "m", (240, 241, 243, 255)))
            else:
                words.append((m["name"] + ":", "b", m["color"] + (255,)))
                for w in m["text"].split(" "):
                    words.append((w, "m", WHITE))
            cur = []
            cw = 0.0
            for w, wt, col in words:
                if not w:
                    continue
                ww = text_w(w, wt, 14, S)
                while ww > maxw:
                    n = len(w)
                    while n > 1 and text_w(w[:n], wt, 14, S) > maxw - cw:
                        n -= 1
                    if cur and n <= 1:
                        out.append(cur)
                        cur = []
                        cw = 0.0
                        continue
                    cur.append((w[:n], wt, col, cw))
                    out.append(cur)
                    cur = []
                    cw = 0.0
                    w = w[n:]
                    ww = text_w(w, wt, 14, S)
                gap = sp if cur else 0.0
                if cur and cw + gap + ww > maxw:
                    out.append(cur)
                    cur = []
                    cw = 0.0
                    gap = 0.0
                cur.append((w, wt, col, cw + gap))
                cw += gap + ww
            if cur:
                out.append(cur)
        return out

    def d_chat(self, cv, hv, S):
        x, y, w, h = 9, 62, 434, 173
        hot = self.focus or (hv is not None and hv.startswith("chat"))
        self.reg("chat_zone", x, y, w, h, cur="arrow")
        ih = 40
        iy = y + h - 9 - ih
        if hot:
            cv.rr(x, y, w, h, 8, PANEL)
            for i in range(3):
                cv.circle(x + w - 28 + i * 6, y + 24, 2.6, (226, 228, 230, 235))
            self.reg("chat_dots", x + w - 40, y + 10, 34, 28)
            ix = x + 8
            iw = w - 16
            cv.rr(ix, iy, iw, ih, 20, (32, 33, 36, 250))
            self.reg("chat_input", ix, iy, iw, ih, cur="ibeam")
            avail = iw - 22 - 56
            sub = Cv(avail + 4, ih, S)
            cw = text_w(self.text[: self.caret], "m", 15, S)
            off = max(0.0, cw - avail)
            if self.text:
                sub.text(-off, ih / 2.0, self.text, "m", 15, WHITE)
            elif not self.focus:
                sub.text(0, ih / 2.0, "To chat click here or press / key", "m", 15, (170, 172, 176, 255))
            if self.focus and self.caret_on:
                sub.rr(cw - off, ih / 2.0 - 9, 1.5, 18, 0, WHITE)
            cv.blit(sub, ix + 22, iy)
            if self.text:
                cv.circle(ix + iw - 20, iy + ih / 2.0, 32, BLUE)
                if hv == "chat_send":
                    cv.circle(ix + iw - 20, iy + ih / 2.0, 32, (255, 255, 255, 30))
                cv.icon("arrow_up", ix + iw - 20, iy + ih / 2.0, 22, WHITE)
                self.reg("chat_send", ix + iw - 36, iy + 4, 32, 32)
            else:
                cv.icon("mic", ix + iw - 26, iy + ih / 2.0, 22, (190, 192, 196, 255))
        ax = x + 9
        ay = y + 7
        aw = w - 18
        ah = (iy - 6) - ay
        lines = self.lines(aw, S)
        ch = len(lines) * 20
        mx = max(0, ch - ah)
        self.smax["chat"] = mx
        cur = self.scr.get("chat")
        off = mx if cur is None else min(cur, mx)
        sub = Cv(aw + 8, ah, S)
        for i, ln in enumerate(lines):
            ly = i * 20 - off + 10
            if ly < -12 or ly > ah + 12:
                continue
            for wd, wt, col, lx in ln:
                sub.text(lx + 2, ly, wd, wt, 14, col, stroke=None if hot else (1, (0, 0, 0, 200)))
        cv.blit(sub, ax - 2, ay)
        self.reg("chat_scroll", ax, ay, aw, ah, cur="arrow", sc="chat")

    def d_plist(self, cv, hv, S):
        pw, ph = 166, 64
        px = cv.w - 6 - pw
        py = 62
        cv.rr(px, py, pw, ph, 8, PANEL)
        row = (255, 255, 255, 40 if hv == "pl_row" else 22)
        cv.rr(px, py + 19, pw, 36, 0, row)
        cv.icon("x", px + 11, py + 10, 14, WHITE)
        cv.icon("hammer", px + 22, py + 37, 20, (205, 209, 212, 255))
        cv.text(px + 40, py + 37, fit_text(self.display, "m", 14.5, 116, S), "m", 14.5, (240, 242, 244, 255), maxw=118)
        self.reg("pl_close", px, py, 36, 19)
        self.reg("pl_row", px, py + 19, pw, 36)
        self.reg("pl_panel", px, py, pw, ph, cur="arrow")
        self.plist_rect = (px, py, pw, ph)

    def d_selfview(self, cv, W, S):
        x = W - 6 - 150
        y = 62 + 64 + 8
        cv.rr(x, y, 150, 150, 10, (21, 23, 26, 215))
        cv.rr(x + 8, y + 8, 134, 134, 8, (46, 52, 60, 230))
        img = self.scaled(self.head, "headsv", 134, 91, S)
        cv.paste_img(img, x + 8, y + 8 + 43, 134, 91)
        self.reg("selfview", x, y, 150, 150, cur="arrow")

    def d_popup(self, cv, W, hv, S):
        pw, ph = 302, 121
        x = W - 6 - 166 - 4 - pw
        y = 80
        cv.rr(x, y, pw, ph, 10, PANEL)
        hd = Cv(pw, 75, S)
        hd.rr(0, 0, pw, 75, 0, (35, 36, 39, 232))
        for i in range(65):
            t = i / 64.0
            c = lerp((52, 58, 68), (26, 29, 35), t)
            hd.rr(0, i, 96, 1.02, 0, c + (255,))
        hd.paste_img(self.scaled(self.head, "head", 96, 65, S), 0, 0, 96, 65)
        hd.round_clip(10)
        hd.im = hd.im.crop((0, 0, hd.W, hd.p(65)))
        hd.H = hd.im.height
        cv.blit(hd, x, y)
        cv.text(x + 107, y + 23, self.display, "b", 17, WHITE, maxw=pw - 120)
        cv.text(x + 107, y + 46, "@" + self.username, "m", 15, (178, 180, 184, 255), maxw=pw - 120)
        cv.rr(x, y + 65, pw, 1, 0, (255, 255, 255, 26))
        if hv == "popup_examine":
            b = Cv(pw, 56, S)
            b.rr(0, -20, pw, 76, 10, (255, 255, 255, 22))
            cv.blit(b, x, y + 65)
        cv.icon("magnify", x + 27, y + 94, 28, WHITE)
        cv.text(x + 56, y + 94, "Examine Avatar", "b", 17, WHITE)
        self.reg("popup_panel", x, y, pw, ph, cur="arrow")
        self.reg("popup_examine", x, y + 65, pw, 56)

    def d_toast(self, cv, W):
        t = self.toast
        body = t["body"].split("\n")
        tw = text_w(t["title"], "b", 17, cv.S)
        for ln in body:
            tw = max(tw, text_w(ln, "r", 14, cv.S))
        w = max(t.get("w") or 0, tw + 48, 260)
        h = 45 + 16.5 * len(body)
        x = (W - w) / 2.0
        y = 20
        cv.rr(x, y, w, h, 12, TILEC)
        cv.text(x + 24, y + 23, t["title"], "b", 17, WHITE)
        for i, ln in enumerate(body):
            cv.text(x + 24, y + 43 + i * 16.5, ln, "r", 14, (205, 208, 213, 255))
        self.reg("toast", x, y, w, h, cur="arrow")

    def d_dd(self, cv, H, hv, S):
        x, y, w = 17, 59, 193
        content = len(MENU_ITEMS) * 56 + 12
        h = max(120, min(content, H - 59 - 60))
        cv.rr(x, y, w, h, 12, (22, 22, 25, 246))
        ah = h - 12
        mx = max(0, content - 12 - ah)
        self.smax["dd"] = mx
        off = min(self.scr.get("dd", 0) or 0, mx)
        self.scr["dd"] = off
        sub = Cv(w, ah, S)
        for i, (key, label, ic) in enumerate(MENU_ITEMS):
            ry = i * 56 - off
            if ry > ah or ry + 56 < 0:
                continue
            if hv == "dd_" + key:
                sub.rr(6, ry + 2, w - 12, 52, 8, (255, 255, 255, 26))
            sub.icon(ic, 33, ry + 28, 26, (255, 255, 255, 255))
            sub.text(61, ry + 28, label, "b", 16.5, WHITE)
        cv.blit(sub, x, y + 6)
        self.reg("dd_panel", x, y, w, h, cur="arrow")
        self.reg("dd_scroll", x, y + 6, w, ah, cur="arrow", sc="dd")
        for i, (key, label, ic) in enumerate(MENU_ITEMS):
            self.reg("dd_" + key, x, y + 6 + i * 56 - off, w, 56, clip=(x, y + 6, w, ah))
        if mx > 0:
            th = max(24, ah * ah / float(content - 12))
            ty = y + 6 + (ah - th) * (off / float(mx))
            cv.rr(x + w - 5, ty, 2, th, 1, (255, 255, 255, 70))

    def d_menu(self, cv, W, H, hv, S):
        mw = max(520, min(1100, W * 0.777))
        mw = min(mw, W - 20)
        mh = max(330, min(700, H * 0.82))
        mh = min(mh, H - 20)
        x0 = (W - mw) / 2.0
        y0 = (H - mh) / 2.0 + 10
        y0 = max(8, min(y0, H - mh - 8))
        m = Cv(mw, mh, S)
        m.rr(0, 0, mw, mh, 12, (24, 24, 25, 240))
        self.reg("menu_panel", x0, y0, mw, mh, cur="arrow")
        iw = mw - 44
        tw = iw / 5.0
        for i, (key, label, ic) in enumerate(TABS):
            sel = self.tab == key
            col = WHITE if sel else (GRAY if hv != "tab_" + key else (214, 216, 219, 255))
            lw = text_w(label, "b", 16, S)
            gx = 22 + i * tw + (tw - (24 + 8 + lw)) / 2.0
            m.icon(ic, gx + 12, 32, 24, col)
            m.text(gx + 32, 32, label, "b", 16, col)
            self.reg("tab_" + key, x0 + 22 + i * tw, y0, tw, 60)
        m.rr(22, 60, iw, 1, 0, (255, 255, 255, 36))
        sel_i = [t[0] for t in TABS].index(self.tab)
        m.rr(22 + sel_i * tw, 59, tw, 2, 0, WHITE)
        bx, by = 22, 62
        bw = iw
        fy = mh - 68
        bh = fy - by - 4
        body = Cv(bw, bh, S)
        clip = (x0 + bx, y0 + by, bw, bh)
        self.reg("body", clip[0], clip[1], bw, bh, cur="arrow", sc="body")
        off = self.scr.get("body", 0) or 0
        content = getattr(self, "b_" + self.tab)(body, bw, bh, hv, S, x0 + bx, y0 + by, clip)
        mx = max(0, content - bh)
        self.smax["body"] = mx
        if off > mx:
            self.scr["body"] = mx
        m.blit(body, bx, by)
        if mx > 0:
            o = min(self.scr.get("body", 0) or 0, mx)
            th = max(24, bh * bh / float(content))
            ty = by + (bh - th) * (o / float(mx))
            m.rr(mw - 14, ty, 2, th, 1, (255, 255, 255, 60))
        fx = 19
        fw = mw - 38
        bwid = (fw - 20) / 3.0
        defs = [("btn_leave", "Leave", "L"), ("btn_respawn", "Respawn", "R"), ("btn_resume", "Resume", "ESC")]
        for i, (n, label, key) in enumerate(defs):
            bx2 = fx + i * (bwid + 10)
            h2 = hv == n
            if n == "btn_resume":
                m.rr(bx2 - 3, fy - 3, bwid + 6, 55, 10, WHITE, ring=2)
                m.rr(bx2, fy, bwid, 49, 8, (46, 62, 140, 255) if h2 else (35, 49, 113, 255))
            else:
                m.rr(bx2, fy, bwid, 49, 8, (62, 64, 68, 255) if h2 else BTNC)
            lw = text_w(label, "b", 17, S)
            gx = bx2 + (bwid - (24 + 14 + lw)) / 2.0
            m.rr(gx, fy + 12.5, 24, 24, 5, (255, 255, 255, 235), ring=2)
            m.text(gx + 12, fy + 24.5, key, "b", 10.5 if key == "ESC" else 13, WHITE, anchor="m")
            m.text(gx + 38, fy + 24.5, label, "b", 17, WHITE)
            self.reg(n, x0 + bx2, y0 + fy, bwid, 49)
        cv.blit(m, x0, y0, alpha=self.fade if self.fade < 1 else 1.0)

    def b_people(self, b, bw, bh, hv, S, ax, ay, clip):
        off = self.scr.get("body", 0) or 0
        b.text(10, 39 - off, "In this server", "b", 20, WHITE)
        tx = bw - 12 - 86
        b.rr(tx, 24 - off, 86, 30, 8, (255, 255, 255, 16))
        gsel = self.view == "grid"
        b.rr(tx + (2 if gsel else 44), 26 - off, 40, 26, 6, (52, 53, 58, 255))
        b.icon("grid", tx + 22, 39 - off, 18, WHITE if gsel else GRAY)
        b.icon("list", tx + 64, 39 - off, 18, GRAY if gsel else WHITE)
        self.reg("view_grid", ax + tx, ay + 24 - off, 43, 30, clip=clip)
        self.reg("view_list", ax + tx + 43, ay + 24 - off, 43, 30, clip=clip)
        if self.view == "grid":
            ty = 80 - off
            col = TILEC if hv != "tile_0" else (46, 49, 57, 255)
            b.rr(9, ty, 146, 146, 8, col)
            img, iw = self.fit_body(110, S)
            b.paste_img(img, 9 + (146 - iw) / 2.0, ty + 18, iw, 110)
            b.text(17, ty + 166, self.display, "b", 15, WHITE, maxw=130)
            b.text(17, ty + 185, "@" + self.username, "m", 14, (200, 202, 206, 255), maxw=130)
            self.reg("tile_0", ax + 9, ay + ty, 146, 146, clip=clip)
            return 80 + 146 + 40
        ty = 76 - off
        col = TILEC if hv != "tile_0" else (46, 49, 57, 255)
        b.rr(9, ty, bw - 30, 64, 8, col)
        b.rr(17, ty + 8, 48, 48, 24, (24, 27, 33, 255))
        hd = Cv(48, 48, S)
        hd.paste_img(self.scaled(self.head, "headl", 62, 42, S), -7, 3, 62, 42)
        hd.round_clip(24)
        b.blit(hd, 17, ty + 8)
        b.text(80, ty + 22, self.display, "b", 15.5, WHITE, maxw=bw - 150)
        b.text(80, ty + 43, "@" + self.username, "m", 14, (200, 202, 206, 255), maxw=bw - 150)
        self.reg("tile_0", ax + 9, ay + ty, bw - 30, 64, clip=clip)
        return 76 + 64 + 20

    def b_settings(self, b, bw, bh, hv, S, ax, ay, clip):
        off = self.scr.get("body", 0) or 0
        b.text(10, 39 - off, "Settings", "b", 20, WHITE)
        y = 70 - off
        for label, kind, key in SETTINGS:
            b.text(10, y + 28, label, "m", 16, WHITE)
            b.rr(0, y + 55, bw - 22, 1, 0, (255, 255, 255, 20))
            rx = bw - 22
            if kind == "toggle":
                if key == "chat":
                    on = self.chat_vis
                elif key == "plist":
                    on = self.plist
                else:
                    on = self.tog[key]
                b.rr(rx - 52, y + 16, 48, 24, 12, BLUE if on else (88, 90, 96, 255))
                kx = rx - 52 + (27 if on else 3)
                b.circle(kx + 9, y + 28, 18, WHITE)
                self.reg("set_" + key, ax + rx - 56, ay + y + 8, 56, 40, clip=clip)
            elif kind == "slider":
                sw = 240
                sx = rx - sw - 10
                v = self.val[key]
                b.rr(sx, y + 26, sw, 4, 2, (88, 90, 96, 255))
                b.rr(sx, y + 26, sw * v, 4, 2, BLUE)
                b.circle(sx + sw * v, y + 28, 18, WHITE)
                b.text(sx - 14, y + 28, "%d" % round(v * 100), "m", 15, (200, 202, 206, 255), anchor="r")
                self.sgeom[key] = (ax + sx, sw)
                self.reg("slider_" + key, ax + sx - 10, ay + y + 12, sw + 20, 32, clip=clip)
            else:
                b.text(rx - 4, y + 28, key, "m", 15, (200, 202, 206, 255), anchor="r")
            y += 56
        return 70 + len(SETTINGS) * 56 + 10

    def b_gallery(self, b, bw, bh, hv, S, ax, ay, clip):
        cx = bw / 2.0
        b.icon("gallery", cx, bh / 2.0 - 40, 44, (120, 122, 128, 255))
        b.text(cx, bh / 2.0 + 4, "No captures yet", "b", 19, WHITE, anchor="m")
        b.text(cx, bh / 2.0 + 30, "Captures you take in an experience will show up here.", "m", 14.5, (170, 172, 176, 255), anchor="m")
        bt = hv == "gal_take"
        b.rr(cx - 70, bh / 2.0 + 52, 140, 38, 8, (46, 62, 140, 255) if bt else (35, 49, 113, 255))
        b.text(cx, bh / 2.0 + 71, "Take capture", "b", 15, WHITE, anchor="m")
        self.reg("gal_take", ax + cx - 70, ay + bh / 2.0 + 52, 140, 38, clip=clip)
        return bh

    def b_report(self, b, bw, bh, hv, S, ax, ay, clip):
        off = self.scr.get("body", 0) or 0
        b.text(10, 39 - off, "Report", "b", 20, WHITE)
        rows = [("Report a player", "Report someone for breaking the rules"), ("Report an experience", "Report content in this experience"), ("Report a bug", "Tell us something isn't working")]
        y = 70 - off
        for i, (t, s) in enumerate(rows):
            col = (46, 49, 57, 255) if hv == "rep_%d" % i else TILEC
            b.rr(10, y, bw - 42, 64, 8, col)
            b.text(30, y + 22, t, "b", 16, WHITE)
            b.text(30, y + 43, s, "m", 14, (176, 178, 183, 255))
            b.icon("chev_r", bw - 54, y + 32, 22, GRAY)
            self.reg("rep_%d" % i, ax + 10, ay + y, bw - 42, 64, clip=clip)
            y += 74
        return 70 + 3 * 74

    def b_help(self, b, bw, bh, hv, S, ax, ay, clip):
        off = self.scr.get("body", 0) or 0
        b.text(10, 39 - off, "Controls", "b", 20, WHITE)
        y = 70 - off
        for label, keys in HELP_ROWS:
            b.text(10, y + 22, label, "m", 16, WHITE)
            x = bw - 32
            for k in reversed(keys):
                kw = max(32, text_w(k, "b", 13.5, S) + 22)
                x -= kw
                b.rr(x, y + 6, kw, 32, 7, BTNC)
                b.text(x + kw / 2.0, y + 22, k, "b", 13.5, WHITE, anchor="m")
                x -= 8
            b.rr(0, y + 43, bw - 22, 1, 0, (255, 255, 255, 20))
            y += 48
        return 70 + len(HELP_ROWS) * 48 + 10

    def d_page(self, cv, W, H, hv, S):
        pw = max(420, min(806, W - 40))
        ph = max(240, H - 82 - 23)
        x0 = (W - pw) / 2.0
        y0 = 82 if H > ph + 82 else max(8, (H - ph) / 2.0)
        m = Cv(pw, ph, S)
        m.rr(0, 0, pw, ph, 12, (24, 24, 25, 240))
        self.reg("page_panel", x0, y0, pw, ph, cur="arrow")
        if hv == "page_back":
            m.circle(28, 29, 36, (255, 255, 255, 24))
        m.icon("chev", 28, 29, 24, WHITE)
        self.reg("page_back", x0 + 8, y0 + 8, 40, 42)
        img, iw = self.fit_body(125, S)
        m.paste_img(img, (pw - iw) / 2.0, 7, iw, 125)
        lx = max(40, (pw - 806) / 2.0 + 98)
        m.text(lx, 152, "%s's Avatar" % self.username, "b", 22, WHITE, maxw=pw - lx - 190)
        tx = lx
        tx += m.text(tx, 176, "Total (%d items)  \u00b7  " % len(ITEMS), "m", 15.5, (205, 207, 210, 255))
        m.icon("robux", tx + 9, 176, 18, (205, 207, 210, 255))
        m.text(tx + 24, 176, "0", "m", 15.5, (205, 207, 210, 255))
        bx = min(pw - 121 - 40, lx + 490)
        b = hv == "buy"
        m.rr(bx, 142, 121, 39, 8, (48, 66, 150, 255) if b else (40, 56, 133, 255))
        m.text(bx + 60.5, 161.5, "Buy items", "b", 16, WHITE, anchor="m")
        self.reg("buy", x0 + bx, y0 + 142, 121, 39)
        ly = 200
        lh = ph - ly
        lw = pw - lx - 40
        lst = Cv(lw, lh, S)
        off = self.scr.get("page", 0) or 0
        content = len(ITEMS) * 118
        mx = max(0, content - lh + 20)
        self.smax["page"] = mx
        off = min(off, mx)
        self.scr["page"] = off
        for i, (nm, cat, by, ver) in enumerate(ITEMS):
            ty = 8 + i * 118 - off
            lst.rr(0, ty, 101, 101, 8, BTNC)
            if nm:
                lst.text(113, ty + 12, nm, "b", 15.5, WHITE)
                yy = ty + 36
            else:
                lst.icon("logo_small", 118, ty + 11, 16, WHITE)
                yy = ty + 36
            t = "%s  \u00b7  %s" % (cat, by) if not nm else "%s  \u00b7  %s" % (cat, by)
            wd = lst.text(113, yy, t, "m", 15, (200, 202, 206, 255))
            if ver:
                lst.icon("badge", 113 + wd + 14, yy, 16, (51, 105, 255, 255))
                lst.icon("check", 113 + wd + 14, yy, 16, WHITE)
        m.blit(lst, lx, ly)
        self.reg("page_list", x0 + lx, y0 + ly, lw, lh, cur="arrow", sc="page")
        if mx > 0:
            th = max(24, lh * lh / float(content))
            ty = ly + (lh - th) * (off / float(mx))
            m.rr(pw - 12, ty, 2, th, 1, (255, 255, 255, 60))
        cv.blit(m, x0, y0, alpha=self.fade if self.fade < 1 else 1.0)


IS_WIN = sys.platform == "win32"
LOG_PATH = os.path.join(os.environ.get("TEMP", os.path.expanduser("~")), "roblox_gui_overlay_error.log")


def log_error(text):
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S") + "\n" + text + "\n")
    except Exception:
        pass


if IS_WIN:
    from ctypes import wintypes as wt

    user32 = ctypes.WinDLL("user32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)
    LRESULT = ctypes.c_ssize_t
    WNDPROC = ctypes.WINFUNCTYPE(LRESULT, wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM)

    class WNDCLASSW(ctypes.Structure):
        _fields_ = [
            ("style", wt.UINT), ("lpfnWndProc", WNDPROC), ("cbClsExtra", ctypes.c_int), ("cbWndExtra", ctypes.c_int),
            ("hInstance", wt.HINSTANCE), ("hIcon", wt.HANDLE), ("hCursor", wt.HANDLE), ("hbrBackground", wt.HANDLE),
            ("lpszMenuName", wt.LPCWSTR), ("lpszClassName", wt.LPCWSTR),
        ]

    class BLENDFUNCTION(ctypes.Structure):
        _fields_ = [("BlendOp", ctypes.c_ubyte), ("BlendFlags", ctypes.c_ubyte), ("SourceConstantAlpha", ctypes.c_ubyte), ("AlphaFormat", ctypes.c_ubyte)]

    class BITMAPINFOHEADER(ctypes.Structure):
        _fields_ = [
            ("biSize", wt.DWORD), ("biWidth", ctypes.c_long), ("biHeight", ctypes.c_long), ("biPlanes", wt.WORD),
            ("biBitCount", wt.WORD), ("biCompression", wt.DWORD), ("biSizeImage", wt.DWORD), ("biXPelsPerMeter", ctypes.c_long),
            ("biYPelsPerMeter", ctypes.c_long), ("biClrUsed", wt.DWORD), ("biClrImportant", wt.DWORD),
        ]

    class BITMAPINFO(ctypes.Structure):
        _fields_ = [("bmiHeader", BITMAPINFOHEADER), ("bmiColors", wt.DWORD * 3)]

    def _sig(fn, args, res):
        fn.argtypes = args
        fn.restype = res

    _sig(user32.DefWindowProcW, [wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM], LRESULT)
    _sig(user32.RegisterClassW, [ctypes.POINTER(WNDCLASSW)], wt.ATOM)
    _sig(user32.CreateWindowExW, [wt.DWORD, wt.LPCWSTR, wt.LPCWSTR, wt.DWORD, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wt.HWND, wt.HMENU, wt.HINSTANCE, wt.LPVOID], wt.HWND)
    _sig(user32.GetMessageW, [ctypes.POINTER(wt.MSG), wt.HWND, wt.UINT, wt.UINT], ctypes.c_int)
    _sig(user32.TranslateMessage, [ctypes.POINTER(wt.MSG)], wt.BOOL)
    _sig(user32.DispatchMessageW, [ctypes.POINTER(wt.MSG)], LRESULT)
    _sig(user32.PostMessageW, [wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM], wt.BOOL)
    _sig(user32.SetTimer, [wt.HWND, ctypes.c_size_t, wt.UINT, ctypes.c_void_p], ctypes.c_size_t)
    _sig(user32.KillTimer, [wt.HWND, ctypes.c_size_t], wt.BOOL)
    _sig(user32.DestroyWindow, [wt.HWND], wt.BOOL)
    _sig(user32.PostQuitMessage, [ctypes.c_int], None)
    _sig(user32.ShowWindow, [wt.HWND, ctypes.c_int], wt.BOOL)
    _sig(user32.SetWindowPos, [wt.HWND, wt.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wt.UINT], wt.BOOL)
    _sig(user32.UpdateLayeredWindow, [wt.HWND, wt.HDC, ctypes.POINTER(wt.POINT), ctypes.POINTER(wt.SIZE), wt.HDC, ctypes.POINTER(wt.POINT), wt.COLORREF, ctypes.POINTER(BLENDFUNCTION), wt.DWORD], wt.BOOL)
    _sig(user32.GetClientRect, [wt.HWND, ctypes.POINTER(wt.RECT)], wt.BOOL)
    _sig(user32.ClientToScreen, [wt.HWND, ctypes.POINTER(wt.POINT)], wt.BOOL)
    _sig(user32.GetCursorPos, [ctypes.POINTER(wt.POINT)], wt.BOOL)
    _sig(user32.GetForegroundWindow, [], wt.HWND)
    _sig(user32.SetForegroundWindow, [wt.HWND], wt.BOOL)
    _sig(user32.BringWindowToTop, [wt.HWND], wt.BOOL)
    _sig(user32.SetFocus, [wt.HWND], wt.HWND)
    _sig(user32.IsWindow, [wt.HWND], wt.BOOL)
    _sig(user32.IsIconic, [wt.HWND], wt.BOOL)
    _sig(user32.IsWindowVisible, [wt.HWND], wt.BOOL)
    _sig(user32.GetAncestor, [wt.HWND, wt.UINT], wt.HWND)
    _sig(user32.WindowFromPoint, [wt.POINT], wt.HWND)
    _sig(user32.GetClassNameW, [wt.HWND, wt.LPWSTR, ctypes.c_int], ctypes.c_int)
    _sig(user32.GetWindowThreadProcessId, [wt.HWND, ctypes.POINTER(wt.DWORD)], wt.DWORD)
    _sig(user32.AttachThreadInput, [wt.DWORD, wt.DWORD, wt.BOOL], wt.BOOL)
    _sig(user32.GetAsyncKeyState, [ctypes.c_int], ctypes.c_short)
    _sig(user32.GetKeyState, [ctypes.c_int], ctypes.c_short)
    _sig(user32.LoadCursorW, [wt.HINSTANCE, ctypes.c_void_p], ctypes.c_void_p)
    _sig(user32.SetCursor, [ctypes.c_void_p], ctypes.c_void_p)
    _sig(user32.SetCapture, [wt.HWND], wt.HWND)
    _sig(user32.ReleaseCapture, [], wt.BOOL)
    _sig(user32.OpenClipboard, [wt.HWND], wt.BOOL)
    _sig(user32.GetClipboardData, [wt.UINT], ctypes.c_void_p)
    _sig(user32.CloseClipboard, [], wt.BOOL)
    _sig(user32.keybd_event, [ctypes.c_ubyte, ctypes.c_ubyte, wt.DWORD, ctypes.c_size_t], None)
    _GWLP = getattr(user32, "GetWindowLongPtrW", None) or user32.GetWindowLongW
    _SWLP = getattr(user32, "SetWindowLongPtrW", None) or user32.SetWindowLongW
    _sig(_GWLP, [wt.HWND, ctypes.c_int], ctypes.c_ssize_t)
    _sig(_SWLP, [wt.HWND, ctypes.c_int, ctypes.c_ssize_t], ctypes.c_ssize_t)
    _sig(kernel32.GetModuleHandleW, [wt.LPCWSTR], ctypes.c_void_p)
    _sig(kernel32.GlobalLock, [ctypes.c_void_p], ctypes.c_void_p)
    _sig(kernel32.GlobalUnlock, [ctypes.c_void_p], wt.BOOL)
    _sig(kernel32.GetCurrentThreadId, [], wt.DWORD)
    _sig(gdi32.CreateCompatibleDC, [wt.HDC], wt.HDC)
    _sig(gdi32.CreateDIBSection, [wt.HDC, ctypes.POINTER(BITMAPINFO), wt.UINT, ctypes.POINTER(ctypes.c_void_p), wt.HANDLE, wt.DWORD], wt.HANDLE)
    _sig(gdi32.SelectObject, [wt.HDC, wt.HANDLE], wt.HANDLE)
    _sig(gdi32.DeleteObject, [wt.HANDLE], wt.BOOL)
    _sig(gdi32.DeleteDC, [wt.HDC], wt.BOOL)

    _instances = {}
    _class_ready = [False]
    CLASS_NAME = "RbxGuiOverlayWnd"

    def _wnd_proc(hwnd, msg, wp, lp):
        ov = _instances.get(hwnd)
        if ov is not None:
            try:
                r = ov.on_msg(msg, wp, lp)
            except Exception:
                log_error(traceback.format_exc())
                r = None
            if r is not None:
                return r
        return user32.DefWindowProcW(hwnd, msg, wp, lp)

    _wnd_proc_c = WNDPROC(_wnd_proc)

    def set_dpi_aware():
        try:
            ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
            return
        except Exception:
            pass
        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(2)
            return
        except Exception:
            pass
        try:
            ctypes.windll.user32.SetProcessDPIAware()
        except Exception:
            pass

    def clip_text():
        if not user32.OpenClipboard(None):
            return ""
        try:
            h = user32.GetClipboardData(13)
            if not h:
                return ""
            p = kernel32.GlobalLock(h)
            if not p:
                return ""
            try:
                return ctypes.wstring_at(p)
            finally:
                kernel32.GlobalUnlock(h)
        finally:
            user32.CloseClipboard()

    def force_fg(hwnd):
        fg = user32.GetForegroundWindow()
        cur = kernel32.GetCurrentThreadId()
        fgt = user32.GetWindowThreadProcessId(fg, None) if fg else 0
        attached = False
        if fgt and fgt != cur:
            attached = bool(user32.AttachThreadInput(cur, fgt, True))
        user32.BringWindowToTop(hwnd)
        ok = user32.SetForegroundWindow(hwnd)
        if attached:
            user32.AttachThreadInput(cur, fgt, False)
        if not ok and user32.GetForegroundWindow() != hwnd:
            user32.keybd_event(0x12, 0, 0, 0)
            user32.keybd_event(0x12, 0, 2, 0)
            user32.SetForegroundWindow(hwnd)

    def window_scale(hwnd):
        try:
            dpi = ctypes.windll.user32.GetDpiForWindow(ctypes.c_void_p(hwnd))
            if dpi:
                return max(1.0, min(3.0, dpi / 96.0))
        except Exception:
            pass
        return 1.0

    class Overlay:
        def __init__(self, target, ui, scale):
            self.target = target
            self.ui = ui
            self.S = scale if scale else window_scale(target)
            self.hwnd = None
            self.x = self.y = 0
            self.w = self.h = 0
            self.shown = False
            self.kbd = False
            self.dirty = True
            self.down_name = None
            self.drag = None
            self.prev_esc = False
            self.prev_slash = False
            self.prev_lb = False
            self.pending_hi = None
            self.memdc = None
            self.hbm = None
            self.old = None
            self.bits = None
            self.bw = self.bh = 0
            self.finished = threading.Event()
            self.cursors = {}

        def start(self):
            t = threading.Thread(target=self.run, daemon=True)
            t.start()
            return t

        def stop(self):
            if self.hwnd:
                user32.PostMessageW(self.hwnd, 0x0010, 0, 0)

        def run(self):
            try:
                self.loop()
            except Exception:
                log_error(traceback.format_exc())
            finally:
                self.finished.set()

        def client_rect(self):
            rc = wt.RECT()
            if not user32.GetClientRect(self.target, ctypes.byref(rc)):
                return None
            pt = wt.POINT(0, 0)
            user32.ClientToScreen(self.target, ctypes.byref(pt))
            return pt.x, pt.y, rc.right - rc.left, rc.bottom - rc.top

        def loop(self):
            hinst = kernel32.GetModuleHandleW(None)
            if not _class_ready[0]:
                wc = WNDCLASSW()
                wc.style = 0
                wc.lpfnWndProc = _wnd_proc_c
                wc.cbClsExtra = 0
                wc.cbWndExtra = 0
                wc.hInstance = hinst
                wc.hIcon = None
                wc.hCursor = None
                wc.hbrBackground = None
                wc.lpszMenuName = None
                wc.lpszClassName = CLASS_NAME
                user32.RegisterClassW(ctypes.byref(wc))
                _class_ready[0] = True
            rect = self.client_rect() or (0, 0, 800, 600)
            self.x, self.y, self.w, self.h = rect
            self.w = max(64, self.w)
            self.h = max(64, self.h)
            ex = 0x00080000 | 0x00000008 | 0x00000080 | 0x08000000
            self.hwnd = user32.CreateWindowExW(ex, CLASS_NAME, "Roblox GUI Overlay", 0x80000000, self.x, self.y, self.w, self.h, None, None, hinst, None)
            if not self.hwnd:
                raise RuntimeError("could not create overlay window")
            _instances[self.hwnd] = self
            self.memdc = gdi32.CreateCompatibleDC(None)
            self.make_bitmap(self.w, self.h)
            user32.SetTimer(self.hwnd, 1, 15, None)
            msg = wt.MSG()
            try:
                while True:
                    r = user32.GetMessageW(ctypes.byref(msg), None, 0, 0)
                    if r <= 0:
                        break
                    user32.TranslateMessage(ctypes.byref(msg))
                    user32.DispatchMessageW(ctypes.byref(msg))
            finally:
                _instances.pop(self.hwnd, None)
                if self.hbm:
                    gdi32.SelectObject(self.memdc, self.old)
                    gdi32.DeleteObject(self.hbm)
                if self.memdc:
                    gdi32.DeleteDC(self.memdc)

        def make_bitmap(self, w, h):
            if self.hbm:
                gdi32.SelectObject(self.memdc, self.old)
                gdi32.DeleteObject(self.hbm)
                self.hbm = None
            bmi = BITMAPINFO()
            bmi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
            bmi.bmiHeader.biWidth = w
            bmi.bmiHeader.biHeight = -h
            bmi.bmiHeader.biPlanes = 1
            bmi.bmiHeader.biBitCount = 32
            bmi.bmiHeader.biCompression = 0
            bits = ctypes.c_void_p()
            self.hbm = gdi32.CreateDIBSection(self.memdc, ctypes.byref(bmi), 0, ctypes.byref(bits), None, 0)
            self.old = gdi32.SelectObject(self.memdc, self.hbm)
            self.bits = bits.value
            self.bw = w
            self.bh = h

        def push(self):
            pt = wt.POINT(self.x, self.y)
            sz = wt.SIZE(self.bw, self.bh)
            src = wt.POINT(0, 0)
            bf = BLENDFUNCTION(0, 0, 255, 1)
            user32.UpdateLayeredWindow(self.hwnd, None, ctypes.byref(pt), ctypes.byref(sz), self.memdc, ctypes.byref(src), 0, ctypes.byref(bf), 2)

        def redraw(self):
            img = self.ui.render(self.bw, self.bh, self.S, time.time())
            r, g, b, a = img.split()
            data = Image.merge("RGBA", (ImageChops.multiply(b, a), ImageChops.multiply(g, a), ImageChops.multiply(r, a), a)).tobytes()
            ctypes.memmove(self.bits, data, len(data))
            self.push()
            self.dirty = False

        def local(self, sx, sy):
            return (sx - self.x) / self.S, (sy - self.y) / self.S

        def region_at(self, lx, ly):
            r = self.ui.hit(lx, ly)
            return r["n"] if r else None

        def acquire(self):
            self.kbd = True
            st = _GWLP(self.hwnd, -20)
            _SWLP(self.hwnd, -20, st & ~0x08000000)
            user32.SetWindowPos(self.hwnd, None, 0, 0, 0, 0, 0x37)
            force_fg(self.hwnd)
            user32.SetFocus(self.hwnd)

        def release(self):
            self.kbd = False
            st = _GWLP(self.hwnd, -20)
            _SWLP(self.hwnd, -20, st | 0x08000000)
            user32.SetWindowPos(self.hwnd, None, 0, 0, 0, 0, 0x37)
            if user32.GetForegroundWindow() == self.hwnd and user32.IsWindow(self.target):
                force_fg(self.target)

        def tick(self):
            ui = self.ui
            now = time.time()
            if ui.quit or not user32.IsWindow(self.target):
                user32.DestroyWindow(self.hwnd)
                return
            fg = user32.GetForegroundWindow()
            fgroot = user32.GetAncestor(fg, 2) if fg else 0
            active = (fgroot == self.target) or (fg == self.hwnd)
            rect = self.client_rect()
            vis = bool(active and rect and not user32.IsIconic(self.target) and user32.IsWindowVisible(self.target) and rect[2] >= 64 and rect[3] >= 64)
            if vis:
                x, y, w, h = rect
                if (w, h) != (self.bw, self.bh):
                    self.w, self.h = w, h
                    self.x, self.y = x, y
                    self.make_bitmap(w, h)
                    self.dirty = True
                elif (x, y) != (self.x, self.y):
                    self.x, self.y = x, y
                    self.push()
            esc = bool(user32.GetAsyncKeyState(0x1B) & 0x8000)
            slash = bool(user32.GetAsyncKeyState(0xBF) & 0x8000)
            lb = bool(user32.GetAsyncKeyState(0x01) & 0x8000)
            pt = wt.POINT()
            user32.GetCursorPos(ctypes.byref(pt))
            lx, ly = self.local(pt.x, pt.y)
            if vis and fgroot == self.target and not self.kbd:
                if esc and not self.prev_esc:
                    ui.esc()
                    self.dirty = True
                if slash and not self.prev_slash:
                    ui.slash()
                    self.dirty = True
            if vis and lb and not self.prev_lb and 0 <= lx < self.w / self.S and 0 <= ly < self.h / self.S:
                if self.region_at(lx, ly) is None:
                    ui.down(None)
                    self.dirty = True
            self.prev_esc = esc
            self.prev_slash = slash
            self.prev_lb = lb
            if vis:
                if self.drag and lb:
                    if ui.slider_set(self.drag, lx):
                        self.dirty = True
                name = None
                if 0 <= lx < self.w / self.S and 0 <= ly < self.h / self.S:
                    name = self.region_at(lx, ly)
                if ui.set_hover(name):
                    self.dirty = True
            if ui.step(now):
                self.dirty = True
            want = ui.needs_kbd
            if want and not self.kbd and vis:
                self.acquire()
            elif not want and self.kbd:
                self.release()
            if vis != self.shown:
                self.shown = vis
                if vis:
                    user32.SetWindowPos(self.hwnd, ctypes.c_void_p(-1), self.x, self.y, 0, 0, 0x13)
                    self.dirty = True
                    self.redraw()
                    user32.ShowWindow(self.hwnd, 4)
                else:
                    user32.ShowWindow(self.hwnd, 0)
            elif vis and self.dirty:
                self.redraw()

        def set_cursor(self):
            r = self.ui.hit(*self.cursor_local())
            kind = r["cur"] if r else "arrow"
            ids = {"hand": 32649, "ibeam": 32513, "arrow": 32512}
            cid = ids.get(kind, 32512)
            h = self.cursors.get(cid)
            if h is None:
                h = user32.LoadCursorW(None, ctypes.c_void_p(cid))
                self.cursors[cid] = h
            user32.SetCursor(h)

        def cursor_local(self):
            pt = wt.POINT()
            user32.GetCursorPos(ctypes.byref(pt))
            return self.local(pt.x, pt.y)

        def on_msg(self, msg, wp, lp):
            ui = self.ui
            if msg == 0x0113:
                try:
                    self.tick()
                except Exception:
                    log_error(traceback.format_exc())
                return 0
            if msg == 0x0201:
                x = ctypes.c_short(lp & 0xFFFF).value
                y = ctypes.c_short((lp >> 16) & 0xFFFF).value
                lx, ly = x / self.S, y / self.S
                user32.SetCapture(self.hwnd)
                name = self.region_at(lx, ly)
                ui.down(name)
                self.down_name = name
                if name and name.startswith("slider_"):
                    self.drag = name[7:]
                    ui.slider_set(self.drag, lx)
                self.dirty = True
                return 0
            if msg == 0x0202:
                x = ctypes.c_short(lp & 0xFFFF).value
                y = ctypes.c_short((lp >> 16) & 0xFFFF).value
                lx, ly = x / self.S, y / self.S
                user32.ReleaseCapture()
                name = self.region_at(lx, ly)
                if self.drag:
                    self.drag = None
                elif name and name == self.down_name:
                    ui.click(name)
                self.down_name = None
                self.dirty = True
                return 0
            if msg == 0x020A:
                delta = ctypes.c_short((wp >> 16) & 0xFFFF).value
                sx = ctypes.c_short(lp & 0xFFFF).value
                sy = ctypes.c_short((lp >> 16) & 0xFFFF).value
                lx, ly = self.local(sx, sy)
                if ui.wheel(lx, ly, delta):
                    self.dirty = True
                return 0
            if msg == 0x0100:
                ctrl = user32.GetKeyState(0x11) < 0
                r = ui.on_key(wp, ctrl)
                if r == "paste":
                    ui.paste(clip_text())
                self.dirty = True
                return 0
            if msg == 0x0102:
                ch = chr(wp)
                if 0xD800 <= wp <= 0xDBFF:
                    self.pending_hi = ch
                    return 0
                if 0xDC00 <= wp <= 0xDFFF and self.pending_hi:
                    ch = self.pending_hi + ch
                    self.pending_hi = None
                if ui.on_char(ch):
                    self.dirty = True
                return 0
            if msg == 0x0020:
                if (lp & 0xFFFF) == 1:
                    self.set_cursor()
                    return 1
                return None
            if msg == 0x0021:
                return 3 if not self.kbd else None
            if msg == 0x0006:
                if (wp & 0xFFFF) == 0:
                    ui.lost_focus()
                    if self.kbd:
                        self.kbd = False
                        st = _GWLP(self.hwnd, -20)
                        _SWLP(self.hwnd, -20, st | 0x08000000)
                        user32.SetWindowPos(self.hwnd, None, 0, 0, 0, 0, 0x37)
                    self.dirty = True
                return 0
            if msg == 0x0014:
                return 1
            if msg == 0x0010:
                user32.DestroyWindow(self.hwnd)
                return 0
            if msg == 0x0002:
                user32.KillTimer(self.hwnd, 1)
                user32.PostQuitMessage(0)
                return 0
            return None


SETTINGS_DIR = os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "RobloxGuiOverlay")
SETTINGS_FILE = os.path.join(SETTINGS_DIR, "settings.json")


def load_settings():
    d = {"display": "slefro", "username": "sl3fro", "avatar": "", "scale": "Auto"}
    try:
        with open(SETTINGS_FILE, "r", encoding="utf-8") as f:
            d.update(json.load(f))
    except Exception:
        pass
    return d


def save_settings(d):
    try:
        os.makedirs(SETTINGS_DIR, exist_ok=True)
        with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
            json.dump(d, f)
    except Exception:
        pass


def load_avatar(path):
    if path:
        try:
            return Image.open(path).convert("RGBA")
        except Exception:
            pass
    local = os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "avatar.png")
    if os.path.isfile(local):
        try:
            return Image.open(local).convert("RGBA")
        except Exception:
            pass
    return Image.open(io.BytesIO(base64.b64decode("".join(AVATAR_B64.split())))).convert("RGBA")


SKIP_CLASSES = {"Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "NotifyIconOverflowWindow", "TaskListThumbnailWnd", "TaskListOverlayWnd", "XamlExplorerHostIslandWindow", "Windows.UI.Core.CoreWindow"}


class Launcher:
    def __init__(self):
        import tkinter as tk
        from tkinter import filedialog
        self.tk = tk
        self.filedialog = filedialog
        self.s = load_settings()
        self.root = tk.Tk()
        self.root.title("Roblox GUI Overlay")
        self.root.configure(bg="#18191c")
        self.root.resizable(False, False)
        self.root.attributes("-topmost", True)
        w, h = 520, 400
        sw = self.root.winfo_screenwidth()
        sh = self.root.winfo_screenheight()
        self.root.geometry("%dx%d+%d+%d" % (w, h, (sw - w) // 2, (sh - h) // 3))
        tk.Label(self.root, text="click on a application to overlay", bg="#18191c", fg="#ffffff", font=("Segoe UI Semibold", 20)).pack(pady=(34, 6))
        self.status = tk.Label(self.root, text="Waiting for your click...", bg="#18191c", fg="#8f949c", font=("Segoe UI", 11))
        self.status.pack(pady=(0, 22))
        form = tk.Frame(self.root, bg="#18191c")
        form.pack(padx=40, fill="x")
        form.columnconfigure(1, weight=1)
        self.v_display = tk.StringVar(value=self.s["display"])
        self.v_user = tk.StringVar(value=self.s["username"])
        self.v_avatar = tk.StringVar(value=self.s["avatar"])
        self.v_scale = tk.StringVar(value=self.s["scale"])
        self.row(form, 0, "Display name", self.v_display)
        self.row(form, 1, "Username", self.v_user)
        r = self.row(form, 2, "Avatar png", self.v_avatar)
        tk.Button(form, text="Browse", command=self.browse, bg="#2d2e31", fg="#ffffff", activebackground="#3e4044", activeforeground="#ffffff", relief="flat", padx=10, font=("Segoe UI", 10)).grid(row=2, column=2, padx=(8, 0), pady=6)
        tk.Label(form, text="UI scale", bg="#18191c", fg="#c7cacf", font=("Segoe UI", 11), anchor="w").grid(row=3, column=0, sticky="w", pady=6)
        om = tk.OptionMenu(form, self.v_scale, "Auto", "100%", "125%", "150%", "175%", "200%")
        om.config(bg="#2d2e31", fg="#ffffff", activebackground="#3e4044", activeforeground="#ffffff", relief="flat", highlightthickness=0, font=("Segoe UI", 10), width=10)
        om["menu"].config(bg="#2d2e31", fg="#ffffff", font=("Segoe UI", 10))
        om.grid(row=3, column=1, sticky="w", pady=6, padx=(10, 0))
        tk.Label(self.root, text="Esc = menu     / = chat     Use windowed or borderless mode", bg="#18191c", fg="#6c7078", font=("Segoe UI", 10)).pack(side="bottom", pady=18)
        self.overlay = None
        self.prev = False
        self.me = os.getpid()
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        self.root.after(40, self.poll)

    def row(self, form, i, label, var):
        tk = self.tk
        tk.Label(form, text=label, bg="#18191c", fg="#c7cacf", font=("Segoe UI", 11), anchor="w").grid(row=i, column=0, sticky="w", pady=6)
        e = tk.Entry(form, textvariable=var, bg="#2d2e31", fg="#ffffff", insertbackground="#ffffff", relief="flat", font=("Segoe UI", 11), highlightthickness=1, highlightbackground="#3e4044", highlightcolor="#3658f3")
        e.grid(row=i, column=1, sticky="ew", padx=(10, 0), pady=6, ipady=4)
        return e

    def browse(self):
        p = self.filedialog.askopenfilename(title="Choose your avatar png", filetypes=[("Images", "*.png *.webp *.jpg *.jpeg")])
        if p:
            self.v_avatar.set(p)

    def valid_target(self, hwnd):
        if not hwnd or not user32.IsWindowVisible(hwnd):
            return False
        pid = wt.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if pid.value == self.me:
            return False
        buf = ctypes.create_unicode_buffer(256)
        user32.GetClassNameW(hwnd, buf, 256)
        return buf.value not in SKIP_CLASSES

    def poll(self):
        try:
            if self.overlay is not None:
                if self.overlay.finished.is_set():
                    self.overlay = None
                    self.root.deiconify()
                    self.status.config(text="Waiting for your click...")
                    self.prev = True
            else:
                down = bool(user32.GetAsyncKeyState(0x01) & 0x8000)
                if down and not self.prev:
                    pt = wt.POINT()
                    user32.GetCursorPos(ctypes.byref(pt))
                    hw = user32.WindowFromPoint(pt)
                    root = user32.GetAncestor(hw, 2) if hw else 0
                    if self.valid_target(root):
                        self.begin(root)
                self.prev = down
        except Exception:
            log_error(traceback.format_exc())
        self.root.after(30, self.poll)

    def begin(self, hwnd):
        display = self.v_display.get().strip() or "Player"
        user = self.v_user.get().strip().lstrip("@") or "Player"
        d = {"display": display, "username": user, "avatar": self.v_avatar.get().strip(), "scale": self.v_scale.get()}
        save_settings(d)
        sc = d["scale"]
        scale = None if sc == "Auto" else int(sc.rstrip("%")) / 100.0
        ui = Ui(display, user, load_avatar(d["avatar"]))
        self.overlay = Overlay(hwnd, ui, scale)
        self.overlay.start()
        self.root.withdraw()

    def close(self):
        if self.overlay is not None:
            self.overlay.stop()
        self.root.destroy()

    def run(self):
        self.root.mainloop()


def main():
    try:
        if not IS_WIN:
            raise RuntimeError("This overlay only runs on Windows.")
        set_dpi_aware()
        Launcher().run()
    except Exception:
        text = traceback.format_exc()
        log_error(text)
        try:
            ctypes.windll.user32.MessageBoxW(None, text[-1500:] + "\n\nLog: " + LOG_PATH, "Roblox GUI Overlay", 0x10)
        except Exception:
            pass


AVATAR_B64 = """
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
REQ8Ivz/AS3dGaHBIXVxAAAAAElFTkSuQmCC
"""


if __name__ == "__main__":
    main()
