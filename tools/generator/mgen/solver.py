"""Solution counter, human-style logical solver with a reasoned trace, and grader.

Difficulty = number of eliminations that needed a one-level "what if"
(contradiction) test: very-easy 0, easy 1-3, medium 4-15, hard 16+.
"""
from .model import In, Only


def all_atoms(clues):
    """clues: list of lists of atoms (any grouping). Flattened list."""
    return [at for group in clues for at in group]


def own_domains(pz, atoms):
    """Domains from each person's own unary atoms only."""
    D = [set(pz.ok) for _ in range(pz.n)]
    for at in atoms:
        if isinstance(at, In):
            D[at.who] &= at.allowed(pz)
    return D


def base_domains(pz, atoms, events=None):
    D = own_domains(pz, atoms)
    for at in atoms:
        if isinstance(at, Only):
            hit = []
            for j in at.victims(pz):
                if D[j] & at.cells:
                    D[j] -= at.cells
                    hit.append(j)
            if events is not None and hit:
                events.append(('clue', at, tuple(hit)))
    return D


def dynamic_atoms(atoms):
    return [at for at in atoms if not isinstance(at, (In, Only))]


def count_solutions(pz, atoms, limit=2, node_limit=2_000_000):
    """Backtracking count. Returns (count, solutions, nodes, timed_out)."""
    D = base_domains(pz, atoms)
    dyn = dynamic_atoms(atoms)
    by_person = [[] for _ in range(pz.n)]
    for at in dyn:
        for j in set(at.involves(pz)):
            by_person[j].append(at)
    sols, asg = [], {}
    used_r, used_c = set(), set()
    nodes = [0]
    stop = [False]
    row, col = pz.row, pz.col

    def rec():
        if stop[0]:
            return
        nodes[0] += 1
        if nodes[0] > node_limit:
            stop[0] = True
            return
        if len(asg) == pz.n:
            if all(at.check(pz, asg, True) for at in dyn):
                sols.append(tuple(asg[i] for i in range(pz.n)))
                if len(sols) >= limit:
                    stop[0] = True
            return
        best, bestc = None, None
        for j in range(pz.n):
            if j in asg:
                continue
            cand = [x for x in D[j] if row[x] not in used_r and col[x] not in used_c]
            if best is None or len(cand) < len(bestc):
                best, bestc = j, cand
                if not cand:
                    return
        for x in sorted(bestc):
            asg[best] = x
            used_r.add(row[x])
            used_c.add(col[x])
            if all(at.check(pz, asg, False) for at in by_person[best]):
                rec()
            used_r.discard(row[x])
            used_c.discard(col[x])
            del asg[best]
            if stop[0]:
                return

    rec()
    return len(sols), sols, nodes[0], nodes[0] > node_limit


class Contradiction(Exception):
    """why: ('empty', j) | ('row', r) | ('col', c) | ('clue', atom)"""

    def __init__(self, why):
        super().__init__(why)
        self.why = why


