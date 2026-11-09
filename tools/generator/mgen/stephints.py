"""Player hints from the STEP solver's trace (aha mode): one hint per placement,
naming the idea that unlocks it, e.g.
  "Who can be the person in a car in Ada's area? Only Boris: nobody else can
   still reach a square that fits. ... So Boris (B) must be at row 2, column 5."
Also a short technique summary ('aha moments') for answer sheets."""
from .model import Only, AreaCount, Rel, Exists
from .hints import _where, _label, _owner_clue, _list


def _nm(pz, j):
    return pz.names[j]


def _why(pz, why):
    k = why[0]
    if k == 'empty':
        return f'{_nm(pz, why[1])} would have nowhere left to go'
    if k == 'row':
        return f'nobody could stand in row {why[1] + 1}'
    if k == 'col':
        return f'nobody could stand in column {why[1] + 1}'
    if k == 'share':
        return f'{_nm(pz, why[1])} and {_nm(pz, why[2])} would have to share a row or column'
    if k == 'clue':
        return f'{_owner_clue(pz, why[1])} could not be true'
    return 'that leads to a contradiction'


def _desc(pz, at):
    """Words for the unknown companion of a 'someone' clue."""
    d = getattr(at, 'desc', None)
    if d:
        return d
    owner = _nm(pz, at.who)
    if isinstance(at, AreaCount):
        if at.who == pz.victim:
            return f'the murderer (the one person alone with {owner})'
        if at.cond and at.cond[0] == 'female':
            return f'the {"woman" if at.cond[1] else "man"} in {owner}\'s area'
        return f'the other person in {owner}\'s area'
    src = getattr(at, 'src', None)
    return f'the "someone" in {owner}\'s clue' + (f' ("{src.text}")' if src else '')


def _lines(axis, lines):
    word = 'rows' if axis == 0 else 'columns'
    nums = [str(l + 1) for l in lines]
    return f'{word} {", ".join(nums[:-1])} and {nums[-1]}'


def step_text(pz, s):
    """One sentence for an advanced (level >= 2) step."""
    t, info = s['tech'], s['info']
    hit = sorted({j for j, _ in s['rm']})
    if t == 'cross-block':
        x, j = info[1], info[2]
        He = pz.pron(j)[0].lower()
        return (f'Look at {_nm(pz, j)}: every square {He} could still use shares a row or column with {_where(pz, x)}. '
                f'So nobody else can stand at {_where(pz, x)}, or {_nm(pz, j)} would have nowhere to go')
    if t == 'forced-cell':
        x, axis = info[1], info[3]
        line = f'row {pz.row[x] + 1}' if axis == 0 else f'column {pz.col[x] + 1}'
        other = f'column {pz.col[x] + 1}' if axis == 0 else f'row {pz.row[x] + 1}'
        return (f'Only one square of {line} is still open to anyone ({_where(pz, x)}). Someone must stand there, '
                f'so nobody else can use {other}')
    if t == 'line-clash':
        at = info[1]
        if isinstance(at, Rel):
            return (f'{_nm(pz, at.who)} and {_nm(pz, at.other)} can\'t share a row or column, so '
                    f'{_owner_clue(pz, at)} rules out more squares for {_list(pz, hit)}')
        if at.who is None:
            return (f'{_owner_clue(pz, at)} can only hold if nobody shares a row or column; '
                    f'that rules out squares for {_list(pz, hit)}')
        if at.who == pz.victim:
            return (f'The murderer must be in {_nm(pz, at.who)}\'s area without sharing {pz.pron(at.who)[2]} row or '
                    f'column; that rules out squares for {_list(pz, hit)}')
        if getattr(at, 'desc', None):
            return (f'{_owner_clue(pz, at)} needs {at.desc} on a square that does not share {pz.pron(at.who)[2]} '
                    f'row or column; that rules out squares for {_list(pz, hit)}')
        return (f'{_owner_clue(pz, at)} needs a partner who does not share {pz.pron(at.who)[2]} row or column; '
                f'that rules out squares for {_list(pz, hit)}')
    if t == 'subset':
        axis, lines, combo = info[1], info[2], info[3]
        return (f'{_list(pz, list(combo))} can only use {_lines(axis, lines)} between them, '
                f'so nobody else can be in those {"rows" if axis == 0 else "columns"}')
    if t == 'witness':
        at = info[1]
        if info[0] == 'who':
            j = info[2]
            return (f'Who can be {_desc(pz, at)}? Only {_nm(pz, j)}, because nobody else can still reach a square that fits '
                    f'{_owner_clue(pz, at)}. That rules out {_nm(pz, j)}\'s other squares')
        x = info[2]
        return (f'Where can {_desc(pz, at)} stand? Only at {_where(pz, x)}, so whoever it is stands there: '
                f'nobody else can use row {pz.row[x] + 1} or column {pz.col[x] + 1}')
    if t.startswith('contra'):
        j, x, why = info[1], info[2], info[4]
        long = ' (this takes a longer chain of steps)' if t == 'contra-long' else ''
        return f'Suppose {_nm(pz, j)} were at {_where(pz, x)}: then {_why(pz, why)}{long}. So {_nm(pz, j)} can\'t be there'
    return None


