#!/usr/bin/env python3
"""Murdoku for KOReader: offline case generator.

Default mode is "designed aha" (mgen/aha.py): clue sets are hill-climbed until
the step solver finds a mid-solve aha (cross-block, line-clash, subset, witness,
short what-if) followed by a cascade, with the victim placed last or second to
last. --classic uses the original pipeline (mgen/generate.py).

Examples (from the repo root):
  # one case, written as site v2 JSON (+ optional playtest sheets)
  python3 tools/generator/murdoku_gen.py --size 7 --difficulty medium --seed 42 --out /tmp/case.json

  # the curated "Originals" pack -> murdoku.koplugin/cases/ (+ playtest sheets)
  python3 tools/generator/murdoku_gen.py --pack --out-dir murdoku.koplugin/cases --playtest-dir /tmp/playtest

  # re-parse the clue TEXT of JSON files and confirm a unique solution equal to the stored one
  python3 tools/generator/murdoku_gen.py --check murdoku.koplugin/cases/orig-*.json

  # timing / success statistics
  python3 tools/generator/murdoku_gen.py --bench --sizes 6,7,9 --count 10
"""
import argparse
import json
import os
import sys
import time
from multiprocessing import Pool

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from mgen.generate import generate                       # noqa: E402
from mgen.aha import generate_aha                        # noqa: E402
from mgen.hints import make_hints                        # noqa: E402
from mgen.stephints import make_step_hints               # noqa: E402
from mgen.solver import own_domains                      # noqa: E402
from mgen.export import to_json, playtest_text, answer_text, slugify   # noqa: E402
from mgen.textparse import check_file                    # noqa: E402
from mgen.themes import THEMES                           # noqa: E402
from mgen.clues import WEAK                              # noqa: E402

RELEASE_AT = '2026-01-01T00:00:00.000Z'

# Pack layout: (difficulty, sizes, count)
PACK = [
    ('very-easy', (5, 6), 6),
    ('easy', (6, 7), 9),
    ('medium', (7, 8, 9), 9),
    ('hard', (8, 9), 6),
]


def finish(res):
    """Attach hints (from the solver trace) to a generator result."""
    pz = res.pz
    atoms = [a for lst in res.chosen for c in lst for a in c.atoms] + \
            [a for c in res.general for a in c.atoms] + res.vclue.atoms
    texts = [' '.join(c.text for c in lst) for lst in res.chosen] + [res.vclue.text]
    if getattr(res, 'aha', False):
        res.hints = make_step_hints(pz, res.profile, pz.murderer, texts, own_domains(pz, atoms))
    else:
        res.hints = make_hints(pz, atoms, res.logic, pz.murderer, texts)
    return res


def make(N, seed, diff, theme=None, time_limit=60, classic=False):
    if classic:
        return generate(N, seed, target=diff, theme=theme, time_limit=time_limit)
    return generate_aha(N, seed, target=diff, theme=theme, time_limit=time_limit)


def fun_score(res):
    """Cheap 'fun' heuristic used to choose between candidates for a pack slot."""
    kinds = [c.kind for lst in res.chosen for c in lst]
    n = res.pz.n - 1
    s = 0.0
    s -= 1.0 * max(0, len(kinds) - n)                 # extra sentences
    s -= 1.0 * sum(1 for lst in res.chosen for c in lst if c.positional)
    s -= 0.4 * sum(1 for k in kinds if k in ('noton', 'notroom', 'notwith'))
    s += 0.15 * len(set(kinds))                       # variety
    s += 0.6 if res.general else 0
    s += 0.4 if any(k in ('exists', 'existsg', 'onlygender') for k in kinds) else 0
    sizes = {}
    for a in res.pz.area:
        sizes[a] = sizes.get(a, 0) + 1
    return s


def _gen_slot(args):
    """Worker: generate several candidates for one pack slot, keep the best and write it.
    Classic mode ranks by fun_score(); aha mode by the aha objective (res.score).
    Returns a summary (results themselves hold lambdas and can't be pickled)."""
    diff, N, seed, theme, tries, title, out_dir, playtest_dir, classic = args
    best, made, t0 = None, 0, time.time()
    rank = fun_score if classic else (lambda r: r.score)
    for t in range(tries if classic else tries * 4):
        if made >= tries:
            break
        r = make(N, seed * 10 + t if classic else seed * 100 + t, diff, theme=theme, time_limit=240 if diff == 'hard' else 120, classic=classic)
        if r is None:
            continue
        made += 1
        r = finish(r)
        if best is None or rank(r) > rank(best):
            best = r
    if best is None:
        return None
    case_id = 'orig-' + slugify(title)
    write_case(best, case_id, title, out_dir=out_dir, playtest_dir=playtest_dir)
    P = getattr(best, 'profile', None)
    return dict(id=case_id, title=title, difficulty=diff, gridSize=f'{N}x{N}', theme=theme,
                trials=best.logic['trials'], sentences=sum(len(lst) for lst in best.chosen),
                general=len(best.general), seed=best.seed, candidates=made, secs=round(time.time() - t0),
                score=getattr(best, 'score', None), whatifs=P['whatifs'] if P else None,
                aha=[f"{e['aha_key']}@{e['placed']}/{N}" for e in P['episodes'] if e['aha']] if P else [])


