"""Floor plans (rectangles plus optional L-shaped rooms), themed furniture and a
random valid solution."""
from . import objects as O
from .themes import THEMES, OBJ_ID, TWO_WIDE, FEMALE, MALE, VICTIM_F, VICTIM_M

ROOMS_FOR_SIZE = {5: (3, 4), 6: (4, 5), 7: (4, 6), 8: (5, 7), 9: (6, 8)}


def _split(N, k, rng):
    """Guillotine-split an N x N grid into k rectangles (r0, c0, h, w)."""
    rects = [(0, 0, N, N)]
    tries = 0
    while len(rects) < k and tries < 300:
        tries += 1
        rects.sort(key=lambda r: -(r[2] * r[3]) + rng.random() * 4)
        r0, c0, h, w = rects[0]
        horiz = h > w if h != w else rng.random() < 0.5
        if horiz and h >= 3:
            cut = rng.randint(1 if h < 4 else 2, h - (1 if h < 4 else 2))
            new = [(r0, c0, cut, w), (r0 + cut, c0, h - cut, w)]
        elif not horiz and w >= 3:
            cut = rng.randint(1 if w < 4 else 2, w - (1 if w < 4 else 2))
            new = [(r0, c0, h, cut), (r0, c0 + cut, h, w - cut)]
        else:
            continue
        if any(nr[2] * nr[3] < 2 for nr in new):
            continue
        rects = rects[1:] + new
    return rects


def _l_pairs(rects):
    """Index pairs of rectangles whose union is an L shape."""
    out = []
    for i, a in enumerate(rects):
        for j, b in enumerate(rects):
            if j <= i:
                continue
            ar0, ac0, ah, aw = a
            br0, bc0, bh, bw = b
            for (p, q) in ((a, b), (b, a)):
                pr0, pc0, ph, pw = p
                qr0, qc0, qh, qw = q
                if pr0 + ph == qr0:  # q directly below p
                    lo, hi = max(pc0, qc0), min(pc0 + pw, qc0 + qw)
                    if hi > lo and ((pc0 == qc0) != (pc0 + pw == qc0 + qw)):
                        out.append((i, j))
                if pc0 + pw == qc0:  # q directly right of p
                    lo, hi = max(pr0, qr0), min(pr0 + ph, qr0 + qh)
                    if hi > lo and ((pr0 == qr0) != (pr0 + ph == qr0 + qh)):
                        out.append((i, j))
    return out


def floor_plan(N, rng, k=None, l_rooms=None):
    lo, hi = ROOMS_FOR_SIZE.get(N, (max(3, N - 3), N - 1))
    k = k or rng.randint(lo, hi)
    if l_rooms is None:
        l_rooms = 1 if rng.random() < 0.6 else 0
        if N >= 8 and rng.random() < 0.3:
            l_rooms = 2
    rects = _split(N, k + l_rooms, rng)
    label = list(range(len(rects)))
    for _ in range(l_rooms):
        pairs = [(i, j) for i, j in _l_pairs(rects) if label[i] == i and label[j] == j]
        if not pairs:
            break
        i, j = rng.choice(pairs)
        label[j] = i
    area = [[0] * N for _ in range(N)]
    for idx, (r0, c0, h, w) in enumerate(rects):
        for r in range(r0, r0 + h):
            for c in range(c0, c0 + w):
                area[r][c] = label[idx]
    # renumber areas 1..k in reading order
    ren = {}
    for r in range(N):
        for c in range(N):
            if area[r][c] not in ren:
                ren[area[r][c]] = len(ren) + 1
            area[r][c] = ren[area[r][c]]
    return area


