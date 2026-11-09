"""True clue sentences for a known solution. Each candidate is a Clue: English
text plus the atoms it means. textparse.py is the independent inverse."""
from .model import In, Only, AreaCount, Rel, Exists, Count, NoEmptyArea, NoLoner
from .themes import ON_VERB, MASS, NOUN, obj_word

ORD = ['first', 'second', 'third', 'fourth', 'fifth', 'sixth', 'seventh', 'eighth', 'ninth']
NUM = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight']
POSITIONAL = {'row', 'col', 'compass', 'offset'}
STRONG = {'on', 'onroom', 'onlyon', 'beside2', 'besideroom', 'onlybeside', 'onlygender', 'alonewith'}
WEAK = {'orroom', 'notroom', 'noton', 'notbeside', 'notwith', 'nogender', 'existsg', 'compass', 'with', 'exists',
        'samearea', 'withg'}
KIND_W = {
    'area': 3, 'orroom': 1.5, 'notroom': 1, 'on': 4, 'onroom': 2, 'noton': 0.8, 'onlyon': 2.5,
    'beside': 4, 'beside2': 2, 'besideroom': 1.5, 'notbeside': 1.5, 'onlybeside': 1.5,
    'alone': 2, 'aloneroom': 1.5, 'alonewith': 1.5, 'alonewithg': 1.5, 'with': 1.5, 'notwith': 0.7,
    'nogender': 1, 'onlygender': 1.2, 'exists': 1.5, 'existsg': 1, 'corner': 1,
    'row': 0.6, 'col': 0.6, 'compass': 0.5, 'offset': 0.4,
    'samearea': 1.2, 'rowof': 0.8, 'withg': 1.0,
}


class Clue:
    def __init__(self, kind, atoms, text, who):
        self.kind, self.atoms, self.text, self.who = kind, atoms, text, who
        for a in atoms:
            a.src = self
        self.positional = kind in POSITIONAL

    def __repr__(self):
        return f'<{self.kind}: {self.text}>'


class Ctx:
    """Puzzle + solution + English helpers."""

    def __init__(self, pz, anchors):
        self.pz = pz
        self.sol = pz.sol
        self.count = {}       # object word -> number of objects (multi-cell counted once)
        N = pz.W
        for r in range(pz.H):
            for c in range(N):
                w = obj_word(anchors[r][c])
                if w:
                    self.count[w] = self.count.get(w, 0) + 1
        self.words = sorted(self.count)
        if any(pz.carpet):
            self.words.append('carpet')

    def noun(self, w):
        return NOUN.get(w, w)

    def art(self, w, only=False):
        """'the piano' / 'a chair' / 'some flowers'. only=True: for 'the only person beside a ...'."""
        n = self.noun(w)
        if w in MASS:
            return 'some ' + n
        if w == 'water':
            return 'the water'
        if w != 'carpet' and self.count.get(w, 0) == 1 and not only:
            return 'the ' + n
        return ('an ' if n[0].lower() in 'aeiou' else 'a ') + n

    def on_phrase(self, w):
        return f'{ON_VERB[w]} {self.art(w)}'

    def word_at(self, x):
        """Standable object word under cell x (or 'carpet'), else None."""
        pz = self.pz
        w = obj_word(pz.obj[x])
        if w in ON_VERB:
            return w
        if pz.carpet[x]:
            return 'carpet'
        return None

    def beside_words(self, x):
        pz = self.pz
        out = set()
        for y in pz.nbrs[x]:
            w = obj_word(pz.obj[y])
            if w and w not in ON_VERB and pz.area[y] == pz.area[x]:
                out.add(w)
        return sorted(out)

    def room(self, a):
        return self.pz.room_names[a]


def _desc(atom, desc):
    """Words for the unknown companion of a 'someone' clue (used by the hints)."""
    atom.desc = desc
    return atom


def _true_for_others(pz, sol, i, cells):
    return any(sol[j] in cells for j in range(pz.n) if j != i)


