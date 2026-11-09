"""Export: the site's v2 puzzle JSON (loaded unchanged by murdoku_puzzle.lua),
and plain-text playtest / answer sheets."""
import re

from . import objects as O
from .solver import GRADES
from .themes import THEMES, ON_VERB

CREATOR = 'Murdoku for KOReader'
GEN_VERSION = '2'


def slugify(s):
    return re.sub(r'[^a-z0-9]+', '-', s.lower().replace("'", '')).strip('-')


def to_json(res, title, case_id=None):
    pz = res.pz
    N = pz.W
    P = {
        'puzzle_version': '2',
        'grid_w': str(N), 'grid_h': str(pz.H),
        'total_char': str(pz.n), 'total_chars': str(pz.n),
        'murderer': str(pz.murderer),
        'difficulty': str(GRADES.index(res.grade)),
    }
    for k, h in enumerate(res.hints, 1):
        P[f'player_hint_{k}_en'] = h
    C = {'title_en_': title, 'creator_': CREATOR}
    for r in range(pz.H):
        for c in range(N):
            i = r * N + c
            C[f'room_code_{r}_{c}'] = str(pz.area[i])
            C[f'room_objects_{r}_{c}'] = str(res.anchors[r][c])
            C[f'carpet_objects_{r}_{c}'] = str(O.CARPET_ID if pz.carpet[i] else 0)
    for a in pz.areas:
        C[f'room_name_{a}'] = pz.room_names[a]
    texts = clue_texts(res)
    for i in range(pz.n):
        C[f'char_name_{i}'] = pz.names[i]
        C[f'char_sex_{i}'] = '1' if pz.female[i] else '0'
        C[f'char_quote_en_{i}'] = texts[i]
        C[f'solution_x_{i}'] = str(pz.col[pz.sol[i]])
        C[f'solution_y_{i}'] = str(pz.row[pz.sol[i]])
    for k, g in enumerate(res.general):
        C[f'general_clue_{k}'] = g.text
    meta = {
        'id': case_id, 'theme': res.theme, 'grade': res.grade, 'trials': res.logic['trials'],
        'seed': res.seed, 'generator': GEN_VERSION,
    }
    P_ = getattr(res, 'profile', None)
    if P_ is not None:
        meta['aha'] = [dict(tech=e['aha_key'], placed=e['placed'], cascade=e['cascade'])
                       for e in P_['episodes'] if e['aha']]
        meta['aha_score'] = getattr(res, 'score', None)
    return {'PROPERTIES': P, 'CHARACTERS': C, 'META': meta}


def clue_texts(res):
    pz = res.pz
    out = [' '.join(c.text for c in lst) for lst in res.chosen]
    out.append(res.vclue.text)
    return out


