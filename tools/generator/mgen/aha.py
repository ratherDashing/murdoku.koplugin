"""'Designed aha' generation (the default mode).

Same scene + clue machinery as generate.py, plus:
  * existential clue templates ("in the same area as someone in a car",
    "exactly one row north of someone on a bed", "with a woman");
  * the step solver (steps.py) that names the technique of every step;
  * an ACCEPT filter: the solve has an aha episode (cross-block, line-clash,
    subset, witness, short what-if) between 15% and 80% of the placements,
    followed by a cascade of >= 2 easy placements; the victim is among the last
    two placed; at most 3 what-ifs and no long bifurcation (relaxed for 'hard',
    which needs many what-ifs by definition);
  * a hill-climb on the clue set: mutate one suspect's clue (replace / add /
    drop a sentence) -> repair to a unique, logic-solvable puzzle -> prune ->
    keep the change if the objective does not drop. Stops at the first accepted
    clue set.
Difficulty is still graded by solver.grade (what-if count of the old solver).
"""
import random
import time

from .model import Puzzle
from .solver import logic_solve, grade, own_domains, GRADES
from .layout import floor_plan, furnish, expanded, place_people, cast
from .clues import Ctx, candidates, existential_candidates, general_candidates, victim_clue
from .generate import PROFILES, Result, _pick, _atoms, _npos, _status, _kills, _harden
from .steps import profile, fun_score, mid_ahas
from .themes import THEMES

STATS = {'climbed': 0, 'accepted': 0}   # scene counters (for --bench)
MAX_WHATIFS = 3          # accept cap (easy/medium-feel puzzles)
SCORE_WHATIFS = 8        # step solver gives up beyond this while scoring (speed)


def scene(N, rng, theme=None):
    """Floor plan, furniture, a valid solution and a cast. (pz, anchors, theme) or None."""
    th = theme or rng.choice(sorted(THEMES))
    area = floor_plan(N, rng)
    nareas = len({a for row in area for a in row})
    if nareas > len(THEMES[th]['rooms']):
        return None
    anchors, carpet, rnames = furnish(N, area, th, rng)
    eobj = expanded(anchors, N)
    ps = place_people(N, area, eobj, rng)
    if not ps:
        return None
    solrc, murderer = ps
    names, female = cast(N, rng)
    sol = [r * N + c for r, c in solrc]
    pz = Puzzle(N, N, area, eobj, carpet, names, female, rnames, sol, murderer, title='')
    return pz, anchors, th


def repair(pz, rng, cands, chosen, general, vclue, prof, poscap, node_limit, deadline, rounds=60):
    """Add/replace sentences until the clue set is unique and logic-solvable,
    then drop second sentences that are not needed. Returns chosen or None."""
    N = pz.n
    sol = pz.sol
    chosen = [lst[:] for lst in chosen]
    for _ in range(rounds):
        if time.time() > deadline:
            return None
        solved, L, cnt, sols = _status(pz, chosen, general, vclue, node_limit)
        if solved:
            break
        if cnt in (-1, 0):
            return None
        alt = None
        if cnt == 1:
            amb = [j for j in range(N - 1) if L and len(L['D'][j]) > 1] or list(range(N - 1))
        else:
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
    else:
        return None
    for j in rng.sample(range(N - 1), N - 1):
        if len(chosen[j]) > 1:
            for k in range(len(chosen[j])):
                trial = [lst[:] for lst in chosen]
                del trial[j][k]
                if _status(pz, trial, general, vclue, node_limit)[0]:
                    chosen = trial
                    break
    return chosen


def evaluate(pz, chosen, general, vclue, target):
    atoms = _atoms(chosen, general, vclue)
    P = profile(pz, atoms, max_whatifs=None if target == 'hard' else SCORE_WHATIFS)
    L = logic_solve(pz, atoms, want_events=False)
    return P, grade(L), L


def accept(P, gr, target, max_whatifs=MAX_WHATIFS):
    if P['status'] != 'solved' or not P['victim_late']:
        return False
    if target != 'any' and gr != target:
        return False
    if target != 'hard' and (P['whatifs'] > max_whatifs or P['n_long'] > 0):
        return False
    return bool(mid_ahas(P))


def objective(P, gr, target):
    if P['status'] != 'solved':
        return -99.0
    hard = target == 'hard'
    sc = fun_score(P, whatif_penalty=not hard)
    sc += 10 * min(P['d0'], 0.35) - P['givens']          # weak, hand-made-style clues
    if not hard and P['whatifs'] > MAX_WHATIFS:
        sc -= 2 + 0.3 * P['whatifs']
    if any(e['aha_key'] != 'contra-short' for e in mid_ahas(P)):
        sc += 1.0                                       # a named idea beats a quick what-if
    if target != 'any' and gr in GRADES:
        sc -= 3 * abs(GRADES.index(gr) - GRADES.index(target))
    return sc


