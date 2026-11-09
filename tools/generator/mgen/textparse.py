"""Independent check: load a puzzle JSON the way the plugin does, parse the
English clue TEXT back into atoms (without using the generator's atoms), and
confirm the text alone has exactly one solution, equal to the stored one.

Only the sentence templates our generator writes are understood; anything else
is reported as unparsed (so wording bugs are caught, not ignored)."""
import json
import re

from . import objects as O
from .model import Puzzle, In, Only, AreaCount, Rel, Exists, Count, NoEmptyArea, NoLoner
from .solver import count_solutions, logic_solve, grade
from .themes import ON_VERB

NUMW = {'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6, 'seven': 7, 'eight': 8}
ORDW = {'first': 0, 'second': 1, 'third': 2, 'fourth': 3, 'fifth': 4, 'sixth': 5, 'seventh': 6, 'eighth': 7,
        'ninth': 8}


class Unparsed(Exception):
    pass


def _num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def load(path):
    """Mirror of murdoku_puzzle.lua for v2 files. Returns (Puzzle, texts, general, title)."""
    d = json.load(open(path, encoding='utf-8'))
    flat = {}
    for s in ('CHARACTERS', 'GRID', 'OBJECT', 'PROPERTIES'):
        for k, v in d.get(s, {}).items():
            flat.setdefault(k, v)
    P = d['PROPERTIES']
    W, H = int(_num(P['grid_w'])), int(_num(P['grid_h']))
    assert (_num(P.get('puzzle_version')) or 0) >= 2, 'only v2 files are checked'
    g = lambda nm: [[int(_num(flat.get(f'{nm}_{r}_{c}', 0)) or 0) for c in range(W)] for r in range(H)]
    area, objs, carp = g('room_code'), g('room_objects'), g('carpet_objects')
    O.expand_footprints(objs, H, W)
    n = 0
    while str(flat.get(f'char_name_{n}', '')).strip():
        n += 1
    tc = _num(P.get('total_char'))
    if tc and 0 < tc < n:
        n = int(tc)
    names = [str(flat[f'char_name_{i}']).strip() for i in range(n)]
    female = [int(_num(flat.get(f'char_sex_{i}')) or 0) == 1 for i in range(n)]
    rn = {a: str(flat.get(f'room_name_{a}', '') or f'Area {a}').strip() for a in {x for row in area for x in row}}
    sol = [int(_num(flat[f'solution_y_{i}'])) * W + int(_num(flat[f'solution_x_{i}'])) for i in range(n)]
    pz = Puzzle(H, W, area, objs, carp, names, female, rn, sol, int(_num(P['murderer'])))
    texts = [re.sub(r'\s+', ' ', str(flat.get(f'char_quote_en_{i}', ''))).strip() for i in range(n)]
    general = []
    for k in range(0, 21):
        for f in (f'clue_custom_text{k}', f'general_clue_{k}'):
            t = str(flat.get(f, '') or '').strip()
            if t and t not in general:
                general.append(t)
    return pz, texts, general, str(flat.get('title_en_', '')).strip()


class TextParser:
    def __init__(self, pz):
        self.pz = pz
        self.person_idx = {nm.lower(): i for i, nm in enumerate(pz.names)}
        self.room_idx = {nm.lower(): a for a, nm in pz.room_names.items()}
        if len(self.room_idx) != len(pz.room_names):
            raise Unparsed('duplicate room names')
        self.obj_names = {nm.lower() for nm, occ in O.OBJECTS.values() if occ is not None} | {'carpet'}

    def person(self, s):
        if s.lower() not in self.person_idx:
            raise Unparsed('unknown person ' + s)
        return self.person_idx[s.lower()]

    def room(self, s):
        if s.lower() not in self.room_idx:
            raise Unparsed('unknown area ' + s)
        return self.room_idx[s.lower()]

    def noun(self, phrase):
        """'a chair' / 'the piano' / 'some flowers' / 'the water' -> object word present in the scene."""
        m = re.fullmatch(r'(?:a|an|the|some) (.+)', phrase)
        if not m:
            raise Unparsed('object phrase ' + phrase)
        w = m.group(1).lower()
        if w not in self.obj_names:
            raise Unparsed('unknown object ' + w)
        if not self.pz.obj_cells(w):
            raise Unparsed('object not in scene ' + w)
        return w

    def where(self, phrase):
        """'sitting in a chair' / 'on a carpet' / 'beside the piano' -> cell set."""
        m = re.fullmatch(r'beside (.+)', phrase)
        if m:
            w = self.noun(m.group(1))
            return self.pz.beside_set(w)
        m = re.fullmatch(r'(sitting in|standing in|on|in) (.+)', phrase)
        if m:
            w = self.noun(m.group(2))
            if ON_VERB.get(w) != m.group(1):
                raise Unparsed(f'verb "{m.group(1)}" does not suit {w}')
            return self.pz.on_set(w)
        raise Unparsed('place phrase ' + phrase)

    def sentence(self, i, s):
        pz = self.pz
        s = s.strip()
        if not s.endswith('.'):
            raise Unparsed('no full stop: ' + s)
        s = s[:-1]
        if i == pz.victim:
            if s == 'The Victim':
                return []
            if re.fullmatch(r'(He|She) was alone with the murderer', s):
                return [AreaCount(i, 'alonewith', None)]
            raise Unparsed('victim sentence ' + s)
        his = 'her' if pz.female[i] else 'his'
        He = 'She' if pz.female[i] else 'He'
        m = re.fullmatch(rf'There was no (other )?(man|woman) in {his} area', s)
        if m:
            fem = m.group(2) == 'woman'
            if bool(m.group(1)) != (fem == pz.female[i]):
                raise Unparsed('"other" misuse: ' + s)
            return [AreaCount(i, 'none', ('female', fem))]
        m = re.fullmatch(rf'There was (a|another) (man|woman) in {his} area', s)
        if m:
            return [AreaCount(i, 'with', ('female', m.group(2) == 'woman'))]
        m = re.fullmatch(rf'Someone else in {his} area was (.+)', s)
        if m:
            return [Exists(i, 'samearea', cells=self.where(m.group(1)))]
        m = re.fullmatch(rf'{He} was (.+)', s)
        if not m:
            raise Unparsed('sentence ' + s)
        return self.body(i, m.group(1))

    def body(self, i, b):
        pz = self.pz
        m = re.fullmatch(r'in the same area as someone (?:else )?(.+)', b)
        if m:
            return [Exists(i, 'samearea', cells=self.where(m.group(1)))]
        m = re.fullmatch(r'exactly one row (north|south) of someone (.+)', b)
        if m:
            return [Exists(i, 'rows', cells=self.where(m.group(2)), k=-1 if m.group(1) == 'north' else 1)]
        m = re.fullmatch(r'with a (man|woman)', b)
        if m:
            return [AreaCount(i, 'with', ('female', m.group(1) == 'woman'))]
        m = re.fullmatch(r'the only person (.+)', b)
        if m:
            cells = self.where(m.group(1))
            return [In(i, cells), Only(i, cells)]
        m = re.fullmatch(r'the only (man|woman) in the (.+)', b)
        if m:
            fem = m.group(1) == 'woman'
            if fem != pz.female[i]:
                raise Unparsed('gender mismatch ' + b)
            cells = pz.area_set([self.room(m.group(2))])
            return [In(i, cells), Only(i, cells, exempt=[j for j in range(pz.n) if pz.female[j] != fem])]
        if b == 'alone':
            return [AreaCount(i, 'alone')]
        m = re.fullmatch(r'alone in the (.+)', b)
        if m:
            return [In(i, pz.area_set([self.room(m.group(1))])), AreaCount(i, 'alone')]
        m = re.fullmatch(r'alone with a (man|woman)', b)
        if m:
            return [AreaCount(i, 'alonewith', ('female', m.group(1) == 'woman'))]
        m = re.fullmatch(r'alone with (\w+)', b)
        if m:
            return [AreaCount(i, 'alonewith', ('person', self.person(m.group(1))))]
        m = re.fullmatch(r'(not )?with (\w+)', b)
        if m:
            return [AreaCount(i, 'none' if m.group(1) else 'with', ('person', self.person(m.group(2))))]
        m = re.fullmatch(r'in the (.+) or the (.+)', b)
        if m:
            return [In(i, pz.area_set([self.room(m.group(1)), self.room(m.group(2))]))]
        m = re.fullmatch(r'not in the (.+)', b)
        if m:
            return [In(i, pz.area_set([self.room(m.group(1))]), neg=True)]
        m = re.fullmatch(r'in the (.+), but not (beside .+)', b)
        if m:
            return [In(i, pz.area_set([self.room(m.group(1))])), In(i, self.where(m.group(2)), neg=True)]
        m = re.fullmatch(r'in the (top|bottom|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth) row', b)
        if m:
            r = {'top': 0, 'bottom': pz.H - 1}.get(m.group(1), ORDW.get(m.group(1)))
            if m.group(1) in ('first', ) or r in (0, pz.H - 1) and m.group(1) not in ('top', 'bottom'):
                raise Unparsed('use top/bottom row: ' + b)
            return [In(i, pz.row_set(r), positional=True)]
        m = re.fullmatch(r'in the (first|last|second|third|fourth|fifth|sixth|seventh|eighth) column', b)
        if m:
            c = {'first': 0, 'last': pz.W - 1}.get(m.group(1), ORDW.get(m.group(1)))
            if c == pz.W - 1 and m.group(1) != 'last':
                raise Unparsed('use last column: ' + b)
            return [In(i, pz.col_set(c), positional=True)]
        if re.fullmatch(r'in a corner of (his|her) area', b):
            return [In(i, pz.corner_set())]
        m = re.fullmatch(r'(north|south|east|west) of (\w+)', b)
        if m:
            return [Rel(i, self.person(m.group(2)), m.group(1))]
        m = re.fullmatch(r'exactly (\w+) (rows?|columns?) (north|south|east|west) of (\w+)', b)
        if m:
            k = NUMW.get(m.group(1))
            if k is None or (k == 1) != (not m.group(2).endswith('s')):
                raise Unparsed('count ' + b)
            d = m.group(3)
            if m.group(2).startswith('row') and d in ('north', 'south'):
                return [Rel(i, self.person(m.group(4)), 'rows', -k if d == 'north' else k)]
            if m.group(2).startswith('column') and d in ('east', 'west'):
                return [Rel(i, self.person(m.group(4)), 'cols', -k if d == 'west' else k)]
            raise Unparsed('direction ' + b)
        m = re.fullmatch(r'beside (.+?) and (.+)', b)
        if m:
            return [In(i, self.where('beside ' + m.group(1))), In(i, self.where('beside ' + m.group(2)))]
        m = re.fullmatch(r'(.+) in the (.+)', b)
        if m and m.group(2).lower() in self.room_idx:
            return [In(i, self.where(m.group(1))), In(i, pz.area_set([self.room(m.group(2))]))]
        m = re.fullmatch(r'not (.+)', b)
        if m:
            return [In(i, self.where(m.group(1)), neg=True)]
        m = re.fullmatch(r'in the (.+)', b)
        if m and m.group(1).lower() in self.room_idx:
            return [In(i, pz.area_set([self.room(m.group(1))]))]
        return [In(i, self.where(b))]

    def general(self, s):
        s = s.strip()
        if not s.endswith('.'):
            raise Unparsed('no full stop: ' + s)
        s = s[:-1]
        if s == 'There was no empty area':
            return [NoEmptyArea()]
        if s == 'No area contained exactly one person':
            return [NoLoner()]
        m = re.fullmatch(r'No one was (.+)', s)
        if m:
            return [Count(self.where(m.group(1)), 0, 0)]
        m = re.fullmatch(r'There was exactly one person (.+)', s)
        if m:
            return [Count(self.where(m.group(1)), 1, 1)]
        m = re.fullmatch(r'There were exactly (two|three) people (.+)', s)
        if m:
            k = NUMW[m.group(1)]
            return [Count(self.where(m.group(2)), k, k)]
        raise Unparsed('general ' + s)


def split_sentences(text):
    return [x for x in re.split(r'(?<=\.)\s+', text.strip()) if x]


def check_file(path):
    """Returns (ok, message, info dict)."""
    pz, texts, general, title = load(path)
    tp = TextParser(pz)
    atoms = []
    try:
        for i, t in enumerate(texts):
            for s in split_sentences(t):
                atoms += tp.sentence(i, s)
        for t in general:
            for s in split_sentences(t):
                atoms += tp.general(s)
    except Unparsed as e:
        return False, f'unparsed: {e}', {}
    cnt, sols, nodes, timed_out = count_solutions(pz, atoms, limit=2, node_limit=5_000_000)
    if timed_out:
        return False, 'solution count timed out', {}
    if cnt != 1:
        return False, f'{cnt} solutions', {}
    if list(sols[0]) != pz.sol:
        return False, 'unique solution differs from the stored one', {}
    v = pz.victim
    with_v = [j for j in range(pz.n) if j != v and pz.area[pz.sol[j]] == pz.area[pz.sol[v]]]
    if with_v != [pz.murderer]:
        return False, 'stored murderer is not the person alone with the victim', {}
    L = logic_solve(pz, atoms, want_events=True)
    info = dict(title=title, size=f'{pz.W}x{pz.H}', grade=grade(L), trials=L['trials'],
                victim_late=v in L['order'][-2:])
    if not L['solved']:
        return False, 'not solvable without guessing', info
    return True, 'unique, matches stored solution', info
