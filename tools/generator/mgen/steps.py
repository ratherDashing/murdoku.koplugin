"""Human-style STEP solver that names the technique used at every step, and the
"designed aha" profile built on it.

At each step it looks for the cheapest technique level that makes progress,
records how many moves were available at that level, applies one, and goes on.
A step where no level-0/1 move exists is a BOTTLENECK: the player has to find a
cleverer idea there.

Techniques (level):
  0 naked-single   a person has one square left -> place, block row+col
  0 hidden-line    only one person can still use a row/col -> they are in it
  1 line-confine   a person's squares all lie in one row/col -> block it for others
  1 clue-*         direct elimination by one clue (relation, area/alone/with,
                   'only person on X', existential 'someone ...', general clue)
  2 forced-cell    only one square of a row/col is open to anyone -> someone is
                   there (identity unknown) -> block its column/row
  2 cross-block    every square of person P sees cell X -> nobody else at X
  2 line-clash     a two-person clue fails because the pair would share a
                   row/col (one-row area, 'with X' in a strip, ...)
  3 subset         k people (k=2,3) confined to k rows/cols -> block them
  3 witness        the 'someone'/'with a man'/'alone with' companion can only be
                   one person, or only one square ("who can be ...?")
  4 contra-short   one-level what-if refuted by <=4 basic moves
  4 contra-long    what-if needing a longer chain (tedious bifurcation)
Opening tag:
    intersection   a person's start domain is tiny only because two of their
                   conditions intersect (each alone allows >=3 squares)

The grader (solver.grade, what-if count of solver.logic_solve) still labels
difficulty; this module only measures *how* a puzzle is solved.
"""
import itertools

from .model import In, Only, Rel, AreaCount, Exists
from .solver import own_domains, Contradiction

LEVEL = {'naked-single': 0, 'hidden-line': 0, 'line-confine': 1, 'clue-rel': 1, 'clue-area': 1, 'clue-only': 1,
         'clue-exists': 1, 'clue-global': 1, 'clue-other': 1, 'forced-cell': 2, 'cross-block': 2, 'line-clash': 2,
         'subset': 3, 'witness': 3, 'contra-short': 4, 'contra-long': 4}
AHA = {'line-clash', 'cross-block', 'subset', 'witness', 'contra-short', 'intersection'}
ADVANCED = AHA | {'forced-cell', 'contra-long'}


def _clue_name(at):
    if isinstance(at, Rel):
        return 'clue-rel'
    if isinstance(at, AreaCount):
        return 'clue-area'
    if isinstance(at, Only):
        return 'clue-only'
    if isinstance(at, Exists):
        return 'clue-exists'
    if getattr(at, 'is_global', False):
        return 'clue-global'
    return 'clue-other'


def _prune(pz, at, D):
    if isinstance(at, Only):
        return [(j, x) for j in at.victims(pz) for x in D[j] & at.cells]
    return at.prune(pz, D)


class TooManyWhatIfs(Exception):
    pass