def climb(pz, rng, cands, chosen, general, vclue, target, prof, poscap, node_limit, deadline, iters):
    P, gr, L = evaluate(pz, chosen, general, vclue, target)
    best = objective(P, gr, target)
    it = 0
    for it in range(1, iters + 1):
        if accept(P, gr, target) or time.time() > deadline:
            break
        trial = [lst[:] for lst in chosen]
        j = rng.randrange(pz.n - 1)
        op = rng.random()
        if op < 0.6:                                   # replace
            trial[j] = [rng.choice(cands[j])]
        elif op < 0.85 and len(trial[j]) < 2:         # add
            trial[j] = trial[j] + [rng.choice(cands[j])]
        elif len(trial[j]) > 1:                        # drop
            del trial[j][rng.randrange(len(trial[j]))]
        else:
            continue
        if _npos(trial) > poscap:
            continue
        trial = repair(pz, rng, cands, trial, general, vclue, prof, poscap, node_limit, deadline)
        if not trial:
            continue
        Q, g2, L2 = evaluate(pz, trial, general, vclue, target)
        v = objective(Q, g2, target)
        if v >= best:                                  # plateau moves allowed
            chosen, P, gr, best = trial, Q, g2, v
    return chosen, P, gr, best, it


def generate_aha(N, seed, target='any', theme=None, time_limit=60.0, iters=60, attempts=40,
                 node_limit=300_000, verbose=False):
    """One accepted puzzle (Result) or None. Deterministic in seed (up to the time limit)."""
    rng = random.Random(seed)
    t0 = time.time()
    deadline = t0 + time_limit
    prof = PROFILES[target]
    poscap = 1 if N <= 6 else 2
    for attempt in range(1, attempts + 1):
        if time.time() > deadline:
            return None
        sc = scene(N, rng, theme)
        if not sc:
            continue
        pz, anchors, th = sc
        g = Ctx(pz, anchors)
        vclue = victim_clue(pz)
        cands = [candidates(g, i, rng) + existential_candidates(g, i) for i in range(N - 1)]
        gens = general_candidates(g)
        chosen = [[] for _ in range(N - 1)]
        general = []
        if rng.random() < prof[2]:                     # key clue: alone pins its owner
            keys = [c for i in range(N - 1) for c in cands[i]
                    if c.kind in ('beside2', 'onroom', 'besideroom', 'notbeside', 'onlygender', 'onlyon', 'onlybeside')
                    and len(own_domains(pz, c.atoms)[i]) == 1]
            if keys:
                k = rng.choice(keys)
                chosen[k.who] = [k]
        if rng.random() < prof[3] and gens:
            general = [rng.choice(gens)]
        for i in range(N - 1):
            if not chosen[i]:
                chosen[i] = [_pick(rng, [c for c in cands[i] if not c.positional], prof) or _pick(rng, cands[i], prof)]
        chosen = repair(pz, rng, cands, chosen, general, vclue, prof, poscap, node_limit, deadline)
        if not chosen:
            continue
        if target != 'any':
            L = logic_solve(pz, _atoms(chosen, general, vclue), want_events=False)
            if GRADES.index(grade(L)) < GRADES.index(target):
                chosen, L = _harden(pz, rng, cands, chosen, general, vclue, target, prof, poscap, node_limit,
                                    t0, time_limit)
        STATS['climbed'] += 1
        chosen, P, gr, score, used = climb(pz, rng, cands, chosen, general, vclue, target, prof, poscap,
                                           node_limit, deadline, iters)
        if verbose:
            print(f'  attempt {attempt}: grade {gr} whatifs {P["whatifs"]} aha {P["aha_keys"]} '
                  f'victim_late {P["victim_late"]} score {score:.2f} iters {used}')
        if not accept(P, gr, target) or _npos(chosen) > poscap:
            continue
        STATS['accepted'] += 1
        L = logic_solve(pz, _atoms(chosen, general, vclue), want_events=True)
        return Result(pz=pz, anchors=anchors, theme=th, chosen=chosen, general=general, vclue=vclue,
                      logic=L, grade=gr, attempts=attempt, time=time.time() - t0, seed=seed,
                      profile=P, score=round(score, 2), aha=True)
    return None
