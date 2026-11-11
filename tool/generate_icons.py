import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

RES_DIR = "android/app/src/main/res"
FONT_PATH = "/usr/share/fonts/google-noto-vf/NotoSansBengali[wght].ttf"

BG_COLOR = (13, 13, 13, 255)       # Matte Black #0D0D0D
CRIMSON = (255, 30, 75, 255)       # Vibrant Crimson Accent
GLOW_COLOR = (220, 20, 60, 200)    # Crimson Glow
ACCENT_RING = (220, 20, 60, 180)   # Subtle Crimson Ring

DENSITIES = {
    "mipmap-mdpi": {"legacy": 48, "adaptive": 108},
    "mipmap-hdpi": {"legacy": 72, "adaptive": 162},
    "mipmap-xhdpi": {"legacy": 96, "adaptive": 216},
    "mipmap-xxhdpi": {"legacy": 144, "adaptive": 324},
    "mipmap-xxxhdpi": {"legacy": 192, "adaptive": 432},
}

def create_master_foreground(size=1024):
    """Creates a high-res transparent foreground containing the Bengali Taka symbol centered in safe area."""
    fg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    
    # Safe area is inner ~66.6% (72dp of 108dp)
    # Using 0.48 scale gives a strong, legible symbol within safe bounds
    font_size = int(size * 0.48)
    font = ImageFont.truetype(FONT_PATH, font_size)
    try:
        font.set_variation_by_name("Bold")
    except Exception:
        pass

    bbox = font.getbbox("৳")
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    tx = (size - tw) / 2 - bbox[0]
    ty = (size - th) / 2 - bbox[1]

    # Crimson glow
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.text((tx, ty), "৳", fill=GLOW_COLOR, font=font)
    glow = glow.filter(ImageFilter.GaussianBlur(int(size * 0.035)))
    fg.paste(glow, (0, 0), glow)

    # Crisp Bengali Taka symbol
    draw = ImageDraw.Draw(fg)
    draw.text((tx, ty), "৳", fill=CRIMSON, font=font)

    return fg

def create_master_legacy(size=1024, is_round=False):
    """Creates a high-res master icon for legacy launcher icons (opaque Matte Black bg)."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    margin = int(size * 0.04)
    if is_round:
        draw.ellipse([margin, margin, size - margin, size - margin], fill=BG_COLOR, outline=ACCENT_RING, width=int(size * 0.02))
    else:
        # Squircle / rounded rectangle
        corner_r = int(size * 0.22)
        draw.rounded_rectangle([margin, margin, size - margin, size - margin], radius=corner_r, fill=BG_COLOR, outline=ACCENT_RING, width=int(size * 0.02))

    # Font
    font_size = int(size * 0.58)
    font = ImageFont.truetype(FONT_PATH, font_size)
    try:
        font.set_variation_by_name("Bold")
    except Exception:
        pass

    bbox = font.getbbox("৳")
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    tx = (size - tw) / 2 - bbox[0]
    ty = (size - th) / 2 - bbox[1]

    # Glow
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.text((tx, ty), "৳", fill=GLOW_COLOR, font=font)
    glow = glow.filter(ImageFilter.GaussianBlur(int(size * 0.035)))
    img.paste(glow, (0, 0), glow)

    # Symbol
    d = ImageDraw.Draw(img)
    d.text((tx, ty), "৳", fill=CRIMSON, font=font)

    return img

def main():
    print("Generating master assets...")
    master_fg = create_master_foreground(1024)
    master_legacy = create_master_legacy(1024, is_round=False)
    master_round = create_master_legacy(1024, is_round=True)

    master_fg.save("/tmp/master_fg.png")
    master_legacy.save("/tmp/master_legacy.png")
    master_round.save("/tmp/master_round.png")

    for folder, dims in DENSITIES.items():
        out_dir = os.path.join(RES_DIR, folder)
        os.makedirs(out_dir, exist_ok=True)

        # 1. Adaptive foreground (108dp * density)
        adap_size = dims["adaptive"]
        fg_resized = master_fg.resize((adap_size, adap_size), Image.Resampling.LANCZOS)
        fg_path = os.path.join(out_dir, "ic_launcher_foreground.png")
        fg_resized.save(fg_path)

        # 2. Legacy icon (48dp * density)
        leg_size = dims["legacy"]
        leg_resized = master_legacy.resize((leg_size, leg_size), Image.Resampling.LANCZOS)
        leg_path = os.path.join(out_dir, "ic_launcher.png")
        leg_resized.save(leg_path)

        # 3. Round icon
        round_resized = master_round.resize((leg_size, leg_size), Image.Resampling.LANCZOS)
        round_path = os.path.join(out_dir, "ic_launcher_round.png")
        round_resized.save(round_path)

        print(f"Generated {folder}: {leg_size}x{leg_size} (legacy/round), {adap_size}x{adap_size} (adaptive fg)")

if __name__ == "__main__":
    main()