class StepSolver:
    def __init__(self, pz, atoms, disable=(), max_whatifs=None):
        self.pz = pz
        self.n = pz.n
        self.disable = set(disable)
        self.max_whatifs = max_whatifs
        self.D0 = own_domains(pz, atoms)
        self.dyn = [at for at in atoms if not isinstance(at, In)]
        self.witness_atoms = [at for at in self.dyn
                              if isinstance(at, Exists) or
                              (isinstance(at, AreaCount) and at.mode in ('with', 'alonewith')
                               and not (at.cond and at.cond[0] == 'person'))]
        by = [[] for _ in range(pz.n)]
        for at in atoms:
            if isinstance(at, In):
                by[at.who].append(at)
        self.intersection = []
        for j in range(pz.n):
            us = by[j]
            if len(us) >= 2 and len(self.D0[j]) <= 2:
                if all(len(u.allowed(pz)) >= 3 for u in us):
                    self.intersection.append(j)

    # ------------------------------------------------------------ helpers
    def why_contradiction(self, D):
        """None, or the reason the position is impossible (same shapes as solver.Contradiction)."""
        pz, n = self.pz, self.n
        for j, d in enumerate(D):
            if not d:
                return ('empty', j)
        if pz.exact:
            for axis, size, lineof in ((0, pz.H, pz.row), (1, pz.W, pz.col)):
                used = set()
                for d in D:
                    used |= {lineof[x] for x in d}
                for line in range(size):
                    if line not in used:
                        return ('row' if axis == 0 else 'col', line)
        asg = {j: next(iter(D[j])) for j in range(n) if len(D[j]) == 1}
        seen_r, seen_c = {}, {}
        for j, x in asg.items():
            if pz.row[x] in seen_r:
                return ('share', seen_r[pz.row[x]], j)
            if pz.col[x] in seen_c:
                return ('share', seen_c[pz.col[x]], j)
            seen_r[pz.row[x]] = j
            seen_c[pz.col[x]] = j
        complete = len(asg) == n
        for at in self.dyn:
            if not at.check(pz, asg, complete):
                return ('clue', at)
        return None

    @staticmethod
    def _real(D, rm):
        return frozenset((j, x) for j, x in rm if x in D[j])

    # ------------------------------------------------------------ technique finders
    # each yields (tech, removals frozenset, info)
    def t_naked(self, D, placed):
        pz = self.pz
        for j in range(self.n):
            if len(D[j]) == 1 and j not in placed:
                (x,) = tuple(D[j])
                rm = self._real(D, [(k, y) for k in range(self.n) if k != j for y in D[k]
                                    if pz.row[y] == pz.row[x] or pz.col[y] == pz.col[x]])
                yield ('naked-single', rm, ('place', j, x))

    def t_hidden(self, D, placed):
        pz = self.pz
        if not pz.exact:
            return
        for axis, size, lineof in ((0, pz.H, pz.row), (1, pz.W, pz.col)):
            for line in range(size):
                who = [j for j in range(self.n) if any(lineof[y] == line for y in D[j])]
                if len(who) == 1:
                    j = who[0]
                    rm = self._real(D, [(j, y) for y in D[j] if lineof[y] != line])
                    if rm:
                        yield ('hidden-line', rm, ('line', axis, line, j))

    def t_confine(self, D, placed):
        pz = self.pz
        for j in range(self.n):
            if j in placed or len(D[j]) < 2:
                continue
            for axis, lineof in ((0, pz.row), (1, pz.col)):
                ls = {lineof[y] for y in D[j]}
                if len(ls) == 1:
                    line = next(iter(ls))
                    rm = self._real(D, [(k, y) for k in range(self.n) if k != j for y in D[k] if lineof[y] == line])
                    if rm:
                        yield ('line-confine', rm, ('line', axis, line, j))

    def t_clue(self, D, placed, want_clash):
        pz = self.pz
        for at in self.dyn:
            rm = self._real(D, _prune(pz, at, D))
            if not rm:
                continue
            pz.line_aware = False
            try:
                relaxed = self._real(D, _prune(pz, at, D))
            finally:
                pz.line_aware = True
            plain = rm & relaxed
            clash = rm - relaxed
            if not want_clash and plain:
                yield (_clue_name(at), plain, ('clue', at))
            if want_clash and clash:
                yield ('line-clash', clash, ('clue', at))

    def t_forced_cell(self, D, placed):
        pz = self.pz
        if not pz.exact:
            return
        for axis, size, lineof, other in ((0, pz.H, pz.row, pz.col), (1, pz.W, pz.col, pz.row)):
            for line in range(size):
                cells = set()
                for d in D:
                    cells |= {y for y in d if lineof[y] == line}
                if len(cells) == 1:
                    (x,) = tuple(cells)
                    rm = self._real(D, [(k, y) for k in range(self.n) for y in D[k] if other[y] == other[x] and y != x])
                    if rm:
                        yield ('forced-cell', rm, ('cell', x, None, axis))

    def t_cross(self, D, placed):
        pz, n = self.pz, self.n
        for j in range(n):
            if j in placed or len(D[j]) < 2 or len(D[j]) > 8:
                continue
            dj = D[j]
            rows = {pz.row[y] for y in dj}
            cols = {pz.col[y] for y in dj}
            if len(rows) == 1 or len(cols) == 1:
                continue  # that's line-confine
            for r in rows:
                for c in cols:
                    x = r * pz.W + c
                    if all(pz.row[y] == r or pz.col[y] == c for y in dj):
                        rm = self._real(D, [(k, x) for k in range(n) if k != j])
                        if rm:
                            yield ('cross-block', rm, ('cell', x, j, None))

    def t_subset(self, D, placed):
        pz, n = self.pz, self.n
        if not pz.exact:
            return
        free = [j for j in range(n) if j not in placed and len(D[j]) > 1]
        for axis, lineof in ((0, pz.row), (1, pz.col)):
            lines = {j: frozenset(lineof[y] for y in D[j]) for j in free}
            for k in (2, 3):
                cand = [j for j in free if len(lines[j]) <= k]
                for combo in itertools.combinations(cand, k):
                    u = frozenset().union(*(lines[j] for j in combo))
                    if len(u) == k:
                        rm = self._real(D, [(o, y) for o in range(n) if o not in combo for y in D[o] if lineof[y] in u])
                        if rm:
                            yield ('subset', rm, ('subset', axis, tuple(sorted(u)), combo))

    def _witnesses(self, D, at, x):
        """Possible (person, cell) companions for atom `at` if its owner stands at x."""
        pz = self.pz
        out = []
        for j in range(self.n):
            if j == at.who:
                continue
            if isinstance(at, Exists):
                if at.fem is not None and pz.female[j] != at.fem:
                    continue
                for y in D[j]:
                    if pz.free(x, y) and at.fn(pz, x, y) and (at.cells is None or y in at.cells):
                        out.append((j, y))
            else:
                cond = at.cond
                if cond and cond[0] == 'female' and pz.female[j] != cond[1]:
                    continue
                a = pz.area[x]
                for y in D[j]:
                    if pz.area[y] == a and pz.free(x, y) and (not cond or cond[0] != 'cells' or y in cond[1]):
                        out.append((j, y))
        return out

    def t_witness(self, D, placed):
        pz, n = self.pz, self.n
        for at in self.witness_atoms:
            W = set()
            for x in D[at.who]:
                W |= set(self._witnesses(D, at, x))
            if not W:
                continue
            persons = {j for j, _ in W}
            cells = {y for _, y in W}
            if len(persons) == 1:
                (j,) = tuple(persons)
                if j in placed:
                    continue
                rm = self._real(D, [(j, y) for y in D[j] if y not in cells])
                if rm:
                    yield ('witness', rm, ('who', at, j))
            if len(cells) == 1:
                (x,) = tuple(cells)
                rm = self._real(D, [(k, y) for k in range(n) for y in D[k]
                                    if (pz.row[y] == pz.row[x] or pz.col[y] == pz.col[x]) and y != x] +
                                [(k, x) for k in range(n) if k not in persons])
                if rm:
                    yield ('witness', rm, ('where', at, x))

    # ------------------------------------------------------------ driver
    def finders(self, level):
        f = {0: (self.t_naked, self.t_hidden),
             1: (self.t_confine, lambda D, p: self.t_clue(D, p, False)),
             2: (self.t_forced_cell, self.t_cross, lambda D, p: self.t_clue(D, p, True)),
             3: (self.t_subset, self.t_witness)}
        return f.get(level, ())

    def moves_at(self, D, placed, level, first_only=False):
        out = []
        for fn in self.finders(level):
            for mv in fn(D, placed):
                if mv[0] in self.disable:
                    continue
                if mv[1] or mv[2][0] == 'place':
                    out.append(mv)
                    if first_only:
                        return out
        return out

    @staticmethod
    def apply(D, placed, mv, order=None):
        for j, x in mv[1]:
            D[j].discard(x)
        if mv[2][0] == 'place':
            placed.add(mv[2][1])
            if order is not None:
                order.append(mv[2][1])

    def fixpoint(self, D, placed, maxlevel, budget=300):
        """Apply moves up to maxlevel until stuck. On contradiction raises
        Contradiction(why) with attribute .depth = moves made before it."""
        k = 0
        while k < budget:
            why = self.why_contradiction(D)
            if why:
                e = Contradiction(why)
                e.depth = k
                raise e
            if len(placed) == self.n:
                return k
            for lv in range(maxlevel + 1):
                mv = self.moves_at(D, placed, lv, first_only=True)
                if mv:
                    self.apply(D, placed, mv[0])
                    k += 1
                    break
            else:
                return k
        return k

    def what_if(self, D, placed):
        """One-level contradiction ('if X were at s, ...'). Refutations needing only
        basic (level<=1) moves and <=4 of them are 'contra-short' (the human 'that
        would leave Y no square'); longer ones, or ones needing advanced moves
        inside, are 'contra-long'."""
        n = self.n
        cands = [(j, x) for j in sorted(range(n), key=lambda q: (len(D[q]), q)) if len(D[j]) > 1 for x in sorted(D[j])]
        for maxlevel in (1, 3):
            best = None
            for j, x in cands:
                T = [set(d) for d in D]
                T[j] = {x}
                try:
                    self.fixpoint(T, set(placed), maxlevel)
                except Contradiction as e:
                    if best is None or e.depth < best[0]:
                        best = (e.depth, j, x, e.why)
                    if maxlevel == 1 and e.depth <= 1:
                        break
                    if maxlevel == 3:
                        break
            if best:
                d, j, x, why = best
                name = 'contra-short' if (maxlevel == 1 and d <= 4) else 'contra-long'
                if name in self.disable:
                    if maxlevel == 1 and 'contra-long' not in self.disable:
                        return ('contra-long', frozenset([(j, x)]), ('whatif', j, x, d, why))
                    return None
                return (name, frozenset([(j, x)]), ('whatif', j, x, d, why))
        return None

    def run(self, max_steps=2000):
        n = self.n
        D = [set(d) for d in self.D0]
        placed, order, steps = set(), [], []
        status = 'stuck'
        whatifs = 0
        for _ in range(max_steps):
            if self.why_contradiction(D):
                status = 'contradiction'
                break
            if len(placed) == n:
                status = 'solved'
                break
            mv, lv, avail = None, None, 0
            for lev in range(4):
                ms = self.moves_at(D, placed, lev)
                if ms:
                    ms.sort(key=lambda m: m[2][0] != 'place')   # placements first
                    mv, lv, avail = ms[0], lev, len(ms)
                    break
            if mv is None:
                whatifs += 1
                if self.max_whatifs is not None and whatifs > self.max_whatifs:
                    status = 'too-many-whatifs'
                    break
                w = self.what_if(D, placed)
                if w is None:
                    break
                mv, lv, avail = w, 4, 1
            before = len(placed)
            self.apply(D, placed, mv, order)
            steps.append(dict(tech=mv[0], level=lv, avail=avail, info=mv[2], placed_before=before,
                              removed=len(mv[1]), rm=mv[1]))
        return dict(status=status, steps=steps, order=order, D=D, intersection=self.intersection)


