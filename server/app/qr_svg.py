"""Dependency-free QR encoder, emitting SVG.

Exists because the web portal used to pull its QR image from `api.qrserver.com`,
which is wrong twice over on this product:

* **It cannot work.** The portal's whole premise is a clinic LAN. On a kiosk with
  no route to the internet the QR silently fails to load, so the phone hand-off
  looks broken rather than unavailable.
* **It leaks.** The URL being encoded carries the hand-off session token, so
  every capture code was being handed to a third party in a query string.

Byte mode, error-correction level M, versions 1-15 (up to 412 bytes) - far more
than the ~70-character capture URLs this serves. SVG output keeps it crisp at any
size with no imaging dependency.

Verified against `zbarimg` in `server/tests/test_qr_svg.py`.
"""

from __future__ import annotations

# (ec codewords per block, [(block count, data codewords per block), ...]) at
# error-correction level M, indexed by version - 1.
_EC_M: list[tuple[int, list[tuple[int, int]]]] = [
    (10, [(1, 16)]),
    (16, [(1, 28)]),
    (26, [(1, 44)]),
    (18, [(2, 32)]),
    (24, [(2, 43)]),
    (16, [(4, 27)]),
    (18, [(4, 31)]),
    (22, [(2, 38), (2, 39)]),
    (22, [(3, 36), (2, 37)]),
    (26, [(4, 43), (1, 44)]),
    (30, [(1, 50), (4, 51)]),
    (22, [(6, 36), (2, 37)]),
    (22, [(8, 37), (1, 38)]),
    (24, [(4, 40), (5, 41)]),
    (24, [(5, 41), (5, 42)]),
]

# Row/column centres of the alignment patterns, indexed by version - 1.
_ALIGN: list[list[int]] = [
    [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34],
    [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50],
    [6, 30, 54], [6, 32, 58], [6, 34, 62], [6, 26, 46, 66], [6, 26, 48, 70],
]

# ── GF(256) arithmetic, generator polynomial x^8 + x^4 + x^3 + x^2 + 1 ────────
_EXP = [0] * 512
_LOG = [0] * 256


def _init_tables() -> None:
    x = 1
    for i in range(255):
        _EXP[i] = x
        _LOG[x] = i
        x <<= 1
        if x & 0x100:
            x ^= 0x11D
    for i in range(255, 512):
        _EXP[i] = _EXP[i - 255]


_init_tables()


def _gf_mul(a: int, b: int) -> int:
    if a == 0 or b == 0:
        return 0
    return _EXP[_LOG[a] + _LOG[b]]


def _rs_generator(degree: int) -> list[int]:
    """Build the Reed-Solomon generator polynomial of the given degree."""
    poly = [1]
    for i in range(degree):
        poly.append(0)
        root = _EXP[i]
        for j in range(len(poly) - 1, 0, -1):
            poly[j] = poly[j - 1] ^ _gf_mul(poly[j], root)
        poly[0] = _gf_mul(poly[0], root)
    # Built constant-term first; _rs_remainder divides highest-degree first, so
    # hand it back leading coefficient first to match.
    return poly[::-1]


def _rs_remainder(data: list[int], degree: int) -> list[int]:
    gen = _rs_generator(degree)
    rem = [0] * degree
    for byte in data:
        factor = byte ^ rem[0]
        rem = rem[1:] + [0]
        for i in range(degree):
            rem[i] ^= _gf_mul(gen[i + 1], factor)
    return rem


# ── BCH codes for the format and version information areas ───────────────────
def _bch_format(fmt: int) -> int:
    rem = fmt
    for _ in range(10):
        rem = (rem << 1) ^ (0x537 if (rem << 1) & 0x400 else 0)
    return ((fmt << 10) | rem) ^ 0x5412


def _bch_version(ver: int) -> int:
    rem = ver
    for _ in range(12):
        rem = (rem << 1) ^ (0x1F25 if (rem << 1) & 0x1000 else 0)
    return (ver << 12) | rem


