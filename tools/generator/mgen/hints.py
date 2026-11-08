"""Readable step-by-step player hints from the logical solver's trace.

One hint per placement, in the order the solver places people, e.g.
  "Only one square fits Dana's clue ("She was beside a tree and some flowers."),
   so Dana (D) must be at row 3, column 4. Cross out her row and column."
"""
from .model import In, Only, AreaCount
from .solver import own_domains


def _where(pz, x):
    return f'row {pz.row[x] + 1}, column {pz.col[x] + 1}'


def _label(pz, j):
    if j == pz.victim:
        return f'{pz.names[j]} (the victim)'
    return f'{pz.names[j]} ({chr(65 + j)})'


def _owner_clue(pz, atom):
    src = getattr(atom, 'src', None)
    if src is None:
        return 'a clue'
    if src.who is None:
        return f'the general clue ("{src.text}")'
    if src.who == pz.victim:
        return 'the victim\'s clue (alone with the murderer)'
    return f'{pz.names[src.who]}\'s clue ("{src.text}")'


def _why(pz, why):
    kind = why[0]
    if kind == 'empty':
        return f'{pz.names[why[1]]} would have nowhere left to go'
    if kind == 'row':
        return f'nobody could stand in row {why[1] + 1}'
    if kind == 'col':
        return f'nobody could stand in column {why[1] + 1}'
    if kind == 'clue':
        return f'{_owner_clue(pz, why[1])} could not be true'
    return 'that leads to a contradiction'


def make_hints(pz, atoms, logic, murderer, texts):
    """texts[j]: person j's full clue text."""
    events = logic['events']
    own = own_domains(pz, atoms)
    hints = []
    seg = []
    placed_before = []
    for e in events:
        if e[0] != 'place':
            seg.append(e)
            continue
        j, x = e[1], e[2]
        He, him, his = pz.pron(j)
        name = pz.names[j]
        parts = []
        trials = [t for t in seg if t[0] == 'trial']
        hidden = [t for t in seg if t[0] == 'hidden' and t[1] == j]
        clues = [t for t in seg if t[0] == 'clue' and j in t[2]]
        pairs = [t for t in seg if t[0] == 'pair' and j in t[4]]
        clue_text = texts[j] if j != pz.victim else None
        if not seg and len(own[j]) == 1 and not placed_before:
            parts.append(f'Only one square fits {name}\'s clue ("{clue_text}")' if clue_text
                         else f'Only one square fits {name}\'s clue')
        elif not seg and len(own[j]) == 1:
            parts.append(f'{name}\'s clue ("{clue_text}") fits only one square' if clue_text
                         else f'{name}\'s clue fits only one square')
        else:
            groups = {}
            for t in trials:
                groups.setdefault((t[1], _why(pz, t[3])), []).append(t[2])
            ordered = sorted(groups.items(), key=lambda kv: kv[0][0] != j)  # the placed person first
            for (k, why), squares in ordered[:2]:
                sq = [_where(pz, y) for y in squares]
                if len(sq) == 1:
                    parts.append(f'Suppose {pz.names[k]} were at {sq[0]}: then {why}. So {pz.names[k]} can\'t be there')
                else:
                    shown = sq[:3] + (['...'] if len(sq) > 3 else [])
                    parts.append(f'{pz.names[k]} can\'t be at {"; ".join(shown)}: in each case {why}')
            if len(groups) > 2:
                parts.append('Testing the remaining squares the same way rules out a few more')
            if trials and all(t[1] != j for t in trials):
                parts.append(f'That leaves only one possible square for {name}'
                             + (f' that fits {his} clue ("{clue_text}")' if clue_text else ''))
            for t in pairs[:1]:
                axis = 'rows' if t[1] == 0 else 'columns'
                a, b = t[3]
                l1, l2 = t[2]
                parts.append(f'{pz.names[a]} and {pz.names[b]} can only use {axis} {l1 + 1} and {l2 + 1}, '
                             f'so nobody else can be in those {axis}')
            seen = set()
            for t in clues:
                desc = _owner_clue(pz, t[1])
                if desc in seen:
                    continue
                seen.add(desc)
                at = t[1]
                if isinstance(at, Only):
                    parts.append(f'Because of {desc}, nobody else can be on those squares')
                elif isinstance(at, AreaCount) and at.who == pz.victim:
                    parts.append('The victim must share an area with exactly one other person')
                else:
                    parts.append(f'Using {desc}, some squares are ruled out for {name}' if at.who != j
                                 else f'{name}\'s own clue ("{clue_text}") rules out more squares')
                if len(seen) >= 2:
                    break
            for t in hidden[:1]:
                axis, line = t[2], t[3]
                what = f'row {line + 1}' if axis == 0 else f'column {line + 1}'
                parts.append(f'{name} is now the only person who can still go in {what}')
            if not parts:
                if placed_before:
                    who = _list(pz, placed_before) if len(placed_before) <= 2 else 'everyone placed so far'
                    parts.append(f'With the rows and columns of {who} crossed out, '
                                 f'only one square is left for {name}'
                                 + (f' that fits {his} clue ("{clue_text}")' if clue_text else ''))
                else:
                    parts.append(f'Only one square fits {name}\'s clue' + (f' ("{clue_text}")' if clue_text else ''))
        text = '. '.join(parts) + f'. So {_label(pz, j)} must be at {_where(pz, x)}. Cross out {his} row and column.'
        hints.append(text)
        placed_before.append(j)
        seg = []
    if hints and murderer is not None:
        v = pz.victim
        hints[-1] += (f' {pz.names[murderer]} is the only person in the {pz.room_names[pz.area[pz.sol[v]]]} '
                      f'with {pz.names[v]}, so {pz.names[murderer]} is the murderer!')
    return hints


def _list(pz, js):
    names = [pz.names[j] for j in js]
    if len(names) == 1:
        return names[0]
    return ', '.join(names[:-1]) + ' and ' + names[-1]