def make_step_hints(pz, P, murderer, texts, own):
    """P: steps.profile(); texts[j]: person j's full clue text; own: own_domains."""
    hints = []
    seg = []
    placed_before = []
    for s in P['steps']:
        if s['info'][0] != 'place':
            seg.append(s)
            continue
        j, x = s['info'][1], s['info'][2]
        He, him, his = pz.pron(j)
        name = pz.names[j]
        clue_text = texts[j] if j != pz.victim else None
        parts = []
        if j in P['intersection'] and not placed_before:
            parts.append(f'Only one square fits both parts of {name}\'s clue ("{clue_text}")')
        elif not seg and len(own[j]) == 1:
            parts.append(f'Only one square fits {name}\'s clue ("{clue_text}")' if clue_text
                         else f'Only one square fits {name}\'s clue')
        else:
            adv = []
            for t in seg:
                if t['level'] >= 2:
                    txt = step_text(pz, t)
                    if txt and txt not in adv:
                        adv.append(txt)
            if len(adv) > 3:
                adv = adv[:3] + ['The same kind of reasoning rules out a few more squares']
            # one idea per hint: each earlier idea is its own hint, so the
            # hint button climbs a ladder instead of showing a wall of text
            for t in adv[:-1]:
                hints.append(t[0].upper() + t[1:] + '.')
            parts += adv[-1:]
            seen = set()
            for t in seg:
                if t['level'] != 1 or j not in {k for k, _ in t['rm']}:
                    continue
                if t['tech'] == 'line-confine':
                    axis, line, k = t['info'][1], t['info'][2], t['info'][3]
                    what = f'row {line + 1}' if axis == 0 else f'column {line + 1}'
                    desc = f'All of {pz.names[k]}\'s squares are in {what}, so nobody else can use it'
                else:
                    at = t['info'][1]
                    src = _owner_clue(pz, at)
                    if src in seen:
                        continue
                    seen.add(src)
                    if isinstance(at, Only):
                        desc = f'Because of {src}, nobody else can be on those squares'
                    elif isinstance(at, AreaCount) and at.who == pz.victim:
                        desc = 'The victim must share an area with exactly one other person'
                    elif at.who == j:
                        desc = f'{name}\'s own clue ("{clue_text}") rules out more squares'
                    else:
                        desc = f'Using {src}, some squares are ruled out for {name}'
                if desc not in parts:
                    parts.append(desc)
                if len(seen) >= 2:
                    break
            for t in seg:
                if t['tech'] == 'hidden-line' and t['info'][3] == j:
                    axis, line = t['info'][1], t['info'][2]
                    parts.append(f'{name} is now the only person who can still go in '
                                 + (f'row {line + 1}' if axis == 0 else f'column {line + 1}'))
                    break
            if not parts:
                if placed_before:
                    who = _list(pz, placed_before) if len(placed_before) <= 2 else 'everyone placed so far'
                    parts.append(f'With the rows and columns of {who} crossed out, only one square is left for '
                                 f'{name}' + (f' that fits {his} clue ("{clue_text}")' if clue_text else ''))
                else:
                    parts.append(f'Only one square fits {name}\'s clue' + (f' ("{clue_text}")' if clue_text else ''))
        parts = [p[0].upper() + p[1:] for p in parts]
        hints.append('. '.join(parts) + f'. So {_label(pz, j)} must be at {_where(pz, x)}. Cross out {his} row and column.')
        placed_before.append(j)
        seg = []
    if hints and murderer is not None:
        v = pz.victim
        hints[-1] += (f' {pz.names[murderer]} is the only person in the {pz.room_names[pz.area[pz.sol[v]]]} '
                      f'with {pz.names[v]}, so {pz.names[murderer]} is the murderer!')
    return hints


def aha_summary(pz, P):
    """Lines describing each aha episode: technique, where in the solve, cascade."""
    out = []
    for e in P['episodes']:
        if not e['aha']:
            continue
        mid = 'mid-solve' if 0.15 <= e['pos'] <= 0.8 else ('opening' if e['pos'] < 0.15 else 'endgame')
        out.append(f'{e["aha_key"]} after {e["placed"]}/{pz.n} placed ({e["pos"]:.0%}, {mid}); '
                   f'then {e["cascade"]} easy placement{"s" if e["cascade"] != 1 else ""}'
                   + (f'; techniques {"+".join(e["techs"])}' if len(e['techs']) > 1 else ''))
    if P['intersection']:
        out.append('opening intersection clue for ' + _list(pz, P['intersection']))
    return out


def trace_lines(pz, P):
    """The step solver's solve, compressed: placements and bottleneck steps."""
    who = lambda j: 'V' if j == pz.victim else chr(65 + j)
    lines = []
    for s in P['steps']:
        if s['info'][0] == 'place':
            x = s['info'][2]
            lines.append(f'place {who(s["info"][1])} at r{pz.row[x] + 1}c{pz.col[x] + 1}  (moves available {s["avail"]})')
        elif s['level'] >= 2:
            lines.append(f'** {s["tech"]} ({s["placed_before"]}/{pz.n} placed): {step_text(pz, s)}')
    return lines