def write_case(res, case_id, title, out_dir=None, out_file=None, playtest_dir=None):
    data = to_json(res, title, case_id)
    path = out_file or os.path.join(out_dir, case_id + '.json')
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=1, ensure_ascii=False, sort_keys=False)
        f.write('\n')
    if playtest_dir:
        os.makedirs(playtest_dir, exist_ok=True)
        with open(os.path.join(playtest_dir, case_id + '.txt'), 'w', encoding='utf-8') as f:
            f.write(playtest_text(res, case_id, title))
        with open(os.path.join(playtest_dir, case_id + '.answer.txt'), 'w', encoding='utf-8') as f:
            f.write(answer_text(res, case_id, title))
    return path


def cmd_pack(args):
    themes = sorted(THEMES)
    avoid = set()
    if args.avoid_titles:   # e.g. a previous pack's index.json: never reuse its ids
        avoid = {c['title'] for c in json.load(open(args.avoid_titles, encoding='utf-8'))['cases']}
    slots = []
    uses = {}
    k = 0
    os.makedirs(args.out_dir, exist_ok=True)
    for diff, sizes, count in PACK:
        for i in range(count):
            N = sizes[i % len(sizes)]
            theme = themes[(k * 5) % len(themes)]   # stride through themes for variety
            free = [t for t in THEMES[theme]['titles'][args.title_offset:] if t not in avoid]
            title = free[uses.get(theme, 0)]
            uses[theme] = uses.get(theme, 0) + 1
            tries = args.candidates or (2 if diff == 'hard' else 3)
            slots.append((diff, N, args.seed + k, theme, tries, title,
                          args.out_dir, args.playtest_dir, args.classic))
            k += 1
    t0 = time.time()
    with Pool(args.jobs) as pool:
        results = pool.map(_gen_slot, slots, chunksize=1)
    index = []
    for slot, res in zip(slots, results):
        if res is None:
            print(f'FAILED slot {slot[:4]}', file=sys.stderr)
            continue
        print(f"{res['id']:40s} {res['difficulty']:9s} {res['gridSize']} {res['theme']:12s} "
              f"trials={res['trials']:3d} sentences={res['sentences']} general={res['general']} "
              f"cands={res['candidates']} score={res['score']} whatifs={res['whatifs']} "
              f"aha={','.join(res['aha'])} {res['secs']}s", flush=True)
        index.append({key: res[key] for key in ('id', 'title', 'difficulty', 'gridSize', 'theme')}
                     | {'releaseAt': RELEASE_AT})
    with open(os.path.join(args.out_dir, 'index.json'), 'w', encoding='utf-8') as f:
        json.dump({'creator': 'Murdoku for KOReader', 'cases': index}, f, indent=1)
        f.write('\n')
    print(f'{len(index)} cases in {time.time() - t0:.0f}s')


def rebuild(path):
    """Rebuild a generator result from a case JSON (clue text re-matched to the
    generator's sentences), so hints and playtest sheets can be rewritten after a
    wording change without regenerating the case."""
    import random
    from mgen.textparse import load, TextParser, split_sentences
    from mgen.clues import Ctx, Clue, candidates, existential_candidates
    from mgen.solver import logic_solve, grade
    from mgen.steps import profile
    from mgen.aha import objective
    from mgen.generate import Result
    d = json.load(open(path, encoding='utf-8'))
    meta = d.get('META', {})
    pz, texts, general_texts, title = load(path)
    N = pz.W
    C = d['CHARACTERS']
    anchors = [[int(C[f'room_objects_{r}_{c}']) for c in range(N)] for r in range(pz.H)]
    g = Ctx(pz, anchors)
    tp = TextParser(pz)
    chosen = []
    for i in range(pz.n - 1):
        known = {c.text: c for c in candidates(g, i, random.Random(0)) + existential_candidates(g, i)}
        lst = []
        for sent in split_sentences(texts[i]):
            c = known.get(sent) or Clue('orroom' if ' or the ' in sent else 'text', tp.sentence(i, sent), sent, i)
            lst.append(c)
        chosen.append(lst)
    vatoms = [a for sent in split_sentences(texts[-1]) for a in tp.sentence(pz.victim, sent)]
    vclue = Clue('victim', vatoms, texts[-1], pz.victim)
    general = [Clue('general', tp.general(sent), sent, None) for t in general_texts for sent in split_sentences(t)]
    atoms = [a for lst in chosen for c in lst for a in c.atoms] + [a for c in general for a in c.atoms] + vatoms
    L = logic_solve(pz, atoms, want_events=True)
    gr = grade(L)
    P = profile(pz, atoms)
    res = Result(pz=pz, anchors=anchors, theme=meta.get('theme', ''), chosen=chosen, general=general, vclue=vclue,
                 logic=L, grade=gr, seed=meta.get('seed'), profile=P, score=round(objective(P, gr, gr), 2), aha=True)
    return finish(res), meta.get('id') or os.path.splitext(os.path.basename(path))[0], title