# ------------------------------------------------------------------ profile / metrics
def episodes(steps, n):
    """Group advanced (level>=2) steps between two placements into one 'episode' =
    one moment where the player had to think. Its key technique is the first step
    of the run (the one that broke the stall)."""
    eps, cur = [], None
    for i, s in enumerate(steps):
        if s['level'] >= 2:
            if cur is None:
                cur = dict(pos=s['placed_before'] / n, placed=s['placed_before'], key=s['tech'], techs=[],
                           start=i, whatifs=0)
            cur['techs'].append(s['tech'])
            cur['whatifs'] += s['tech'].startswith('contra')
        elif s['info'][0] == 'place' and cur is not None:
            eps.append(cur)
            cur = None
    if cur is not None:
        eps.append(cur)
    for e in eps:  # cascade = placements by basic moves after the episode until the next one
        k = 0
        for t in steps[e['start'] + len(e['techs']):]:
            if t['level'] >= 2:
                break
            k += t['info'][0] == 'place'
        e['cascade'] = k
        # an aha episode is broken by a named aha technique without a pile of what-ifs
        e['aha'] = (e['key'] in AHA or 'witness' in e['techs'] or 'subset' in e['techs']) and e['whatifs'] <= 3
        e['aha_key'] = e['key'] if e['key'] in AHA else next((t for t in e['techs'] if t in AHA), e['key'])
    return eps


