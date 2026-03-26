#!/usr/bin/env python3
"""
generate-dmg-background.py
───────────────────────────
Generates a 600 × 400 DMG background PNG using only Python stdlib (no Pillow
or other dependencies).

The image is a four-corner gradient that blends:
  top-left  → #0c1824  (near-black navy)
  top-right → #17304a  (dark steel blue)
  bot-left  → #0a1520  (deep navy)
  bot-right → #1a3d5c  (ocean blue)

Usage
    python3 scripts/generate-dmg-background.py [output.png]
    Default output: dmg-background.png
"""

import struct
import zlib
import sys
import pathlib

W, H = 600, 400

# Corner colours (R, G, B) — adjust to match your brand palette
C_TL = (12,  24,  36)   # top-left
C_TR = (23,  48,  74)   # top-right
C_BL = (10,  21,  32)   # bottom-left
C_BR = (26,  61,  92)   # bottom-right


def lerp(a: int, b: int, t: float) -> int:
    return max(0, min(255, round(a + (b - a) * t)))


def bilinear(tx: float, ty: float) -> tuple[int, int, int]:
    """Bilinear interpolation across the four corner colours."""
    r = lerp(lerp(C_TL[0], C_TR[0], tx), lerp(C_BL[0], C_BR[0], tx), ty)
    g = lerp(lerp(C_TL[1], C_TR[1], tx), lerp(C_BL[1], C_BR[1], tx), ty)
    b = lerp(lerp(C_TL[2], C_TR[2], tx), lerp(C_BL[2], C_BR[2], tx), ty)
    return r, g, b


def png_chunk(chunk_type: bytes, data: bytes) -> bytes:
    header = chunk_type + data
    crc    = zlib.crc32(header) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + header + struct.pack(">I", crc)


def write_png(path: str) -> None:
    # Build raw scanlines: each row starts with a filter byte (0 = None)
    rows = bytearray()
    for y in range(H):
        rows.append(0)   # filter type
        ty = y / (H - 1) if H > 1 else 0.0
        for x in range(W):
            tx = x / (W - 1) if W > 1 else 0.0
            r, g, b = bilinear(tx, ty)
            rows += bytes([r, g, b])

    # PNG signature
    sig  = b"\x89PNG\r\n\x1a\n"

    # IHDR: width, height, bit depth (8), colour type (2 = RGB), compression,
    #       filter, interlace — all standard defaults
    ihdr = png_chunk(
        b"IHDR",
        struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0),
    )

    # IDAT: zlib-compressed scanlines
    idat = png_chunk(b"IDAT", zlib.compress(bytes(rows), level=6))

    # IEND: empty marker
    iend = png_chunk(b"IEND", b"")

    pathlib.Path(path).write_bytes(sig + ihdr + idat + iend)
    print(f"▸ Generated DMG background: {path}  ({W}×{H} px)")


if __name__ == "__main__":
    output = sys.argv[1] if len(sys.argv) > 1 else "dmg-background.png"
    # Ensure parent directory exists
    pathlib.Path(output).parent.mkdir(parents=True, exist_ok=True)
    write_png(output)