def candidates(g, i, rng):
    """All true sentences for suspect i."""
    pz, sol = g.pz, g.sol
    x = sol[i]
    a = pz.area[x]
    He, him, his = pz.pron(i)
    room = g.room(a)
    occ = [j for j in range(pz.n) if j != i and pz.area[sol[j]] == a]
    out = []

    def add(kind, atoms, text):
        out.append(Clue(kind, atoms, text, i))

    area_cells = pz.area_set([a])
    add('area', [In(i, area_cells)], f'{He} was in the {room}.')
    for b in pz.areas:
        if b == a:
            continue
        r1, r2 = sorted([room, g.room(b)], key=lambda _: rng.random())
        add('orroom', [In(i, pz.area_set([a, b]))], f'{He} was in the {r1} or the {r2}.')
        add('notroom', [In(i, pz.area_set([b]), neg=True)], f'{He} was not in the {g.room(b)}.')

    w = g.word_at(x)
    if w:
        cells = pz.on_set(w)
        add('on', [In(i, cells)], f'{He} was {g.on_phrase(w)}.')
        add('onroom', [In(i, cells), In(i, area_cells)], f'{He} was {g.on_phrase(w)} in the {room}.')
        if not _true_for_others(pz, sol, i, cells):
            add('onlyon', [In(i, cells), Only(i, cells)],
                f'{He} was the only person {ON_VERB[w]} {g.art(w, only=True)}.')
    for w2 in g.words:
        if w2 in ON_VERB and w2 != w and x not in pz.on_set(w2):
            add('noton', [In(i, pz.on_set(w2), neg=True)], f'{He} was not {ON_VERB[w2]} {g.art(w2, only=True)}.')

    near = g.beside_words(x)
    for w2 in near:
        cells = pz.beside_set(w2)
        add('beside', [In(i, cells)], f'{He} was beside {g.art(w2)}.')
        add('besideroom', [In(i, cells), In(i, area_cells)], f'{He} was beside {g.art(w2)} in the {room}.')
        if not _true_for_others(pz, sol, i, cells):
            add('onlybeside', [In(i, cells), Only(i, cells)], f'{He} was the only person beside {g.art(w2, only=True)}.')
    for k1 in range(len(near)):
        for k2 in range(k1 + 1, len(near)):
            w1, w2 = near[k1], near[k2]
            add('beside2', [In(i, pz.beside_set(w1)), In(i, pz.beside_set(w2))],
                f'{He} was beside {g.art(w1)} and {g.art(w2)}.')
    in_room = sorted({obj_word(pz.obj[y]) for y in pz.area_cells[a]} - {None} - set(ON_VERB) - set(near))
    for w2 in in_room:
        add('notbeside', [In(i, area_cells), In(i, pz.beside_set(w2), neg=True)],
            f'{He} was in the {room}, but not beside {g.art(w2)}.')

    if not occ:
        add('alone', [AreaCount(i, 'alone')], f'{He} was alone.')
        add('aloneroom', [In(i, area_cells), AreaCount(i, 'alone')], f'{He} was alone in the {room}.')
    elif len(occ) == 1 and occ[0] != pz.victim:
        j = occ[0]
        add('alonewith', [AreaCount(i, 'alonewith', ('person', j))], f'{He} was alone with {pz.names[j]}.')
        add('alonewithg', [AreaCount(i, 'alonewith', ('female', pz.female[j]))],
            f'{He} was alone with a {"woman" if pz.female[j] else "man"}.')
    for j in occ:
        if j != pz.victim:
            add('with', [AreaCount(i, 'with', ('person', j))], f'{He} was with {pz.names[j]}.')
    for j in range(pz.n - 1):
        if j != i and j not in occ:
            add('notwith', [AreaCount(i, 'none', ('person', j))], f'{He} was not with {pz.names[j]}.')
    for fem, word in ((False, 'man'), (True, 'woman')):
        has = [j for j in occ if pz.female[j] == fem]
        other = 'other ' if fem == pz.female[i] else ''
        if occ and not has:
            add('nogender', [AreaCount(i, 'none', ('female', fem))], f'There was no {other}{word} in {his} area.')
        if has and pz.victim not in has:
            art = 'another' if fem == pz.female[i] else 'a'
            add('existsg', [AreaCount(i, 'with', ('female', fem))], f'There was {art} {word} in {his} area.')
        if fem == pz.female[i] and not has and any(j != i and pz.female[j] == fem for j in range(pz.n)):
            add('onlygender', [In(i, area_cells), Only(i, area_cells, exempt=[j for j in range(pz.n) if pz.female[j] != fem])],
                f'{He} was the only {word} in the {room}.')
    for j in occ:
        y = sol[j]
        w2 = g.word_at(y)
        if w2:
            phrase = f'{ON_VERB[w2]} {g.art(w2, only=True)}'
            add('exists', [_desc(Exists(i, 'samearea', cells=pz.on_set(w2)), f'the person {phrase} in {pz.names[i]}\'s area')],
                f'Someone else in {his} area was {phrase}.')
        for w3 in g.beside_words(y):
            phrase = f'beside {g.art(w3, only=True)}'
            add('exists', [_desc(Exists(i, 'samearea', cells=pz.beside_set(w3)), f'the person {phrase} in {pz.names[i]}\'s area')],
                f'Someone else in {his} area was {phrase}.')

    N = pz.H
    r, c = pz.row[x], pz.col[x]
    rw = {0: 'top row', N - 1: 'bottom row'}.get(r, f'{ORD[r]} row')
    cw = {0: 'first column', N - 1: 'last column'}.get(c, f'{ORD[c]} column')
    add('row', [In(i, pz.row_set(r), positional=True)], f'{He} was in the {rw}.')
    add('col', [In(i, pz.col_set(c), positional=True)], f'{He} was in the {cw}.')
    if x in pz.corner_set():
        add('corner', [In(i, pz.corner_set())], f'{He} was in a corner of {his} area.')

    for j in range(pz.n):
        if j == i:
            continue
        y = sol[j]
        nm = pz.names[j]
        ns = 'north' if pz.row[x] < pz.row[y] else 'south'
        ew = 'west' if pz.col[x] < pz.col[y] else 'east'
        add('compass', [Rel(i, j, ns)], f'{He} was {ns} of {nm}.')
        add('compass', [Rel(i, j, ew)], f'{He} was {ew} of {nm}.')
        dr = pz.row[x] - pz.row[y]
        if abs(dr) <= 3:
            k = abs(dr)
            add('offset', [Rel(i, j, 'rows', dr)], f'{He} was exactly {NUM[k]} row{"s" if k > 1 else ""} {ns} of {nm}.')
        dc = pz.col[x] - pz.col[y]
        if abs(dc) <= 2:
            k = abs(dc)
            add('offset', [Rel(i, j, 'cols', dc)], f'{He} was exactly {NUM[k]} column{"s" if k > 1 else ""} {ew} of {nm}.')
    return out