class _Matrix:
    """A QR module grid, plus which cells are structural and so unmaskable."""

    def __init__(self, version: int) -> None:
        self.version = version
        self.size = version * 4 + 17
        self.modules = [[False] * self.size for _ in range(self.size)]
        self.reserved = [[False] * self.size for _ in range(self.size)]

    def _set(self, r: int, c: int, dark: bool, reserve: bool = True) -> None:
        self.modules[r][c] = dark
        if reserve:
            self.reserved[r][c] = True

    def _finder(self, r: int, c: int) -> None:
        for dr in range(-1, 8):
            for dc in range(-1, 8):
                rr, cc = r + dr, c + dc
                if not (0 <= rr < self.size and 0 <= cc < self.size):
                    continue
                ring = max(abs(dr - 3), abs(dc - 3))
                self._set(rr, cc, ring != 2 and ring <= 3)

    def draw_function_patterns(self) -> None:
        n = self.size
        self._finder(0, 0)
        self._finder(0, n - 7)
        self._finder(n - 7, 0)

        for i in range(8, n - 8):          # timing patterns
            self._set(6, i, i % 2 == 0)
            self._set(i, 6, i % 2 == 0)

        centres = _ALIGN[self.version - 1]
        for r in centres:
            for c in centres:
                # Alignment patterns never overlap the three finders.
                if (r, c) in ((6, 6), (6, n - 7), (n - 7, 6)):
                    continue
                for dr in range(-2, 3):
                    for dc in range(-2, 3):
                        self._set(r + dr, c + dc,
                                  max(abs(dr), abs(dc)) != 1)

        # Reserve the format areas; the dark module is fixed.
        #
        # Row 6 and column 6 are the timing patterns and cross the format strips
        # at (6, 8) and (8, 6). Blanking those two cells here left a hole in the
        # timing pattern, which is enough on its own to make every code
        # undecodable.
        for i in range(9):
            if i != 6:
                self._set(8, i, False)
                self._set(i, 8, False)
        for i in range(8):
            self._set(8, n - 1 - i, False)
            self._set(n - 1 - i, 8, False)
        self._set(n - 8, 8, True)

        if self.version >= 7:
            for i in range(18):
                a, b = n - 11 + i % 3, i // 3
                self._set(a, b, False)
                self._set(b, a, False)

    def draw_format(self, mask: int) -> None:
        """Write both copies of the 15-bit format information.

        The spec writes the same string twice along paths that run in opposite
        directions, so relative to a fixed list of coordinates one copy is
        MSB-first and the other LSB-first. Getting this backwards yields a code
        with a perfect data region that no scanner will look at, which is why the
        two orders are spelled out rather than shared.
        """
        # Level M is 0b00 in the two high bits of the format value.
        bits = _bch_format((0b00 << 3) | mask)
        n = self.size

        # Copy 1 — around the top-left finder. Bit 14 lands on (8, 0).
        copy1 = [(8, 0), (8, 1), (8, 2), (8, 3), (8, 4), (8, 5), (8, 7), (8, 8),
                 (7, 8), (5, 8), (4, 8), (3, 8), (2, 8), (1, 8), (0, 8)]
        for i, (r, c) in enumerate(copy1):
            self._set(r, c, (bits >> (14 - i)) & 1 == 1)

        # Copy 2 — right of the top-right finder, then below the bottom-left one.
        # Bit 0 lands on (8, n - 1).
        copy2 = [(8, n - 1 - i) for i in range(8)] + \
                [(n - 15 + i, 8) for i in range(8, 15)]
        for i, (r, c) in enumerate(copy2):
            self._set(r, c, (bits >> i) & 1 == 1)

    def draw_version(self) -> None:
        if self.version < 7:
            return
        bits = _bch_version(self.version)
        n = self.size
        # Two 3x6 blocks: one below the top-right finder, one right of the
        # bottom-left one, each the transpose of the other. Bit i goes to
        # (n - 11 + i % 3, i // 3) — indexing it by row instead put every bit in
        # the wrong cell, which broke every version from 7 up while 1-6 (which
        # carry no version block) stayed fine.
        for i in range(18):
            dark = (bits >> i) & 1 == 1
            a, b = n - 11 + i % 3, i // 3
            self._set(a, b, dark)
            self._set(b, a, dark)

    def place_data(self, bits: list[int]) -> None:
        """Walk the zig-zag column pairs right-to-left, skipping column 6."""
        n = self.size
        i = 0
        col = n - 1
        upward = True
        while col > 0:
            if col == 6:
                col -= 1
            for step in range(n):
                row = (n - 1 - step) if upward else step
                for c in (col, col - 1):
                    if self.reserved[row][c]:
                        continue
                    self.modules[row][c] = i < len(bits) and bits[i] == 1
                    i += 1
            col -= 2
            upward = not upward

    def apply_mask(self, mask: int) -> None:
        for r in range(self.size):
            for c in range(self.size):
                if self.reserved[r][c]:
                    continue
                if _MASKS[mask](r, c):
                    self.modules[r][c] = not self.modules[r][c]

    def penalty(self) -> int:
        n, m = self.size, self.modules
        score = 0

        # Rule 1: runs of five or more same-coloured modules in a line.
        for line in [[m[r][c] for c in range(n)] for r in range(n)] + \
                    [[m[r][c] for r in range(n)] for c in range(n)]:
            run, prev = 1, line[0]
            for v in line[1:]:
                if v == prev:
                    run += 1
                else:
                    if run >= 5:
                        score += 3 + (run - 5)
                    run, prev = 1, v
            if run >= 5:
                score += 3 + (run - 5)

        # Rule 2: 2x2 blocks of one colour.
        for r in range(n - 1):
            for c in range(n - 1):
                if m[r][c] == m[r][c + 1] == m[r + 1][c] == m[r + 1][c + 1]:
                    score += 3

        # Rule 3: the finder-lookalike pattern, in either direction.
        target = [True, False, True, True, True, False, True,
                  False, False, False, False]
        for r in range(n):
            for c in range(n - 10):
                window = [m[r][c + k] for k in range(11)]
                if window == target or window[::-1] == target:
                    score += 40
        for c in range(n):
            for r in range(n - 10):
                window = [m[r + k][c] for k in range(11)]
                if window == target or window[::-1] == target:
                    score += 40

        # Rule 4: deviation from an even split of dark and light.
        dark = sum(v for row in m for v in row)
        pct = dark * 100 // (n * n)
        score += 10 * (abs(pct - 50) // 5)
        return score


_MASKS = [
    lambda r, c: (r + c) % 2 == 0,
    lambda r, c: r % 2 == 0,
    lambda r, c: c % 3 == 0,
    lambda r, c: (r + c) % 3 == 0,
    lambda r, c: (r // 2 + c // 3) % 2 == 0,
    lambda r, c: (r * c) % 2 + (r * c) % 3 == 0,
    lambda r, c: ((r * c) % 2 + (r * c) % 3) % 2 == 0,
    lambda r, c: ((r + c) % 2 + (r * c) % 3) % 2 == 0,
]


def _pick_version(length: int) -> int:
    for version, (ec_per_block, groups) in enumerate(_EC_M, start=1):
        data_codewords = sum(count * size for count, size in groups)
        header = 2 if version < 10 else 3     # mode nibble + char count
        if length + header <= data_codewords:
            return version
    raise ValueError(f"{length} bytes exceeds the level-M version-15 capacity")


def _encode_codewords(payload: bytes, version: int) -> list[int]:
    ec_per_block, groups = _EC_M[version - 1]
    total_data = sum(count * size for count, size in groups)

    bits: list[int] = []

    def push(value: int, width: int) -> None:
        for shift in range(width - 1, -1, -1):
            bits.append((value >> shift) & 1)

    push(0b0100, 4)                                  # byte mode
    push(len(payload), 8 if version < 10 else 16)
    for byte in payload:
        push(byte, 8)

    push(0, min(4, total_data * 8 - len(bits)))      # terminator
    while len(bits) % 8:
        bits.append(0)

    data = [int("".join(str(b) for b in bits[i:i + 8]), 2)
            for i in range(0, len(bits), 8)]
    # Spec pad bytes, alternating 0xEC / 0x11 from the first free codeword.
    pads = (0xEC, 0x11)
    while len(data) < total_data:
        data.append(pads[(len(data) - len(bits) // 8) % 2])

    blocks: list[list[int]] = []
    offset = 0
    for count, size in groups:
        for _ in range(count):
            blocks.append(data[offset:offset + size])
            offset += size
    ec_blocks = [_rs_remainder(b, ec_per_block) for b in blocks]

    # Interleave: one codeword from each block in turn, data then EC.
    out: list[int] = []
    for i in range(max(len(b) for b in blocks)):
        for b in blocks:
            if i < len(b):
                out.append(b[i])
    for i in range(ec_per_block):
        for b in ec_blocks:
            out.append(b[i])
    return out


def qr_matrix(text: str) -> list[list[bool]]:
    """Encode [text] and return the finished module grid."""
    payload = text.encode("utf-8")
    version = _pick_version(len(payload))
    codewords = _encode_codewords(payload, version)
    bits = [(cw >> shift) & 1 for cw in codewords for shift in range(7, -1, -1)]

    best: tuple[int, list[list[bool]]] | None = None
    for mask in range(8):
        m = _Matrix(version)
        m.draw_function_patterns()
        m.draw_version()
        m.place_data(bits)
        m.apply_mask(mask)
        m.draw_format(mask)
        score = m.penalty()
        if best is None or score < best[0]:
            best = (score, m.modules)
    assert best is not None
    return best[1]


def qr_svg(text: str, *, quiet_zone: int = 4, dark: str = "#2F3E46") -> str:
    """Encode [text] as a self-contained, scalable SVG QR code.

    The light modules are left transparent so the caller's own background shows
    through; scanners need the light/dark contrast, not a specific white.
    """
    modules = qr_matrix(text)
    n = len(modules)
    span = n + quiet_zone * 2

    # One path for every dark module beats one <rect> each: the markup stays
    # small enough to inline in a data URI.
    parts = []
    for r, row in enumerate(modules):
        c = 0
        while c < n:
            if not row[c]:
                c += 1
                continue
            start = c
            while c < n and row[c]:
                c += 1
            parts.append(f"M{start + quiet_zone} {r + quiet_zone}h{c - start}v1h-{c - start}z")

    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {span} {span}" '
        f'shape-rendering="crispEdges" role="img" aria-label="QR code">'
        f'<rect width="{span}" height="{span}" fill="#fff"/>'
        f'<path fill="{dark}" d="{"".join(parts)}"/>'
        f"</svg>"
    )
