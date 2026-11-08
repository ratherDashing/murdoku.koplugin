"""Generation pipeline.

1. Themed floor plan (rectangles + L-shaped rooms) and furniture.
2. A random valid solution; the victim shares an area with exactly one suspect.
3. Optional "key clue" first: one suspect gets a clue that pins them to a single
   square through an intersection (e.g. beside a tree AND flowers), giving the
   solver an entry point; optional general clue.
4. One sentence per suspect, weighted by the difficulty profile; add sentences
   until the solution is unique and the logical solver finishes without guessing.
5. Prune redundant sentences, then harden (swap in weaker sentences) until the
   graded difficulty reaches the target.
6. Filters: few positional clues, victim among the last 2 people deduced.
"""
import random
import time

from .model import Puzzle, In, Rel
from .solver import count_solutions, logic_solve, grade, own_domains, GRADES
from .layout import floor_plan, furnish, expanded, place_people, cast
from .clues import Ctx, candidates, general_candidates, victim_clue, KIND_W, STRONG, WEAK, POSITIONAL
from .themes import THEMES

PROFILES = {
    #             strong, weak, key-clue prob, general prob
    'very-easy': (2.0, 0.4, 0.7, 0.2),
    'easy': (1.3, 0.8, 0.6, 0.35),
    'medium': (0.7, 1.6, 0.5, 0.4),
    'hard': (0.35, 2.5, 0.3, 0.4),
    'any': (1.0, 1.0, 0.5, 0.35),
}


class Result:
    def __init__(self, **kw):
        self.__dict__.update(kw)


def _weight(c, prof):
    w = KIND_W[c.kind]
    if c.kind in STRONG:
        w *= prof[0]
    elif c.kind in WEAK:
        w *= prof[1]
    return w


def _pick(rng, lst, prof):
    if not lst:
        return None
    tot = sum(_weight(c, prof) for c in lst)
    r = rng.random() * tot
    for c in lst:
        r -= _weight(c, prof)
        if r <= 0:
            return c
    return lst[-1]


def _atoms(chosen, general, vclue):
    out = []
    for lst in chosen:
        for c in lst:
            out += c.atoms
    for c in general:
        out += c.atoms
    return out + vclue.atoms


def _npos(chosen):
    return sum(1 for lst in chosen for c in lst if c.positional)


def _status(pz, chosen, general, vclue, node_limit):
    """(unique and logic-solvable, logic result or None, count, solutions)"""
    atoms = _atoms(chosen, general, vclue)
    cnt, sols, _, timed_out = count_solutions(pz, atoms, limit=2, node_limit=node_limit)
    if timed_out or cnt != 1:
        return False, None, cnt if not timed_out else -1, sols
    L = logic_solve(pz, atoms, want_events=False)
    return L['solved'], L, cnt, sols


def _kills(pz, c, alt, j):
    for at in c.atoms:
        if isinstance(at, In) and alt[j] not in at.allowed(pz):
            return True
        if isinstance(at, Rel) and not at.fn(pz, alt[at.who], alt[at.other]):
            return True
    return False


