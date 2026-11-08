#!/usr/bin/env python3
"""Murdoku for KOReader: offline case generator.

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
from mgen.hints import make_hints                        # noqa: E402
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
    res.hints = make_hints(pz, atoms, res.logic, pz.murderer, texts)
    return res


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
    """Worker: generate the best of a few candidates for one pack slot and write it.
    Returns a summary (results themselves hold lambdas and can't be pickled)."""
    diff, N, seed, theme, tries, title, out_dir, playtest_dir = args
    best = None
    for t in range(tries):
        r = generate(N, seed * 10 + t, target=diff, theme=theme, time_limit=240)
        if r is None:
            continue
        r = finish(r)
        if best is None or fun_score(r) > fun_score(best):
            best = r
    if best is None:
        return None
    case_id = 'orig-' + slugify(title)
    write_case(best, case_id, title, out_dir=out_dir, playtest_dir=playtest_dir)
    return dict(id=case_id, title=title, difficulty=diff, gridSize=f'{N}x{N}', theme=theme,
                trials=best.logic['trials'], sentences=sum(len(lst) for lst in best.chosen),
                general=len(best.general), seed=best.seed)


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
    slots = []
    uses = {}
    k = 0
    os.makedirs(args.out_dir, exist_ok=True)
    for diff, sizes, count in PACK:
        for i in range(count):
            N = sizes[i % len(sizes)]
            theme = themes[(k * 5) % len(themes)]   # stride through themes for variety
            title = THEMES[theme]['titles'][uses.get(theme, 0)]
            uses[theme] = uses.get(theme, 0) + 1
            slots.append((diff, N, args.seed + k, theme, 2 if diff == 'hard' else 3, title,
                          args.out_dir, args.playtest_dir))
            k += 1
    t0 = time.time()
    with Pool(args.jobs) as pool:
        results = pool.map(_gen_slot, slots)
    index = []
    for slot, res in zip(slots, results):
        if res is None:
            print(f'FAILED slot {slot[:4]}', file=sys.stderr)
            continue
        print(f"{res['id']:40s} {res['difficulty']:9s} {res['gridSize']} {res['theme']:12s} "
              f"trials={res['trials']:3d} sentences={res['sentences']} general={res['general']}")
        index.append({key: res[key] for key in ('id', 'title', 'difficulty', 'gridSize', 'theme')}
                     | {'releaseAt': RELEASE_AT})
    with open(os.path.join(args.out_dir, 'index.json'), 'w', encoding='utf-8') as f:
        json.dump({'creator': 'Murdoku for KOReader', 'cases': index}, f, indent=1)
        f.write('\n')
    print(f'{len(index)} cases in {time.time() - t0:.0f}s')


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
        times, grades, fails = [], {}, 0
        for s in range(args.count):
            t = time.time()
            r = generate(N, 1000 * N + s, target=args.difficulty, time_limit=args.time_limit)
            times.append(time.time() - t)
            if not r:
                fails += 1
                continue
            grades[r.grade] = grades.get(r.grade, 0) + 1
        print(f'{N}x{N} {args.difficulty}: ok {args.count - fails}/{args.count}, mean {statistics.mean(times):.2f}s, '
              f'max {max(times):.2f}s, grades {grades}', flush=True)


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
    ap.add_argument('--bench', action='store_true')
    ap.add_argument('--sizes', default='6,7,9')
    ap.add_argument('--count', type=int, default=10)
    ap.add_argument('--time-limit', type=float, default=60)
    args = ap.parse_args()
    if args.check:
        return cmd_check(args)
    if args.pack:
        return cmd_pack(args)
    if args.bench:
        return cmd_bench(args)
    t = time.time()
    res = generate(args.size, args.seed, target=args.difficulty, theme=args.theme, time_limit=args.time_limit)
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