# ---------------------------------------------------------------- playtest sheets
RULES = """HOW TO PLAY

THE GOAL
- Someone has been murdered. Work out where every person was standing, then
  you will know who did it.
- The murderer is the one person who was alone with the victim: the victim's
  area holds exactly two people, the victim and the murderer.

THE GRID
- Each row has exactly one person, and each column has exactly one person. So
  when you place someone, cross out the rest of their row and column.
- The map is split into areas (rooms, gardens, lakes...) by walls ("|" and
  "----" on the map above).
- An area can be empty, unless a general clue says otherwise ("There was no
  empty area.").

WHERE PEOPLE CAN STAND
- Squares marked OBSTACLE in the object list (tables, trees, shelves...):
  nobody can stand there.
- Everything else is fine: empty floor, carpets, and the objects marked CAN
  STAND (chairs, beds, cars, boats...).
- Big things (a car, a bed) cover two or more squares; all covered squares are
  listed. Standing on any one of them counts as being on it.

READING THE CLUES
- "in the Kitchen": on any square of the Kitchen. "in the Kitchen or the
  Hall": on a square of one of the two. "not in the Kitchen": anywhere else.
- "sitting in a chair" / "in a car" / "on a carpet": standing on a square of
  that object. "not sitting in a chair": not on any chair square.
- "beside the table": directly left, right, above or below a table square, AND
  in the same area as that square. Diagonals do not count, and a table on the
  other side of a wall does not count.
  Example: the table is at r3c3 in the Kitchen. r3c4 is beside it only if
  r3c4 is also in the Kitchen.
- "beside a tree and some flowers": beside both. "in the Kitchen, but not
  beside the table": in the Kitchen and not beside any table.
- "north of Bella": in any row above Bella's row, in any column and any area.
  South = any row below; west = any column to the left; east = any column to
  the right.
- "exactly one row north of Bella": in the row directly above Bella's row (any
  column). "exactly two columns east of Bella": two columns to the right.
- "in the top row" / "in the last column": that row or column of the map.
- "in a corner of her area": her square has a wall or the map edge on two
  sides that touch, such as top and left. Walls between areas count, not just
  the map edge.
- "alone": nobody else is in the same area. "alone in the Kitchen": in the
  Kitchen, and nobody else is there.
- "alone with Dan": exactly two people in the area, her and Dan. "alone with a
  man": exactly two people in the area, her and a man.
- "with Dan": Dan is in the same area (others may be too). "not with Dan": Dan
  is in a different area.
- "with a man" / "There was a man in her area": at least one OTHER person in
  her area is a man (the victim counts). "There was no other woman in her
  area": no woman other than her is in her area.
- "the only woman in the Library": she is in the Library and no other woman
  (the victim included) is; men may be.
- "the only person sitting in a chair" / "the only person beside the piano":
  she is, and nobody else, the victim included, is on any chair (beside the
  piano) anywhere.
- "Someone else in her area was sitting in a chair" / "in the same area as
  someone sitting in a chair": at least one OTHER person in her area (the
  victim counts) is on a chair.
- "exactly one row north of someone on a bed": some OTHER person, in the row
  directly below hers (any column, any area), is on a bed.
- General clues apply to everyone, the victim included. "There was exactly
  one person beside a tree", "No one was on a carpet", "No area contained
  exactly one person" mean just what they say.

TIPS
- Start with the clue that allows the fewest squares.
- Cross out every square someone can't be on; keep a short list of the two or
  three squares a person might still be on.
- If a guess leaves someone with nowhere to go, the guess was wrong.
- The victim's clue is always the same: they were alone with the murderer. It
  often settles the last step.
- Every case has exactly one solution and can be solved by logic alone."""


def _codes(pz):
    """Two-letter codes for each object name present."""
    names = sorted({O.name(o) for o in pz.obj if o})
    used, codes = set(), {}
    for nm in names:
        letters = re.sub(r'[^A-Za-z]', '', nm).upper()
        cand = [letters[:2], letters[0] + letters[-1]] + [letters[0] + ch for ch in letters[1:]] + \
               [letters[0] + d for d in '23456789']
        for c in cand:
            if len(c) == 2 and c not in used:
                used.add(c)
                codes[nm] = c
                break
    return codes


def render_map(pz, sol=None):
    """ASCII map with walls between areas. Each square: area letter + object code
    (2 chars) or '..' empty / '~~' carpet; with sol, the person letter replaces the code."""
    N, H = pz.W, pz.H
    letters = {a: chr(ord('a') + k) for k, a in enumerate(pz.areas)}
    codes = _codes(pz)
    who = {}
    if sol:
        for j, x in enumerate(sol):
            who[x] = 'V' if j == pz.victim else chr(65 + j)

    def tok(i):
        o = pz.obj[i]
        if i in who:
            return letters[pz.area[i]] + '*' + who[i]
        if o:
            return letters[pz.area[i]] + codes[O.name(o)]
        if pz.carpet[i]:
            return letters[pz.area[i]] + '~~'
        return letters[pz.area[i]] + '..'

    lines = ['      ' + ''.join(f'{c + 1:^5}' for c in range(N))]
    lines.append('     +' + '+'.join(['----'] * N) + '+')
    for r in range(H):
        row = f'  {r + 1:>2} |'
        for c in range(N):
            i = r * N + c
            right = '|' if c == N - 1 or pz.area[i] != pz.area[i + 1] else ' '
            row += f'{tok(i):<4}' + right
        lines.append(row)
        sep = '     +'
        for c in range(N):
            i = r * N + c
            wall = r == H - 1 or pz.area[i] != pz.area[i + N]
            sep += ('----' if wall else '    ') + '+'
        lines.append(sep)
    return lines, letters, codes


def _sq(pz, i):
    return f'r{pz.row[i] + 1}c{pz.col[i] + 1}'


