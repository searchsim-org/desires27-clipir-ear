"""Kokoro voice styles (ADR-020) (.pt, PyTorch zip) → voices.npz as KokoroSwift reads it, standard library only.

A voice .pt holds one float32 tensor of shape (510, 1, 256): the raw storage is the archive's `*/data/0` entry.
Usage: python3 tools/models/kokoro_voices.py <dir with *.pt> <out voices.npz>
"""

import struct
import sys
import zipfile
from pathlib import Path

SHAPE = (510, 1, 256)


def npy(raw: bytes) -> bytes:
    header = f"{{'descr': '<f4', 'fortran_order': False, 'shape': {SHAPE}, }}"
    header += (
        " " * (64 - (10 + len(header) + 1) % 64) + "\n"
    )  # pad so the data starts on a 64-byte boundary
    return b"\x93NUMPY\x01\x00" + struct.pack("<H", len(header)) + header.encode() + raw


def main(src: str, out: str) -> None:
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
        for pt in sorted(Path(src).glob("*.pt")):
            with zipfile.ZipFile(pt) as t:
                data = next(n for n in t.namelist() if n.endswith("/data/0"))
                raw = t.read(data)
            assert len(raw) == 510 * 256 * 4, (pt.name, len(raw))
            z.writestr(pt.stem + ".npy", npy(raw))
            print("wrote", pt.stem)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
