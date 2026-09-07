#!/usr/bin/env python3
"""Builds the corpus of damaged init segments that test-movpkg.sh feeds the parser.

Deterministic on purpose: a fuzz run that finds something must be repeatable, and a run
that finds nothing should not be quietly testing something else next time.

The crafted cases are not random. They are the shapes a reader of length-prefixed boxes
gets wrong: a box whose declared size leaves no room for the field being read, a 64-bit
size that does not fit the integer it is converted to, sizes below the header, and nesting
deep enough to exhaust the stack.
"""
import pathlib, random, struct, sys

out = pathlib.Path(sys.argv[1])
seed_file = sys.argv[2] if len(sys.argv) > 2 else ""
out.mkdir(parents=True, exist_ok=True)
random.seed(20260906)

def box(kind, payload=b"", size=None):
    return struct.pack(">I", len(payload) + 8 if size is None else size) + kind + payload

# Shapes that do not need a real file behind them.
crafted = {
    "craft-mdhd-size8":     box(b"moov", box(b"trak", box(b"mdia", box(b"mdhd")))),
    "craft-mdhd-size9":     box(b"moov", box(b"trak", box(b"mdia", box(b"mdhd", b"\x00")))),
    "craft-size64-huge":    struct.pack(">I", 1) + b"moov" + struct.pack(">Q", 0xFFFFFFFFFFFFFFFF),
    "craft-size64-max":     struct.pack(">I", 1) + b"moov" + struct.pack(">Q", 0x7FFFFFFFFFFFFFFF),
    "craft-size64-short":   struct.pack(">I", 1) + b"moov",
    "craft-size-zero":      struct.pack(">I", 0) + b"moov" + b"\x00" * 32,
    "craft-size-seven":     struct.pack(">I", 7) + b"moov",
    "craft-alac-short":     box(b"moov", box(b"trak", box(b"mdia", box(b"minf", box(b"stbl",
                                box(b"stsd", b"\x00" * 8 + box(b"alac", b"\x00" * 4))))))),
    "craft-empty":          b"",
    "craft-zeros":          b"\x00" * 4096,
    "craft-garbage":        bytes(random.randrange(256) for _ in range(4096)),
}
deep = b""
for _ in range(4000):
    deep = box(b"moov", deep)
crafted["craft-deep-nesting"] = deep

for name, data in crafted.items():
    (out / f"{name}.bin").write_bytes(data)

# Everything else needs a real segment to damage.
if not seed_file or not pathlib.Path(seed_file).exists():
    print(f"generated {len(crafted)} crafted cases (no .initfrag found to damage)")
    sys.exit(0)

base = pathlib.Path(seed_file).read_bytes()

for length in sorted(set(list(range(0, 40)) + [len(base) * n // 64 for n in range(1, 64)])):
    (out / f"trunc-{length:06d}.bin").write_bytes(base[:length])

for offset in range(0, min(len(base), 2048), 7):
    flipped = bytearray(base)
    flipped[offset] ^= 0xFF
    (out / f"flip-{offset:05d}.bin").write_bytes(bytes(flipped))

for n in range(60):
    noisy = bytearray(base)
    for _ in range(random.randint(1, 40)):
        noisy[random.randrange(len(noisy))] = random.randrange(256)
    (out / f"noise-{n:03d}.bin").write_bytes(bytes(noisy))

print(f"generated {len(list(out.iterdir()))} cases from {pathlib.Path(seed_file).name}")