def profile(pz, atoms, disable=(), max_whatifs=None):
    S = StepSolver(pz, atoms, disable, max_whatifs)
    R = S.run()
    steps = R['steps']
    n = pz.n
    tech_counts = {}
    for s in steps:
        tech_counts[s['tech']] = tech_counts.get(s['tech'], 0) + 1
    if R['intersection']:
        tech_counts['intersection'] = len(R['intersection'])
    eps = episodes(steps, n)
    aha = [e for e in eps if e['aha']]
    mid = [e for e in aha if 0.15 <= e['pos'] <= 0.8]
    placements = [s for s in steps if s['info'][0] == 'place']
    whatifs = sum(v for k, v in tech_counts.items() if k.startswith('contra'))
    ok = len(pz.ok)
    return dict(status=R['status'], n_steps=len(steps), techs=tech_counts, episodes=eps,
                n_eps=len(eps), n_aha=len(aha), aha_mid=len(mid),
                aha_keys=[e['aha_key'] for e in aha],
                max_cascade=max([e['cascade'] for e in aha] or [0]),
                trivial_share=sum(1 for s in placements if s['avail'] >= 3) / max(1, len(placements)),
                victim_late=pz.victim in R['order'][-2:], whatifs=whatifs,
                n_long=tech_counts.get('contra-long', 0), order=R['order'], steps=steps,
                intersection=R['intersection'],
                d0=sum(len(S.D0[j]) / ok for j in range(n - 1)) / (n - 1),
                givens=sum(len(S.D0[j]) == 1 for j in range(n - 1)))


def fun_score(P, whatif_penalty=True):
    """Deterministic 'designed aha' score (higher = more hand-made-like).
      +2    per aha episode in the middle of the solve (max 2)
      +0.5  per aha episode at the very start/end   (max 2)
      +0.25 per placement in the cascade after the best aha (max 4)
      +1    victim/murderer resolved among the last two placements
      +0.5  opening 'intersection' clue
      -0.15 per what-if elimination beyond 3 (grind), -1 per long bifurcation (max -4)
    Not solved by the step solver: -10."""
    if P['status'] != 'solved':
        return -10.0
    s = 2.0 * min(P['aha_mid'], 2) + 0.5 * min(P['n_aha'] - P['aha_mid'], 2)
    s += 0.25 * min(P['max_cascade'], 4)
    s += 1.0 if P['victim_late'] else 0.0
    s += 0.5 if P['intersection'] else 0.0
    if whatif_penalty:
        s -= 0.15 * max(0, P['whatifs'] - 3)
        s -= 1.0 * min(P['n_long'], 4)
    return round(max(s, -5.0), 2)


def mid_ahas(P, min_cascade=2):
    return [e for e in P['episodes'] if e['aha'] and 0.15 <= e['pos'] <= 0.8 and e['cascade'] >= min_cascade]