def existential_candidates(g, i):
    """'Someone ...' sentences for suspect i (aha mode). They create the
    "who can be the person in the car?" deductions hand-made puzzles use:
      samearea  He was in the same area as someone sitting in a chair.
      rowof     He was exactly one row north of someone on a bed.
      withg     He was with a woman.
    Each atom gets a `desc` naming the unknown companion, used by the hints."""
    pz, sol = g.pz, g.sol
    x = sol[i]
    He, him, his = pz.pron(i)
    a = pz.area[x]
    occ = [j for j in range(pz.n) if j != i and pz.area[sol[j]] == a]
    out = []
    name = pz.names[i]
    for w in g.words:
        if w not in ON_VERB:
            continue
        cells = pz.on_set(w)
        if not cells or (w == 'carpet' and x in cells):
            continue
        phrase = f'{ON_VERB[w]} {g.art(w, only=True)}'
        if any(sol[j] in cells for j in occ):
            at = Exists(i, 'samearea', cells=cells)
            at.desc = f'the person {phrase} in {name}\'s area'
            out.append(Clue('samearea', [at], f'{He} was in the same area as someone {phrase}.', i))
        for k, word in ((-1, 'north'), (1, 'south')):
            if any(pz.row[x] - pz.row[sol[j]] == k and sol[j] in cells for j in range(pz.n) if j != i):
                at = Exists(i, 'rows', cells=cells, k=k)
                at.desc = f'the person {phrase} one row {"south" if k < 0 else "north"} of {name}'
                out.append(Clue('rowof', [at], f'{He} was exactly one row {word} of someone {phrase}.', i))
    for fem, word in ((False, 'man'), (True, 'woman')):
        if any(pz.female[j] == fem for j in occ if j != pz.victim):
            at = AreaCount(i, 'with', ('female', fem))
            at.desc = f'the {word} in {name}\'s area'
            out.append(Clue('withg', [at], f'{He} was with a {word}.', i))
    return out


def general_candidates(g):
    """True puzzle-wide clues."""
    pz, sol = g.pz, g.sol
    out = []
    for w in g.words:
        if w in ON_VERB:
            cells, phrase = pz.on_set(w), ON_VERB[w] + ' ' + g.art(w, only=True)
        else:
            cells, phrase = pz.beside_set(w), 'beside ' + g.art(w, only=True)
        if not cells:
            continue
        k = sum(1 for x in sol if x in cells)
        if k == 0:
            out.append(Clue('g-none', [Count(cells, 0, 0)], f'No one was {phrase}.', None))
        elif k == 1:
            out.append(Clue('g-one', [Count(cells, 1, 1)], f'There was exactly one person {phrase}.', None))
        elif k == 2:
            out.append(Clue('g-two', [Count(cells, 2, 2)], f'There were exactly two people {phrase}.', None))
    cnt = {}
    for x in sol:
        cnt[pz.area[x]] = cnt.get(pz.area[x], 0) + 1
    if len(cnt) == len(pz.areas):
        out.append(Clue('g-noempty', [NoEmptyArea()], 'There was no empty area.', None))
    if all(k != 1 for k in cnt.values()):
        out.append(Clue('g-noloner', [NoLoner()], 'No area contained exactly one person.', None))
    return out


def victim_clue(pz):
    He = pz.pron(pz.victim)[0]
    return Clue('victim', [AreaCount(pz.victim, 'alonewith', None)], f'The Victim. {He} was alone with the murderer.', pz.victim)