def playtest_text(res, case_id, title):
    pz = res.pz
    lines = [f'CASE: {title}   (id: {case_id})',
             f'Map: {pz.H} rows x {pz.W} columns. {pz.n} people: {pz.n - 1} suspects '
             f'({chr(65)}-{chr(65 + pz.n - 2)}) and the victim (V).', '']
    grid, letters, codes = render_map(pz)
    lines.append('MAP  (rows numbered top to bottom, columns left to right; "|" and "----" are area walls)')
    lines.append('Each square = area letter + object code ("..": empty floor, "~~": carpet).')
    lines += grid
    lines += ['', 'AREAS']
    for a in pz.areas:
        sq = sorted(pz.area_cells[a])
        lines.append(f'  {letters[a]} = {pz.room_names[a]}: ' + ' '.join(_sq(pz, i) for i in sq))
    lines += ['', 'OBJECTS']
    lines.append('  ~~ = Carpet (CAN STAND): ' + (' '.join(_sq(pz, i) for i in range(pz.ncell) if pz.carpet[i]) or 'none'))
    by = {}
    for i in range(pz.ncell):
        if pz.obj[i]:
            by.setdefault(O.name(pz.obj[i]), []).append(i)
    for nm in sorted(by):
        stand = 'CAN STAND' if O.standable(pz.obj[by[nm][0]]) else 'OBSTACLE'
        multi = ''
        if any(pz.obj[i] in (O.RIGHT1 | O.RIGHT2 | O.DOWN1 | O.BIG2X2) for i in by[nm]):
            multi = '; each one covers 2 squares side by side, all covered squares are listed'
        lines.append(f'  {codes[nm]} = {nm} ({stand}{multi}): ' + ' '.join(_sq(pz, i) for i in by[nm]))
    lines += ['', 'SUSPECTS AND CLUES']
    texts = clue_texts(res)
    for j in range(pz.n):
        letter = 'V' if j == pz.victim else chr(65 + j)
        sex = 'woman' if pz.female[j] else 'man'
        lines.append(f'  {letter} {pz.names[j]} ({sex}{", the victim" if j == pz.victim else ""}): {texts[j]}')
    lines += ['', 'GENERAL CLUES']
    lines += [f'  * {g.text}' for g in res.general] or ['  (none)']
    lines += ['', RULES, '',
              'TASK: give the square (row, column) of every person, and name the murderer.']
    return '\n'.join(lines) + '\n'


def answer_text(res, case_id, title):
    pz = res.pz
    L = res.logic
    lines = [f'ANSWER: {title}   (id: {case_id})', '']
    grid, _, _ = render_map(pz, pz.sol)
    lines.append('Solution map ("*X" = person X):')
    lines += grid
    lines.append('')
    for j in range(pz.n):
        letter = 'V' if j == pz.victim else chr(65 + j)
        x = pz.sol[j]
        lines.append(f'  {letter} {pz.names[j]}: row {pz.row[x] + 1}, column {pz.col[x] + 1} '
                     f'({pz.room_names[pz.area[x]]})')
    lines += ['', f'Murderer: {chr(65 + pz.murderer)} {pz.names[pz.murderer]}', '',
              f'Grader: {res.grade}  (what-if eliminations: {L["trials"]}; very-easy 0, easy 1-3, medium 4-15, hard 16+)',
              f'Deduction order: ' + ' '.join('V' if j == pz.victim else chr(65 + j) for j in L['order']),
              f'Theme: {res.theme}  seed: {res.seed}',
              f'Clue kinds: ' + ', '.join(c.kind for lst in res.chosen for c in lst)
              + (' | general: ' + ', '.join(g.kind for g in res.general) if res.general else ''),
              '']
    P_ = getattr(res, 'profile', None)
    if P_ is not None:
        from .stephints import aha_summary, trace_lines
        techs = ', '.join(f'{k} {v}' for k, v in sorted(P_['techs'].items()))
        lines += [f'Step solver: {P_["whatifs"]} what-if(s), {P_["n_eps"]} bottleneck episode(s), '
                  f'aha score {getattr(res, "score", "?")}; d0 {P_["d0"]:.2f}, givens {P_["givens"]}',
                  f'Techniques used: {techs}',
                  'Aha moments:']
        lines += [f'  - {a}' for a in aha_summary(pz, P_)] or ['  (none)']
        lines += ['Step-solver trace (placements and bottlenecks):']
        lines += [f'  {t}' for t in trace_lines(pz, P_)]
        lines += ['']
    lines += ['Hints:']
    lines += [f'  {k}. {h}' for k, h in enumerate(res.hints, 1)]
    return '\n'.join(lines) + '\n'
