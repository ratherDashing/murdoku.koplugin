"""Puzzle model and structured clue atoms.

Cells are integers i = r * W + c (0-based). A person's domain is a set of cells.
Every clue sentence becomes one or more atoms; the solver only sees atoms.

Rules encoded here (shared with the plugin's "How to play"):
  * exactly one person per row and per column (the grid is N x N with N people);
  * nobody stands on an obstacle;
  * "beside" = orthogonally adjacent AND in the same area;
  * north/south/east/west = anywhere above/below/right/left, any area;
  * the victim (last person) is alone in an area with exactly one other person:
    the murderer.
"""
from . import objects as O


class Puzzle:
    def __init__(self, H, W, area, obj, carpet, names, female, room_names, sol=None, murderer=None, title=''):
        """area/obj/carpet: lists of rows (0-based). obj must already be expanded
        (multi-cell objects present on every covered cell)."""
        self.H, self.W = H, W
        self.n = len(names)
        self.victim = self.n - 1
        self.names, self.female = list(names), list(female)
        self.room_names = dict(room_names)
        self.sol, self.murderer, self.title = sol, murderer, title
        self.ncell = H * W
        self.area = [area[i // W][i % W] for i in range(self.ncell)]
        self.obj = [obj[i // W][i % W] for i in range(self.ncell)]
        self.carpet = [bool(carpet[i // W][i % W]) for i in range(self.ncell)]
        self.row = [i // W for i in range(self.ncell)]
        self.col = [i % W for i in range(self.ncell)]
        self.ok = frozenset(i for i in range(self.ncell) if O.standable(self.obj[i]))
        self.areas = sorted(set(self.area))
        self.area_cells = {a: frozenset(i for i in range(self.ncell) if self.area[i] == a) for a in self.areas}
        self.nbrs = []
        for i in range(self.ncell):
            r, c = self.row[i], self.col[i]
            lst = []
            for dr, dc in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                rr, cc = r + dr, c + dc
                if 0 <= rr < H and 0 <= cc < W:
                    lst.append(rr * W + cc)
            self.nbrs.append(lst)
        self.exact = (self.n == H == W)  # one per row/col, every row/col filled
        # False: two-person pruning ignores 'nobody shares a row/column' (the step
        # solver toggles this to recognise 'line-clash' deductions).
        self.line_aware = True
        self._cache = {}

    def rc(self, i):
        return self.row[i], self.col[i]

    def A(self, i):
        return self.area[i]

    def pron(self, j):
        return ('She', 'her', 'her') if self.female[j] else ('He', 'him', 'his')

    # ---- cell sets
    def obj_cells(self, word):
        """Cells holding an object whose name is `word` (any cell of a multi-cell object)."""
        key = ('obj', word)
        if key not in self._cache:
            if word == 'carpet':
                s = frozenset(i for i in range(self.ncell) if self.carpet[i] or self.obj[i] == O.CARPET_ID)
            else:
                ids = O.ids_named(word)
                s = frozenset(i for i in range(self.ncell) if self.obj[i] in ids)
            self._cache[key] = s
        return self._cache[key]

    def on_set(self, word):
        return self.obj_cells(word) & self.ok

    def beside_set(self, word):
        key = ('beside', word)
        if key not in self._cache:
            src = self.obj_cells(word)
            self._cache[key] = frozenset(x for x in self.ok
                                         if any(y in src and self.area[y] == self.area[x] for y in self.nbrs[x]))
        return self._cache[key]

    def area_set(self, areas):
        s = set()
        for a in areas:
            s |= self.area_cells.get(a, frozenset())
        return frozenset(s & self.ok)

    def row_set(self, r):
        return frozenset(x for x in self.ok if self.row[x] == r)

    def col_set(self, c):
        return frozenset(x for x in self.ok if self.col[x] == c)

    def corner_set(self):
        """Squares with a wall (area border or scene edge) on two sides that meet."""
        if 'corner' not in self._cache:
            s = set()
            for x in self.ok:
                r, c = self.row[x], self.col[x]

                def wall(dr, dc):
                    rr, cc = r + dr, c + dc
                    return not (0 <= rr < self.H and 0 <= cc < self.W) or self.area[rr * self.W + cc] != self.area[x]
                if (wall(-1, 0) or wall(1, 0)) and (wall(0, -1) or wall(0, 1)):
                    s.add(x)
            self._cache['corner'] = frozenset(s)
        return self._cache['corner']

    def free(self, x, y):
        """Two people can stand at x and y together (different row and column)."""
        if not self.line_aware:
            return True
        return self.row[x] != self.row[y] and self.col[x] != self.col[y]


# ---------------------------------------------------------------- atoms
class Atom:
    unary = False
    is_global = False
    positional = False
    who = 0

    def check(self, pz, asg, complete):
        """asg: dict person -> cell (placed people only)."""
        return True

    def prune(self, pz, D):
        """Return a list of (person, cell) eliminations that follow from this atom."""
        return []

    def involves(self, pz):
        return [self.who]


class In(Atom):
    """Owner stands in `cells` (or, with neg, outside them)."""
    unary = True

    def __init__(self, who, cells, neg=False, positional=False):
        self.who, self.cells, self.neg, self.positional = who, frozenset(cells), neg, positional

    def allowed(self, pz):
        return (pz.ok - self.cells) if self.neg else (self.cells & pz.ok)


class Only(Atom):
    """Nobody but the owner (and the exempt people) stands in `cells`.
    Static: applied to the starting domains."""

    def __init__(self, who, cells, exempt=()):
        self.who, self.cells, self.exempt = who, frozenset(cells), frozenset(exempt)

    def check(self, pz, asg, complete):
        return not any(j != self.who and j not in self.exempt and x in self.cells for j, x in asg.items())

    def victims(self, pz):
        return [j for j in range(pz.n) if j != self.who and j not in self.exempt]

    def involves(self, pz):
        return list(range(pz.n))


def match(pz, j, x, cond):
    """cond: None | ('person', k) | ('female', bool) | ('cells', set)"""
    if cond is None:
        return True
    t, v = cond
    if t == 'person':
        return j == v
    if t == 'female':
        return pz.female[j] == v
    if t == 'cells':
        return x in v
    raise ValueError(cond)


def _could(pz, D, j, cells, cond, x):
    """Could person j stand in `cells`, matching cond, alongside the owner at x?"""
    if cond and cond[0] == 'person' and cond[1] != j:
        return False
    if cond and cond[0] == 'female' and pz.female[j] != cond[1]:
        return False
    for y in D[j]:
        if y in cells and pz.free(x, y) and (not cond or cond[0] != 'cells' or y in cond[1]):
            return True
    return False


def _forced_area(pz, D, j):
    a = None
    for x in D[j]:
        if a is None:
            a = pz.area[x]
        elif pz.area[x] != a:
            return None
    return a


def _type_ok(pz, j, cond):
    """Does person j match a person/gender condition regardless of position?"""
    return cond is None or (cond[0] == 'female' and pz.female[j] == cond[1]) or (cond[0] == 'person' and j == cond[1])


class AreaCount(Atom):
    """Company in the owner's area.
      alone      no one else
      alonewith  exactly one other person, matching cond
      with       at least one other person matching cond
      none       no other person matching cond
    """

    def __init__(self, who, mode, cond=None):
        self.who, self.mode, self.cond = who, mode, cond

    def involves(self, pz):
        return list(range(pz.n))

    def check(self, pz, asg, complete):
        me = asg.get(self.who)
        if me is None:
            return True
        a = pz.area[me]
        others = [(j, x) for j, x in asg.items() if j != self.who and pz.area[x] == a]
        m, cond = self.mode, self.cond
        if m == 'alone':
            return not others
        if m == 'alonewith':
            if len(others) > 1:
                return False
            if others and not match(pz, others[0][0], others[0][1], cond):
                return False
            if cond and cond[0] == 'person' and cond[1] in asg and pz.area[asg[cond[1]]] != a:
                return False
            return len(others) == 1 if complete else True
        if m == 'with':
            ok = any(match(pz, j, x, cond) for j, x in others)
            if cond and cond[0] == 'person' and cond[1] in asg:
                return ok
            return ok if complete else True
        if m == 'none':
            return not any(match(pz, j, x, cond) for j, x in others)
        raise ValueError(m)

    def prune(self, pz, D):
        out = []
        w, m, cond = self.who, self.mode, self.cond
        others = [j for j in range(pz.n) if j != w]
        forced = {j: _forced_area(pz, D, j) for j in range(pz.n)}
        for x in D[w]:
            a = pz.area[x]
            ac = pz.area_cells[a]
            must = [j for j in others if forced[j] == a]
            if m == 'alone':
                if must:
                    out.append((w, x))
            elif m == 'alonewith':
                if len(must) > 1 or any(not (_type_ok(pz, j, cond) or cond[0] == 'cells') for j in must):
                    out.append((w, x))
                elif not any(_could(pz, D, j, ac, cond, x) for j in others):
                    out.append((w, x))
            elif m == 'with':
                if not any(_could(pz, D, j, ac, cond, x) for j in others):
                    out.append((w, x))
            elif m == 'none':
                if any(forced[j] == a and cond is not None and cond[0] != 'cells' and _type_ok(pz, j, cond) for j in others):
                    out.append((w, x))
        fa = forced[w]
        if fa is not None:
            ac = pz.area_cells[fa]
            for j in others:
                if m == 'alone' or (m == 'none' and cond is not None and cond[0] != 'cells' and _type_ok(pz, j, cond)):
                    out += [(j, y) for y in D[j] & ac]
                elif m == 'alonewith' and cond and cond[0] == 'person':
                    if j == cond[1]:
                        out += [(j, y) for y in D[j] - ac]
                    else:
                        out += [(j, y) for y in D[j] & ac]
                elif m == 'alonewith' and cond and cond[0] == 'female' and pz.female[j] != cond[1]:
                    out += [(j, y) for y in D[j] & ac]
                elif m == 'with' and cond and cond[0] == 'person' and j == cond[1]:
                    out += [(j, y) for y in D[j] - ac]
            if m == 'alonewith':
                must = [j for j in others if forced[j] == fa]
                if must:
                    out += [(j, y) for j in others if j not in must for y in D[j] & ac]
        return out


# relations between two people: fn(pz, a, b) with a = owner's cell, b = other's cell
def rel_fn(kind, k=None):
    if kind == 'north':
        return lambda pz, a, b: pz.row[a] < pz.row[b]
    if kind == 'south':
        return lambda pz, a, b: pz.row[a] > pz.row[b]
    if kind == 'west':
        return lambda pz, a, b: pz.col[a] < pz.col[b]
    if kind == 'east':
        return lambda pz, a, b: pz.col[a] > pz.col[b]
    if kind == 'rows':      # owner is exactly k rows south (k<0: north) of other
        return lambda pz, a, b: pz.row[a] - pz.row[b] == k
    if kind == 'cols':      # owner is exactly k columns east (k<0: west) of other
        return lambda pz, a, b: pz.col[a] - pz.col[b] == k
    if kind == 'samearea':
        return lambda pz, a, b: pz.area[a] == pz.area[b]
    raise ValueError(kind)


class Rel(Atom):
    """Relation between the owner and another named person."""

    def __init__(self, who, other, kind, k=None, positional=True):
        self.who, self.other, self.kind, self.k = who, other, kind, k
        self.fn = rel_fn(kind, k)
        self.positional = positional

    def involves(self, pz):
        return [self.who, self.other]

    def check(self, pz, asg, complete):
        a, b = asg.get(self.who), asg.get(self.other)
        if a is None or b is None:
            return True
        return self.fn(pz, a, b)

    def prune(self, pz, D):
        out = []
        A, B = D[self.who], D[self.other]
        for a in A:
            if not any(self.fn(pz, a, b) for b in B if pz.free(a, b)):
                out.append((self.who, a))
        for b in B:
            if not any(self.fn(pz, a, b) for a in A if pz.free(a, b)):
                out.append((self.other, b))
        return out


class Exists(Atom):
    """Someone else (matching gender `fem` if given) stands at y with rel(owner, y)
    and y in `cells` (if given). E.g. 'Someone else in her area was sitting in a chair.'"""

    def __init__(self, who, kind, cells=None, fem=None, k=None, positional=False):
        self.who, self.kind, self.cells, self.fem, self.k = who, kind, cells, fem, k
        self.fn = rel_fn(kind, k)
        self.positional = positional

    def involves(self, pz):
        return list(range(pz.n))

    def _cand(self, pz, j):
        return j != self.who and (self.fem is None or pz.female[j] == self.fem)

    def check(self, pz, asg, complete):
        me = asg.get(self.who)
        if me is None or not complete:
            return True
        return any(self._cand(pz, j) and self.fn(pz, me, y) and (self.cells is None or y in self.cells)
                   for j, y in asg.items())

    def prune(self, pz, D):
        out = []
        for x in D[self.who]:
            ok = False
            for j in range(pz.n):
                if not self._cand(pz, j):
                    continue
                for y in D[j]:
                    if pz.free(x, y) and self.fn(pz, x, y) and (self.cells is None or y in self.cells):
                        ok = True
                        break
                if ok:
                    break
            if not ok:
                out.append((self.who, x))
        return out


class Count(Atom):
    """General clue: between lo and hi people (inclusive) stand in `cells`."""
    is_global = True

    def __init__(self, cells, lo, hi):
        self.cells, self.lo, self.hi = frozenset(cells), lo, hi
        self.who = None

    def involves(self, pz):
        return list(range(pz.n))

    def check(self, pz, asg, complete):
        k = sum(1 for x in asg.values() if x in self.cells)
        if k > self.hi:
            return False
        return k >= self.lo if complete else True

    def prune(self, pz, D):
        out = []
        placed = [j for j in range(pz.n) if len(D[j]) == 1 and next(iter(D[j])) in self.cells]
        if len(placed) >= self.hi:
            out += [(j, x) for j in range(pz.n) if j not in placed for x in D[j] & self.cells]
        can = [j for j in range(pz.n) if D[j] & self.cells]
        if len(can) <= self.lo:
            out += [(j, x) for j in can for x in D[j] - self.cells]
        return out


class NoEmptyArea(Atom):
    """General clue: every area holds at least one person."""
    is_global = True
    who = None

    def involves(self, pz):
        return list(range(pz.n))

    def check(self, pz, asg, complete):
        if not complete:
            return True
        used = {pz.area[x] for x in asg.values()}
        return len(used) == len(pz.areas)

    def prune(self, pz, D):
        out = []
        for a in pz.areas:
            can = [j for j in range(pz.n) if any(pz.area[x] == a for x in D[j])]
            if len(can) == 1:
                out += [(can[0], x) for x in D[can[0]] if pz.area[x] != a]
        return out


class NoLoner(Atom):
    """General clue: no area contained exactly one person."""
    is_global = True
    who = None

    def involves(self, pz):
        return list(range(pz.n))

    def check(self, pz, asg, complete):
        if not complete:
            return True
        cnt = {}
        for x in asg.values():
            cnt[pz.area[x]] = cnt.get(pz.area[x], 0) + 1
        return all(k != 1 for k in cnt.values())

    def prune(self, pz, D):
        out = []
        for j in range(pz.n):
            for x in D[j]:
                a = pz.area[x]
                if not any(pz.free(x, y) and pz.area[y] == a for k in range(pz.n) if k != j for y in D[k]):
                    out.append((j, x))
        return out
