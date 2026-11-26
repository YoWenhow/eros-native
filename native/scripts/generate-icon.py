#!/usr/bin/env python3
"""Generate the original temporary T05 icon; no external image dependency."""
from pathlib import Path
import struct
import zlib

size = 1024
rows = bytearray()
for y in range(size):
    rows.append(0)
    for x in range(size):
        stem = 280 <= x < 392 and 256 <= y < 768
        bars = 392 <= x < 744 and (256 <= y < 368 or 456 <= y < 568 or 656 <= y < 768)
        rows.extend((255, 255, 255) if stem or bars else (28, 78, 128))

def chunk(tag, data):
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data))

png = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(rows, 9))
png += chunk(b'IEND', b'')
output = Path(__file__).resolve().parents[1] / 'Resources' / 'AppIcon.png'
output.parent.mkdir(parents=True, exist_ok=True)
output.write_bytes(png)
print(output)
