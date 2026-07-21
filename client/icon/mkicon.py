from PIL import Image, ImageDraw
S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# --- squircle background: warm black with a subtle top-lighter gradient ---
pad = 70
r = 230
# gradient fill (vertical): #221E1A (top) -> #1A1714 (bottom)
grad = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(grad)
for y in range(S):
    t = y / S
    col = (int(0x24 - t*0x0a), int(0x20 - t*0x09), int(0x1c - t*0x08), 255)
    gd.line([(0, y), (S, y)], fill=col)
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([pad, pad, S-pad, S-pad], radius=r, fill=255)
img.paste(grad, (0, 0), mask)

WHITE = (0xFA, 0xFA, 0xF9, 255)
ACCENT = (0xE7, 0x00, 0x0B, 255)
cx = S // 2

# --- accent sound waves (concentric arcs) flanking the mic ---
for i, rad in enumerate((150, 220, 290)):
    w = 26 - i*4
    a = 200 - i*45
    col = (ACCENT[0], ACCENT[1], ACCENT[2], a)
    # left arcs (open to the right)
    d.arc([cx-40-rad, 512-rad, cx-40+rad, 512+rad], start=130, end=230, fill=col, width=w)
    # right arcs (open to the left)
    d.arc([cx+40-rad, 512-rad, cx+40+rad, 512+rad], start=-50, end=50, fill=col, width=w)

# --- microphone glyph (white), centered ---
mic_w = 210
top = 250
head_bottom = 560
d.rounded_rectangle([cx-mic_w//2, top, cx+mic_w//2, head_bottom], radius=mic_w//2, fill=WHITE)
# bracket (U arc around lower head)
br = 150
d.arc([cx-br, head_bottom-br-40, cx+br, head_bottom+br-40], start=20, end=160, fill=WHITE, width=34)
# stand
d.rounded_rectangle([cx-17, head_bottom+70, cx+17, head_bottom+190], radius=17, fill=WHITE)
# base
d.rounded_rectangle([cx-120, head_bottom+185, cx+120, head_bottom+225], radius=20, fill=WHITE)

img.save("/tmp/vf_icon_1024.png")
print("saved /tmp/vf_icon_1024.png")