def furnish(N, area, theme, rng, density=(0.28, 0.42)):
    """Returns (anchor objects grid, carpet grid, room names {area: name})."""
    ids = sorted({a for row in area for a in row})
    pool_rooms = THEMES[theme]['rooms']
    rtypes = rng.sample(pool_rooms, len(ids))
    obj = [[0] * N for _ in range(N)]
    covered = [[False] * N for _ in range(N)]
    carpet = [[0] * N for _ in range(N)]
    names = {}
    for a, (rname, palette) in zip(ids, rtypes):
        names[a] = rname
        cells = [(r, c) for r in range(N) for c in range(N) if area[r][c] == a]
        rng.shuffle(cells)
        target = max(1, round(len(cells) * rng.uniform(*density)))
        pool = [w for w, wt in palette for _ in range(wt)]
        placed = 0
        for (r, c) in cells:
            if placed >= target:
                break
            if covered[r][c] or carpet[r][c]:
                continue
            w = rng.choice(pool)
            if w == 'carpet':
                carpet[r][c] = O.CARPET_ID
                for (rr, cc) in ((r, c + 1), (r + 1, c)):
                    if rr < N and cc < N and area[rr][cc] == a and not covered[rr][cc] and rng.random() < 0.5:
                        carpet[rr][cc] = O.CARPET_ID
                placed += 1
                continue
            oid = OBJ_ID[w]
            if w in TWO_WIDE:
                if c + 1 < N and area[r][c + 1] == a and not covered[r][c + 1] and not carpet[r][c + 1]:
                    obj[r][c] = oid
                    covered[r][c] = covered[r][c + 1] = True
                    placed += 2
                continue
            obj[r][c] = oid
            covered[r][c] = True
            placed += 1
            if w == 'table':  # tables attract chairs
                for (rr, cc) in rng.sample([(r - 1, c), (r + 1, c), (r, c - 1), (r, c + 1)], 4):
                    if 0 <= rr < N and 0 <= cc < N and area[rr][cc] == a and not covered[rr][cc] \
                            and not carpet[rr][cc] and rng.random() < 0.5:
                        obj[rr][cc] = OBJ_ID['chair']
                        covered[rr][cc] = True
                        placed += 1
                        break
    return obj, carpet, names


def expanded(obj, N):
    return O.expand_footprints([row[:] for row in obj], N, N)


def place_people(N, area, eobj, rng, tries=300):
    """Random solution: one person per row and column on standable squares, with
    exactly one area holding exactly two people (victim + murderer).
    Returns (cells as (r, c) with the victim last, murderer index) or None."""
    ok = lambda r, c: O.standable(eobj[r][c])
    for _ in range(tries):
        cols = list(range(N))
        rng.shuffle(cols)
        for _ in range(300):
            bad = [r for r in range(N) if not ok(r, cols[r])]
            if not bad:
                break
            r = rng.choice(bad)
            s = rng.randrange(N)
            cols[r], cols[s] = cols[s], cols[r]
        if not all(ok(r, cols[r]) for r in range(N)):
            continue
        cells = [(r, cols[r]) for r in range(N)]
        by_area = {}
        for x in cells:
            by_area.setdefault(area[x[0]][x[1]], []).append(x)
        pairs = [v for v in by_area.values() if len(v) == 2]
        if not pairs:
            continue
        vm = list(rng.choice(pairs))
        rng.shuffle(vm)
        victim_cell, murderer_cell = vm
        others = [x for x in cells if x not in vm] + [murderer_cell]
        rng.shuffle(others)
        sol = others + [victim_cell]
        return sol, sol.index(murderer_cell)
    return None


def cast(N, rng):
    """Names and genders: suspects A.. get names starting with their letter."""
    female = [rng.random() < 0.5 for _ in range(N)]
    # keep at least two of each gender among suspects for gender clues
    sus = female[:-1]
    if sum(sus) < 2 or sum(sus) > len(sus) - 2:
        idx = list(range(N - 1))
        rng.shuffle(idx)
        for k, i in enumerate(idx):
            female[i] = k % 2 == 0
    names = []
    for i in range(N - 1):
        letter = chr(65 + i)
        names.append(rng.choice((FEMALE if female[i] else MALE)[letter]))
    names.append(rng.choice(VICTIM_F if female[-1] else VICTIM_M))
    return names, female