def propagate(pz, D, dyn, events=None, placed=None):
    """Apply no-guessing techniques to a fixpoint. Mutates D; raises Contradiction.
    events (if a list) receives:
      ('place', j, x)              j has one square left
      ('hidden', j, axis, line)    only j can still fill that row/col
      ('pair', axis, lines, js, hit)  two people share two lines; others leave them
      ('clue', atom, hit)          an atom removed squares from people in `hit`
    """
    n = pz.n
    if placed is None:
        placed = set()
    row, col = pz.row, pz.col
    changed = True
    while changed:
        changed = False
        for j in range(n):
            if not D[j]:
                raise Contradiction(('empty', j))
            if len(D[j]) == 1 and j not in placed:
                placed.add(j)
                (x,) = tuple(D[j])
                for k in range(n):
                    if k != j:
                        rm = {y for y in D[k] if row[y] == row[x] or col[y] == col[x]}
                        if rm:
                            D[k] -= rm
                            changed = True
                if events is not None:
                    events.append(('place', j, x))
        if changed:
            continue
        asg = {j: next(iter(D[j])) for j in range(n) if len(D[j]) == 1}
        for at in dyn:
            if not at.check(pz, asg, len(asg) == n):
                raise Contradiction(('clue', at))
        if pz.exact:
            for axis, size, lineof in ((0, pz.H, row), (1, pz.W, col)):
                for line in range(size):
                    who = [j for j in range(n) if any(lineof[y] == line for y in D[j])]
                    if not who:
                        raise Contradiction(('row' if axis == 0 else 'col', line))
                    if len(who) == 1:
                        j = who[0]
                        rm = {y for y in D[j] if lineof[y] != line}
                        if rm:
                            D[j] -= rm
                            changed = True
                            if events is not None:
                                events.append(('hidden', j, axis, line))
                if changed:
                    break
            if changed:
                continue
            for axis, lineof in ((0, row), (1, col)):
                groups = {}
                for j in range(n):
                    if len(D[j]) > 1:
                        ls = frozenset(lineof[y] for y in D[j])
                        if len(ls) == 2:
                            groups.setdefault(ls, []).append(j)
                for ls, js in groups.items():
                    if len(js) == 2:
                        hit = []
                        for k in range(n):
                            if k not in js:
                                rm = {y for y in D[k] if lineof[y] in ls}
                                if rm:
                                    D[k] -= rm
                                    hit.append(k)
                        if hit:
                            changed = True
                            if events is not None:
                                events.append(('pair', axis, tuple(sorted(ls)), tuple(js), tuple(hit)))
                if changed:
                    break
            if changed:
                continue
        for at in dyn:
            rm = at.prune(pz, D)
            hit = set()
            for j, x in rm:
                if x in D[j]:
                    D[j].discard(x)
                    hit.add(j)
            if hit:
                changed = True
                if events is not None:
                    events.append(('clue', at, tuple(sorted(hit))))
                break
    if all(len(d) == 1 for d in D):
        asg = {j: next(iter(D[j])) for j in range(n)}
        for at in dyn:
            if not at.check(pz, asg, True):
                raise Contradiction(('clue', at))


def logic_solve(pz, atoms, max_rounds=400, want_events=True):
    """Returns dict(solved, trials, events, order, D)."""
    events = [] if want_events else None
    D = base_domains(pz, atoms, events)
    dyn = dynamic_atoms(atoms)
    placed = set()
    trials = 0
    try:
        propagate(pz, D, dyn, events, placed)
    except Contradiction:
        return dict(solved=False, trials=0, events=events or [], order=[], D=D)
    rounds = 0
    while not all(len(d) == 1 for d in D) and rounds < max_rounds:
        rounds += 1
        progress = False
        for j in sorted(range(pz.n), key=lambda k: (len(D[k]), k)):
            if len(D[j]) == 1:
                continue
            for x in sorted(D[j]):
                T = [set(d) for d in D]
                T[j] = {x}
                try:
                    propagate(pz, T, dyn, None, set(placed))
                except Contradiction as e:
                    D[j].discard(x)
                    trials += 1
                    if events is not None:
                        events.append(('trial', j, x, e.why))
                    progress = True
                    break
            if progress:
                break
        if not progress:
            break
        try:
            propagate(pz, D, dyn, events, placed)
        except Contradiction:
            return dict(solved=False, trials=trials, events=events or [], order=[], D=D)
    solved = all(len(d) == 1 for d in D)
    order = [e[1] for e in (events or []) if e[0] == 'place']
    return dict(solved=solved, trials=trials, events=events or [], order=order, D=D)


GRADES = ['very-easy', 'easy', 'medium', 'hard']


def grade(res):
    if not res['solved']:
        return 'needs-guessing'
    t = res['trials']
    if t == 0:
        return 'very-easy'
    if t <= 3:
        return 'easy'
    if t <= 15:
        return 'medium'
    return 'hard'
