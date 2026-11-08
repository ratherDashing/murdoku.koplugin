"""Object catalogue, read from the plugin's murdoku_objects.lua so the two never drift."""
import os
import re

LUA_OBJECTS = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'murdoku.koplugin', 'murdoku_objects.lua')


def _load():
    objs = {}
    text = open(LUA_OBJECTS, encoding='utf-8').read()
    for m in re.finditer(r'\[(\d+)\]\s*=\s*\{\s*name\s*=\s*"([^"]*)",\s*occupiable\s*=\s*(\w+)', text):
        objs[int(m.group(1))] = (m.group(2), {'true': True, 'false': False}.get(m.group(3)))
    return objs


OBJECTS = _load()
VOID = {8, 33}
CARPET_ID = 5   # value stored in carpet_objects_r_c

# Multi-cell objects are stored at their anchor cell only (site format) and
# cover the neighbouring empty cells (same rule as murdoku_puzzle.lua).
RIGHT1 = {6, 119, 21, 22, 90}
RIGHT2 = {56}
DOWN1 = {7, 120}
BIG2X2 = {54}


def name(i):
    return OBJECTS.get(i, ('Object', True))[0]


def standable(i):
    if not i:
        return True
    if i in VOID:
        return False
    o = OBJECTS.get(i)
    return True if o is None else o[1] is True


def ids_named(word):
    """All object ids whose display name matches `word` (case-insensitive)."""
    w = word.lower()
    return {i for i, (n, occ) in OBJECTS.items() if occ is not None and n.lower() == w}


def expand_footprints(objs, H, W):
    """objs: list of rows (0-based). Fill neighbouring empty cells of multi-cell objects."""
    add = []
    for r in range(H):
        for c in range(W):
            g = objs[r][c]
            if g in RIGHT1 and c + 1 < W:
                add.append((r, c + 1, g))
            if g in RIGHT2:
                add += [(r, c + k, g) for k in (1, 2) if c + k < W]
            if g in DOWN1 and r + 1 < H:
                add.append((r + 1, c, g))
            if g in BIG2X2:
                add += [(r + a, c + b, g) for a, b in ((0, 1), (1, 0), (1, 1)) if r + a < H and c + b < W]
    for r, c, g in add:
        if not objs[r][c]:
            objs[r][c] = g
    return objs