def generate(N, seed, target='any', theme=None, time_limit=30.0, key_first=None, use_general=None,
             poscap=None, node_limit=300_000, verbose=False):
    rng = random.Random(seed)
    t0 = time.time()
    prof = PROFILES[target]
    if poscap is None:
        poscap = 1 if N <= 6 else 2
    themes = sorted(THEMES)
    for attempt in range(1, 500):
        if time.time() - t0 > time_limit:
            return None
        th = theme or rng.choice(themes)
        area = floor_plan(N, rng)
        nareas = len({a for row in area for a in row})
        if nareas > len(THEMES[th]['rooms']):
            continue
        anchors, carpet, rnames = furnish(N, area, th, rng)
        eobj = expanded(anchors, N)
        ps = place_people(N, area, eobj, rng)
        if not ps:
            continue
        solrc, murderer = ps
        names, female = cast(N, rng)
        sol = [r * N + c for r, c in solrc]
        pz = Puzzle(N, N, area, eobj, carpet, names, female, rnames, sol, murderer, title='')
        g = Ctx(pz, anchors)
        vclue = victim_clue(pz)
        cands = [candidates(g, i, rng) for i in range(N - 1)]
        gens = general_candidates(g)
        chosen = [[] for _ in range(N - 1)]
        general = []

        # key clue first: a clue that alone pins its owner to one square
        kf = (rng.random() < prof[2]) if key_first is None else key_first
        if kf:
            keys = []
            for i in range(N - 1):
                for c in cands[i]:
                    if c.kind in ('beside2', 'onroom', 'besideroom', 'notbeside', 'onlygender', 'onlyon', 'onlybeside') \
                            and len(own_domains(pz, c.atoms)[i]) == 1:
                        keys.append(c)
            if keys:
                k = rng.choice(keys)
                chosen[k.who] = [k]
        ug = (rng.random() < prof[3]) if use_general is None else use_general
        if ug and gens:
            general = [rng.choice(gens)]
        for i in range(N - 1):
            if not chosen[i]:
                chosen[i] = [_pick(rng, [c for c in cands[i] if not c.positional], prof) or _pick(rng, cands[i], prof)]

        ok = False
        for _ in range(60):
            if time.time() - t0 > time_limit:
                return None
            solved, L, cnt, sols = _status(pz, chosen, general, vclue, node_limit)
            if solved:
                ok = True
                break
            if cnt == -1:
                break
            alt = None
            if cnt == 1:
                amb = [j for j in range(N - 1) if L and len(L['D'][j]) > 1]
                if not amb:
                    amb = list(range(N - 1))
            else:
                if cnt == 0:  # cannot happen with true clues
                    break
                alt = [s for s in sols if s != tuple(sol)][0]
                amb = [j for j in range(N - 1) if alt[j] != sol[j]] or list(range(N - 1))
            rng.shuffle(amb)
            added = False
            for j in amb:
                if len(chosen[j]) >= 2:
                    continue
                have = {c.text for c in chosen[j]}
                opts = [c for c in cands[j] if c.text not in have]
                if alt is not None:
                    opts = [c for c in opts if _kills(pz, c, alt, j)] or opts
                if _npos(chosen) >= poscap:
                    opts = [c for c in opts if not c.positional]
                c = _pick(rng, opts, prof)
                if c:
                    chosen[j].append(c)
                    added = True
                    break
            if not added:
                j = amb[0]
                opts = [c for c in cands[j] if not c.positional or _npos(chosen) < poscap]
                chosen[j] = [_pick(rng, opts, prof)]
        if not ok:
            continue

        # prune: drop second sentences and the general clue when not needed
        for j in rng.sample(range(N - 1), N - 1):
            if len(chosen[j]) > 1:
                for k in range(len(chosen[j])):
                    trial = [lst[:] for lst in chosen]
                    del trial[j][k]
                    if _status(pz, trial, general, vclue, node_limit)[0]:
                        chosen = trial
                        break
        if general and _status(pz, chosen, [], vclue, node_limit)[0]:
            general = []
        # collapse two-sentence clues into one sentence where possible
        for j in range(N - 1):
            if len(chosen[j]) < 2:
                continue
            singles = [c for c in cands[j] if not (c.positional and _npos(chosen) >= poscap)]
            rng.shuffle(singles)
            for c in singles[:10]:
                trial = [lst[:] for lst in chosen]
                trial[j] = [c]
                if _status(pz, trial, general, vclue, node_limit)[0]:
                    chosen = trial
                    break

        L = logic_solve(pz, _atoms(chosen, general, vclue), want_events=False)
        gr = grade(L)
        if target != 'any' and GRADES.index(gr) < GRADES.index(target):
            chosen, L = _harden(pz, rng, cands, chosen, general, vclue, target, prof, poscap, node_limit, t0, time_limit)
            gr = grade(L)
        if target != 'any' and gr != target:
            if verbose:
                print(f'  attempt {attempt}: graded {gr}, want {target}')
            continue
        if _npos(chosen) > poscap:
            continue
        L = logic_solve(pz, _atoms(chosen, general, vclue), want_events=True)
        if pz.victim not in L['order'][-2:]:
            if verbose:
                print(f'  attempt {attempt}: victim deduced too early')
            continue
        return Result(pz=pz, anchors=anchors, theme=th, chosen=chosen, general=general, vclue=vclue,
                      logic=L, grade=grade(L), attempts=attempt, time=time.time() - t0, seed=seed)
    return None


def _harden(pz, rng, cands, chosen, general, vclue, target, prof, poscap, node_limit, t0, time_limit):
    """Swap sentences for weaker ones while the puzzle stays fair, until the grade
    reaches the target. Returns (chosen, logic result)."""
    goal = GRADES.index(target)
    L = logic_solve(pz, _atoms(chosen, general, vclue), want_events=False)
    best_trials = L['trials']
    for _round in range(3):
        order = list(range(pz.n - 1))
        rng.shuffle(order)
        improved = False
        for j in order:
            if time.time() - t0 > time_limit:
                return chosen, L
            have = {c.text for c in chosen[j]}
            opts = [c for c in cands[j] if c.text not in have and not (c.positional and _npos(chosen) >= poscap)]
            # weak sentences first
            opts.sort(key=lambda c: -(_weight(c, prof) * rng.random() * (2.0 if c.kind in WEAK else 1.0)))
            for c in opts[:8]:
                trial = [lst[:] for lst in chosen]
                trial[j] = [c]
                ok, L2, _, _ = _status(pz, trial, general, vclue, node_limit)
                if not ok or L2['trials'] < best_trials:
                    continue
                if GRADES.index(grade(L2)) > goal:
                    continue  # overshoot
                if L2['trials'] > best_trials or rng.random() < 0.3:
                    chosen, L, best_trials = trial, L2, L2['trials']
                    improved = True
                    if GRADES.index(grade(L)) == goal:
                        return chosen, L
                    break
        if not improved:
            break
    return chosen, L