def cmd_rehint(args):
    for path in args.rehint:
        if os.path.basename(path) == 'index.json':
            continue
        res, case_id, title = rebuild(path)
        write_case(res, case_id, title, out_file=path, playtest_dir=args.playtest_dir)
        print(f'{path}: {len(res.hints)} hints, aha {[e["aha_key"] for e in res.profile["episodes"] if e["aha"]]}')
    return 0


def cmd_check(args):
    bad = 0
    for path in args.check:
        if os.path.basename(path) == 'index.json':
            continue
        t = time.time()
        ok, msg, info = check_file(path)
        bad += not ok
        extra = f"{info.get('size', '')} {info.get('grade', '')} trials={info.get('trials', '')}" if info else ''
        print(f'{"OK  " if ok else "FAIL"} {os.path.basename(path):45s} {msg} {extra} ({time.time() - t:.2f}s)')
    total = len([p for p in args.check if os.path.basename(p) != 'index.json'])
    print(f'{total - bad}/{total} files: text alone gives the unique stored solution')
    return 1 if bad else 0


def cmd_bench(args):
    import statistics
    for N in [int(s) for s in args.sizes.split(',')]:
        times, grades, fails, attempts = [], {}, 0, 0
        for s in range(args.count):
            t = time.time()
            r = make(N, 1000 * N + s, args.difficulty, time_limit=args.time_limit, classic=args.classic)
            times.append(time.time() - t)
            if not r:
                fails += 1
                continue
            attempts += r.attempts
            grades[r.grade] = grades.get(r.grade, 0) + 1
        ok = args.count - fails
        acc = ''
        if not args.classic:
            from mgen.aha import STATS
            acc = f", climbed scenes accepted {STATS['accepted']}/{STATS['climbed']}"
            STATS['accepted'] = STATS['climbed'] = 0
        print(f'{N}x{N} {args.difficulty}: ok {ok}/{args.count}, mean {statistics.mean(times):.2f}s, '
              f'max {max(times):.2f}s, scenes per case {attempts / max(1, ok):.1f}{acc}, grades {grades}', flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--size', type=int, default=7)
    ap.add_argument('--difficulty', default='any', choices=['any', 'very-easy', 'easy', 'medium', 'hard'])
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--theme', choices=sorted(THEMES))
    ap.add_argument('--title')
    ap.add_argument('--out', help='output JSON file (single case)')
    ap.add_argument('--pack', action='store_true', help='generate the curated Originals pack')
    ap.add_argument('--out-dir', default='murdoku.koplugin/cases')
    ap.add_argument('--playtest-dir', help='also write <id>.txt / <id>.answer.txt sheets here')
    ap.add_argument('--jobs', type=int, default=os.cpu_count() or 2)
    ap.add_argument('--check', nargs='+', metavar='JSON')
    ap.add_argument('--rehint', nargs='+', metavar='JSON',
                    help='rewrite hints (and playtest sheets with --playtest-dir) of existing case files')
    ap.add_argument('--bench', action='store_true')
    ap.add_argument('--sizes', default='6,7,9')
    ap.add_argument('--count', type=int, default=10)
    ap.add_argument('--time-limit', type=float, default=60)
    ap.add_argument('--classic', action='store_true', help='original pipeline (no aha filter / climb)')
    ap.add_argument('--candidates', type=int, help='pack: accepted candidates per slot (best one kept)')
    ap.add_argument('--avoid-titles', metavar='INDEX_JSON', help='pack: skip titles listed in this index.json')
    ap.add_argument('--title-offset', type=int, default=0, help='pack: first title index used per theme')
    args = ap.parse_args()
    if args.check:
        return cmd_check(args)
    if args.rehint:
        return cmd_rehint(args)
    if args.pack:
        return cmd_pack(args)
    if args.bench:
        return cmd_bench(args)
    t = time.time()
    res = make(args.size, args.seed, args.difficulty, theme=args.theme, time_limit=args.time_limit, classic=args.classic)
    if not res:
        print('no puzzle within the time limit', file=sys.stderr)
        return 1
    finish(res)
    title = args.title or THEMES[res.theme]['titles'][args.seed % len(THEMES[res.theme]['titles'])]
    case_id = 'orig-' + slugify(title)
    path = write_case(res, case_id, title, out_file=args.out or (case_id + '.json'), playtest_dir=args.playtest_dir)
    print(f'{path}: {res.grade} ({res.logic["trials"]} what-if steps), {res.theme}, {time.time() - t:.1f}s')
    return 0


if __name__ == '__main__':
    sys.exit(main())
