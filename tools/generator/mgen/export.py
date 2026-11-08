"""Export: the site's v2 puzzle JSON (loaded unchanged by murdoku_puzzle.lua),
and plain-text playtest / answer sheets."""
import re

from . import objects as O
from .solver import GRADES
from .themes import THEMES, ON_VERB

CREATOR = 'Murdoku for KOReader'
GEN_VERSION = '1'


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
    return {'PROPERTIES': P, 'CHARACTERS': C, 'META': meta}


def clue_texts(res):
    pz = res.pz
    out = [' '.join(c.text for c in lst) for lst in res.chosen]
    out.append(res.vclue.text)
    return out


# ---------------------------------------------------------------- playtest sheets
RULES = """RULES
1. Every person (all suspects and the victim) stands on exactly one square.
   There is exactly one person in each row and exactly one person in each column.
2. Nobody can stand on an obstacle square (marked OBSTACLE in the legend).
   People CAN stand on empty floor, on carpets and on the objects marked
   CAN STAND (chairs, beds, cars, boats...). Standing on any square of a
   multi-square object (a car or bed covers 2 squares) counts as being on it.
3. "in the <Area>" means standing on one of that area's squares.
4. "beside X" means directly left, right, above or below a square holding X,
   AND in the same area as that square. Diagonals do not count.
5. "north of" = in a higher row (smaller row number), any column, any area.
   "south of" = larger row number, "west of" = smaller column number,
   "east of" = larger column number. "exactly two rows north of B" means
   B's row number minus 2.
6. "alone" = no other person in the same area. "alone with X" = exactly one
   other person in the area, and it is X. "with X" = X is in the same area
   (others may be too). "not with X" = X is in a different area.
7. "There was no other man in his area" = no man other than him in his area.
   "There was a woman in his area" = at least one woman other than him there.
   "the only woman in the Library" = she is in the Library and no other
   woman is (men may be). "Someone else in her area was ..." = at least one
   other person in her area matches.
8. "the only person sitting in a chair" = nobody else (victim included) is on
   any chair square. General clues apply to everyone, victim included.
9. "in a corner of her area" = her square has a wall or the edge of the map on
   two sides that meet (e.g. top and left).
10. The victim (V) was alone with exactly one other person in an area: that
   person is the murderer. Every case has exactly one solution and can be
   solved by logic alone."""


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
              '', 'Hints:']
    lines += [f'  {k}. {h}' for k, h in enumerate(res.hints, 1)]
    return '\n'.join(lines) + '\n'
