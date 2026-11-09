--[[--
On-device Murdoku case generator (pure Lua, no KOReader dependencies).
Port of tools/generator/mgen (layout, generate, hints, export).

    local Gen = require("murdoku_gen")
    local data, info = Gen.generate{ size = 7, difficulty = "medium", seed = 1234,
                                     yield = function() ... end, deadline = os.clock() + 20 }

`data` is a puzzle in the site's v2 JSON layout (a Lua table), so the normal
parser (murdoku_puzzle.lua) loads it like any downloaded case.

`yield` (optional) is called regularly; inside a coroutine it can call
coroutine.yield() so the UI stays responsive. `deadline` (optional, compared
with `clock()`, default os.clock) bounds the total work.
--]]

local S = require("murdoku_solver")
local C = require("murdoku_clues")
local St = require("murdoku_steps")
local T = require("murdoku_themes")
local A = S.Atom

local Gen = {}

Gen.VERSION = "2"
Gen.CREATOR = "Murdoku for KOReader"

--------------------------------------------------------------------------------
-- Deterministic RNG (Park-Miller "minimal standard", exact in doubles)
--------------------------------------------------------------------------------
local RNG = {}
RNG.__index = RNG

function Gen.newRNG(seed)
    local s = math.floor(math.abs(tonumber(seed) or 1)) % 2147483646 + 1
    local r = setmetatable({ s = s }, RNG)
    for _ = 1, 3 do r:random() end
    return r
end

function RNG:random()
    self.s = (self.s * 16807) % 2147483647
    return (self.s - 1) / 2147483646
end

function RNG:randint(a, b) return a + math.floor(self:random() * (b - a + 1)) end
function RNG:choice(t) return t[self:randint(1, #t)] end
function RNG:shuffle(t)
    for i = #t, 2, -1 do
        local j = self:randint(1, i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end
function RNG:sample(t, k)
    local c = {}
    for i, v in ipairs(t) do c[i] = v end
    self:shuffle(c)
    local out = {}
    for i = 1, k do out[i] = c[i] end
    return out
end
function RNG:uniform(a, b) return a + (b - a) * self:random() end

--------------------------------------------------------------------------------
-- Floor plans and furniture
--------------------------------------------------------------------------------
local ROOMS_FOR_SIZE = { [5] = { 3, 4 }, [6] = { 4, 5 }, [7] = { 4, 6 }, [8] = { 5, 7 }, [9] = { 6, 8 } }

local function split(N, k, rng)
    local rects = { { 0, 0, N, N } }
    local tries = 0
    while #rects < k and tries < 300 do
        tries = tries + 1
        local keyed = {}
        for i, r in ipairs(rects) do keyed[i] = { r, -(r[3] * r[4]) + rng:random() * 4 } end
        table.sort(keyed, function(a, b) return a[2] < b[2] end)
        for i, kr in ipairs(keyed) do rects[i] = kr[1] end
        local r0, c0, h, w = rects[1][1], rects[1][2], rects[1][3], rects[1][4]
        local horiz
        if h ~= w then horiz = h > w else horiz = rng:random() < 0.5 end
        local new
        if horiz and h >= 3 then
            local m = h < 4 and 1 or 2
            local cut = rng:randint(m, h - m)
            new = { { r0, c0, cut, w }, { r0 + cut, c0, h - cut, w } }
        elseif not horiz and w >= 3 then
            local m = w < 4 and 1 or 2
            local cut = rng:randint(m, w - m)
            new = { { r0, c0, h, cut }, { r0, c0 + cut, h, w - cut } }
        end
        if new and new[1][3] * new[1][4] >= 2 and new[2][3] * new[2][4] >= 2 then
            table.remove(rects, 1)
            table.insert(rects, new[1])
            table.insert(rects, new[2])
        end
    end
    return rects
end

local function lPairs(rects, label)
    local out = {}
    for i = 1, #rects do
        for j = i + 1, #rects do
            if label[i] == i and label[j] == j then
                for _, pq in ipairs({ { rects[i], rects[j] }, { rects[j], rects[i] } }) do
                    local p, q = pq[1], pq[2]
                    if p[1] + p[3] == q[1] then
                        local lo, hi = math.max(p[2], q[2]), math.min(p[2] + p[4], q[2] + q[4])
                        if hi > lo and ((p[2] == q[2]) ~= (p[2] + p[4] == q[2] + q[4])) then out[#out + 1] = { i, j } end
                    end
                    if p[2] + p[4] == q[2] then
                        local lo, hi = math.max(p[1], q[1]), math.min(p[1] + p[3], q[1] + q[3])
                        if hi > lo and ((p[1] == q[1]) ~= (p[1] + p[3] == q[1] + q[3])) then out[#out + 1] = { i, j } end
                    end
                end
            end
        end
    end
    return out
end

--- Returns a flat 0-based area array (areas numbered 1..k in reading order).
function Gen.floorPlan(N, rng)
    local lim = ROOMS_FOR_SIZE[N] or { math.max(3, N - 3), N - 1 }
    local k = rng:randint(lim[1], lim[2])
    local lrooms = rng:random() < 0.6 and 1 or 0
    if N >= 8 and rng:random() < 0.3 then lrooms = 2 end
    local rects = split(N, k + lrooms, rng)
    local label = {}
    for i = 1, #rects do label[i] = i end
    for _ = 1, lrooms do
        local pairs_ = lPairs(rects, label)
        if #pairs_ == 0 then break end
        local p = rng:choice(pairs_)
        label[p[2]] = p[1]
    end
    local area = {}
    for idx, r in ipairs(rects) do
        for rr = r[1], r[1] + r[3] - 1 do
            for cc = r[2], r[2] + r[4] - 1 do area[rr * N + cc] = label[idx] end
        end
    end
    local ren, n = {}, 0
    for x = 0, N * N - 1 do
        if not ren[area[x]] then n = n + 1; ren[area[x]] = n end
    end
    for x = 0, N * N - 1 do area[x] = ren[area[x]] end
    return area, n
end

--- Furniture. Returns anchors (flat ids), carpet (flat bools), room names {area = name}.
function Gen.furnish(N, area, nareas, theme, rng)
    local rtypes = rng:sample(theme.rooms, nareas)
    local obj, covered, carpet, names = {}, {}, {}, {}
    for x = 0, N * N - 1 do obj[x] = 0; covered[x] = false; carpet[x] = false end
    for a = 1, nareas do
        local rname, palette = rtypes[a][1], rtypes[a][2]
        names[a] = rname
        local cells = {}
        for x = 0, N * N - 1 do if area[x] == a then cells[#cells + 1] = x end end
        rng:shuffle(cells)
        local target = math.max(1, math.floor(#cells * rng:uniform(0.28, 0.42) + 0.5))
        local pool = {}
        for _, e in ipairs(palette) do for _ = 1, e[2] do pool[#pool + 1] = e[1] end end
        local placed = 0
        for _, x in ipairs(cells) do
            if placed >= target then break end
            local r, c = math.floor(x / N), x % N
            if not covered[x] and not carpet[x] then
                local w = rng:choice(pool)
                if w == "carpet" then
                    carpet[x] = true
                    for _, y in ipairs({ c + 1 < N and x + 1 or -1, r + 1 < N and x + N or -1 }) do
                        if y >= 0 and area[y] == a and not covered[y] and rng:random() < 0.5 then carpet[y] = true end
                    end
                    placed = placed + 1
                else
                    local oid = T.obj_id[w]
                    if T.two_wide[w] then
                        if c + 1 < N and area[x + 1] == a and not covered[x + 1] and not carpet[x + 1] then
                            obj[x] = oid
                            covered[x], covered[x + 1] = true, true
                            placed = placed + 2
                        end
                    else
                        obj[x] = oid
                        covered[x] = true
                        placed = placed + 1
                        if w == "table" then
                            local nb = {}
                            if r > 0 then nb[#nb + 1] = x - N end
                            if r < N - 1 then nb[#nb + 1] = x + N end
                            if c > 0 then nb[#nb + 1] = x - 1 end
                            if c < N - 1 then nb[#nb + 1] = x + 1 end
                            rng:shuffle(nb)
                            for _, y in ipairs(nb) do
                                if area[y] == a and not covered[y] and not carpet[y] and rng:random() < 0.5 then
                                    obj[y] = T.obj_id.chair
                                    covered[y] = true
                                    placed = placed + 1
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return obj, carpet, names
end

local function expand(anchors, N)
    local e = {}
    for x = 0, N * N - 1 do e[x] = anchors[x] end
    for x = 0, N * N - 1 do
        if S.RIGHT1[anchors[x]] and x % N + 1 < N and e[x + 1] == 0 then e[x + 1] = anchors[x] end
    end
    return e
end

--- Random solution (cells by person, victim last) and the murderer index, or nil.
function Gen.placePeople(N, area, eobj, rng)
    local function ok(r, c) return S.standable(eobj[r * N + c]) end
    for _ = 1, 300 do
        local cols = {}
        for i = 1, N do cols[i] = i - 1 end
        rng:shuffle(cols)
        for _ = 1, 300 do
            local bad = {}
            for r = 0, N - 1 do if not ok(r, cols[r + 1]) then bad[#bad + 1] = r end end
            if #bad == 0 then break end
            local r = rng:choice(bad)
            local s = rng:randint(0, N - 1)
            cols[r + 1], cols[s + 1] = cols[s + 1], cols[r + 1]
        end
        local good = true
        for r = 0, N - 1 do if not ok(r, cols[r + 1]) then good = false; break end end
        if good then
            local by = {}
            for r = 0, N - 1 do
                local x = r * N + cols[r + 1]
                local a = area[x]
                by[a] = by[a] or {}
                table.insert(by[a], x)
            end
            local pairs_ = {}
            for a = 1, N * N do if by[a] and #by[a] == 2 then pairs_[#pairs_ + 1] = by[a] end end
            if #pairs_ > 0 then
                local vm = rng:choice(pairs_)
                vm = { vm[1], vm[2] }
                rng:shuffle(vm)
                local victim, murderer = vm[1], vm[2]
                local others = {}
                for r = 0, N - 1 do
                    local x = r * N + cols[r + 1]
                    if x ~= victim then others[#others + 1] = x end
                end
                rng:shuffle(others)
                local sol, m = {}, nil
                for i, x in ipairs(others) do
                    sol[i] = x
                    if x == murderer then m = i end
                end
                sol[N] = victim
                return sol, m
            end
        end
    end
    return nil
end

function Gen.cast(N, rng)
    local female = {}
    for i = 1, N do female[i] = rng:random() < 0.5 end
    local nf = 0
    for i = 1, N - 1 do if female[i] then nf = nf + 1 end end
    if nf < 2 or nf > N - 3 then
        local idx = {}
        for i = 1, N - 1 do idx[i] = i end
        rng:shuffle(idx)
        for k, i in ipairs(idx) do female[i] = (k % 2 == 1) end
    end
    local names = {}
    for i = 1, N - 1 do
        local letter = string.char(64 + i)
        names[i] = rng:choice((female[i] and T.female or T.male)[letter])
    end
    names[N] = rng:choice(female[N] and T.victim_f or T.victim_m)
    return names, female
end

--------------------------------------------------------------------------------
-- Generation
--------------------------------------------------------------------------------
local PROFILES = {
    ["very-easy"] = { 2.0, 0.4, 0.7, 0.2 },
    easy = { 1.3, 0.8, 0.6, 0.35 },
    medium = { 0.7, 1.6, 0.5, 0.4 },
    hard = { 0.35, 2.5, 0.3, 0.4 },
    any = { 1.0, 1.0, 0.5, 0.35 },
}

local function weight(c, prof)
    local w = C.KIND_W[c.kind] or 1
    if C.STRONG[c.kind] then w = w * prof[1] elseif C.WEAK[c.kind] then w = w * prof[2] end
    return w
end

local function pick(rng, list, prof)
    if #list == 0 then return nil end
    local tot = 0
    for _, c in ipairs(list) do tot = tot + weight(c, prof) end
    local r = rng:random() * tot
    for _, c in ipairs(list) do
        r = r - weight(c, prof)
        if r <= 0 then return c end
    end
    return list[#list]
end

local function atomsOf(chosen, general, vclue)
    local out = {}
    for _, lst in ipairs(chosen) do
        for _, c in ipairs(lst) do for _, a in ipairs(c.atoms) do out[#out + 1] = a end end
    end
    for _, c in ipairs(general) do for _, a in ipairs(c.atoms) do out[#out + 1] = a end end
    for _, a in ipairs(vclue.atoms) do out[#out + 1] = a end
    return out
end

local function npos(chosen)
    local k = 0
    for _, lst in ipairs(chosen) do for _, c in ipairs(lst) do if c.positional then k = k + 1 end end end
    return k
end

local function copyChosen(chosen)
    local t = {}
    for i, lst in ipairs(chosen) do
        t[i] = {}
        for k, c in ipairs(lst) do t[i][k] = c end
    end
    return t
end

local Stop = {}

-- Largest board where the "designed aha" climb is used by default, per difficulty.
-- Desktop LuaJIT means (aha vs plain): very easy 0.16/0.02 s at 5x5, 0.28/0.07 s at
-- 6x6, 0.67/0.17 s at 7x7; easy 0.17/0.08, 0.29/0.14, 0.44/0.31 s. A Kindle is
-- ~8-15x slower, so that is a few seconds at 6x6/7x7. Medium costs 0.6-1.2 s at
-- 5x5/6x6 and only 25-40% of cases pass within the scene budget, and 8x8/9x9 or
-- hard are slower still, so those keep the plain pipeline (the Originals pack has
-- aha cases of every size and difficulty, made offline).
Gen.AHA_MAX_SIZE = { ["very-easy"] = 7, easy = 7, medium = 0, hard = 0, any = 7 }

--- Generate one case. opts: size, difficulty, seed, theme (name), yield, deadline, clock.
-- Returns data (v2 table), info; or nil, reason.
function Gen.generate(opts)
    local N = opts.size or 7
    local target = S.GRADE_INDEX[opts.difficulty or ""] and opts.difficulty or "any"
    local seed = opts.seed or os.time()
    local rng = Gen.newRNG(seed)
    local prof = PROFILES[target] or PROFILES.any
    local clock = opts.clock or os.clock
    local deadline = opts.deadline
    local poscap = N <= 6 and 1 or 2
    local node_limit = opts.node_limit or 60000
    -- a puzzle needing more what-if steps than the target allows is useless
    local max_trials = ({ ["very-easy"] = 0, easy = 3, medium = 15 })[target]
    local yield = opts.yield or function() end
    local use_aha = opts.aha
    if use_aha == nil then use_aha = N <= (Gen.AHA_MAX_SIZE[target] or 0) end
    local aha_scenes, aha_max_scenes, aha_iters = 0, opts.aha_scenes or 4, opts.aha_iters or 20
    local climb
    local function tick()
        yield()
        if deadline and clock() > deadline then error(Stop, 0) end
    end

    -- Unique (exhaustive counter, cheap rejection) and solvable by logic?
    local function status(pz, chosen, general, vclue)
        tick()
        local atoms = atomsOf(chosen, general, vclue)
        local cnt, sols, timed_out = S.countSolutions(pz, atoms, 2, node_limit)
        if timed_out then return false, nil, -1, sols end
        if cnt ~= 1 then return false, nil, cnt, sols end
        local L = S.logicSolve(pz, atoms, { yield = tick, max_trials = max_trials })
        return L.solved, L, cnt, sols
    end

    local function kills(pz, c, alt, j)
        for _, at in ipairs(c.atoms) do
            if at.type == "In" and not A.allowed(pz, at)[alt[j]] then return true end
            if at.type == "Rel" and not at.fn(pz, alt[at.who], alt[at.other]) then return true end
        end
        return false
    end

    local function harden(pz, cands, chosen, general, vclue)
        local goal = S.GRADE_INDEX[target]
        local L = S.logicSolve(pz, atomsOf(chosen, general, vclue), { yield = tick })
        local best = L.trials
        for _ = 1, 3 do
            local order = {}
            for j = 1, pz.n - 1 do order[j] = j end
            rng:shuffle(order)
            local improved = false
            for _, j in ipairs(order) do
                local have = {}
                for _, c in ipairs(chosen[j]) do have[c.text] = true end
                local opts_ = {}
                for _, c in ipairs(cands[j]) do
                    if not have[c.text] and not (c.positional and npos(chosen) >= poscap) then
                        opts_[#opts_ + 1] = { c, -(weight(c, prof) * rng:random() * (C.WEAK[c.kind] and 2 or 1)) }
                    end
                end
                table.sort(opts_, function(a, b) return a[2] < b[2] end)
                for k = 1, math.min(8, #opts_) do
                    local c = opts_[k][1]
                    local trial = copyChosen(chosen)
                    trial[j] = { c }
                    local ok, L2 = status(pz, trial, general, vclue)
                    if ok and L2.trials >= best and S.GRADE_INDEX[S.grade(L2)] <= goal then
                        if L2.trials > best or rng:random() < 0.3 then
                            chosen, L, best = trial, L2, L2.trials
                            improved = true
                            if S.GRADE_INDEX[S.grade(L)] == goal then return chosen, L end
                            break
                        end
                    end
                end
            end
            if not improved then break end
        end
        return chosen, L
    end

    -- Add/replace sentences until unique and logic-solvable, then drop second
    -- sentences that are not needed. Returns chosen or nil.
    local function repair(pz, cands, chosen, general, vclue)
        local N, sol = pz.n, pz.sol
        local ok = false
        for _ = 1, 60 do
            local solved, L, cnt, sols = status(pz, chosen, general, vclue)
            if solved then ok = true; break end
            if cnt == -1 or cnt == 0 then break end
            local alt, amb = nil, {}
            if cnt == 1 then
                for j = 1, N - 1 do if L and L.Dn[j] > 1 then amb[#amb + 1] = j end end
            else
                for _, s in ipairs(sols) do
                    for j = 1, N do
                        if s[j] ~= sol[j] then alt = s; break end
                    end
                    if alt then break end
                end
                for j = 1, N - 1 do if alt[j] ~= sol[j] then amb[#amb + 1] = j end end
            end
            if #amb == 0 then for j = 1, N - 1 do amb[j] = j end end
            rng:shuffle(amb)
            local added = false
            for _, j in ipairs(amb) do
                if #chosen[j] < 2 then
                    local have = {}
                    for _, c in ipairs(chosen[j]) do have[c.text] = true end
                    local opts_, killing = {}, {}
                    for _, c in ipairs(cands[j]) do
                        if not have[c.text] and not (c.positional and npos(chosen) >= poscap) then
                            opts_[#opts_ + 1] = c
                            if alt and kills(pz, c, alt, j) then killing[#killing + 1] = c end
                        end
                    end
                    if #killing > 0 then opts_ = killing end
                    local c = pick(rng, opts_, prof)
                    if c then
                        table.insert(chosen[j], c)
                        added = true
                        break
                    end
                end
            end
            if not added then
                local j = amb[1]
                local opts_ = {}
                for _, c in ipairs(cands[j]) do
                    if not c.positional or npos(chosen) < poscap then opts_[#opts_ + 1] = c end
                end
                chosen[j] = { pick(rng, opts_, prof) }
            end
        end
        if not ok then return nil end
        -- prune second sentences that are not needed
        local order = {}
        for j = 1, N - 1 do order[j] = j end
        rng:shuffle(order)
        for _, j in ipairs(order) do
            if #chosen[j] > 1 then
                for k = 1, #chosen[j] do
                    local trial = copyChosen(chosen)
                    table.remove(trial[j], k)
                    if status(pz, trial, general, vclue) then chosen = trial; break end
                end
            end
        end
        return chosen
    end

    -- "Designed aha" (port of mgen/aha.py): hill-climb the clue set until the
    -- step solver finds a mid-solve aha followed by a cascade, the victim is
    -- placed last or second to last, and (except hard) <= 3 what-ifs.
    -- Only used where it fits the on-device time budget (see AHA_MAX_SIZE);
    -- after aha_max_scenes scenes without success the plain pipeline takes over.
    local function evaluate(pz, chosen, general, vclue)
        local atoms = atomsOf(chosen, general, vclue)
        local P = St.profile(pz, atoms, target ~= "hard" and St.SCORE_WHATIFS or nil, tick)
        local L = S.logicSolve(pz, atoms, { yield = tick })
        return P, S.grade(L)
    end

    function climb(pz, cands, chosen, general, vclue)
        local P, gr = evaluate(pz, chosen, general, vclue)
        local best = St.objective(P, gr, target)
        for _ = 1, aha_iters do
            if St.accept(P, gr, target) then break end
            local trial = copyChosen(chosen)
            local j = rng:randint(1, pz.n - 1)
            local op = rng:random()
            local mutated = true
            if op < 0.6 then
                trial[j] = { rng:choice(cands[j]) }
            elseif op < 0.85 and #trial[j] < 2 then
                table.insert(trial[j], rng:choice(cands[j]))
            elseif #trial[j] > 1 then
                table.remove(trial[j], rng:randint(1, #trial[j]))
            else
                mutated = false
            end
            if mutated and npos(trial) <= poscap then
                trial = repair(pz, cands, trial, general, vclue)
                if trial then
                    local Q, g2 = evaluate(pz, trial, general, vclue)
                    local v = St.objective(Q, g2, target)
                    if v >= best then chosen, P, gr, best = trial, Q, g2, v end
                end
            end
        end
        return chosen, P, gr
    end

    local themes = T.themes
    local function attempt()
        local theme
        if opts.theme then
            for _, th in ipairs(themes) do if th.name == opts.theme then theme = th end end
        end
        theme = theme or rng:choice(themes)
        local area, nareas = Gen.floorPlan(N, rng)
        if nareas > #theme.rooms then return nil end
        local anchors, carpet, rnames = Gen.furnish(N, area, nareas, theme, rng)
        local eobj = expand(anchors, N)
        local sol, murderer = Gen.placePeople(N, area, eobj, rng)
        if not sol then return nil end
        local names, female = Gen.cast(N, rng)
        local pz = S.newPuzzle(N, N, area, eobj, carpet, names, female, rnames, sol, murderer)
        local g = C.newCtx(pz, anchors)
        local vclue = C.victimClue(pz)
        local cands = {}
        local aha_on = use_aha and aha_scenes < aha_max_scenes
        for i = 1, N - 1 do
            cands[i] = C.candidates(g, i, rng)
            if aha_on then
                for _, c in ipairs(C.existentialCandidates(g, i)) do cands[i][#cands[i] + 1] = c end
            end
        end
        local gens = C.generalCandidates(g)
        local chosen, general = {}, {}
        for i = 1, N - 1 do chosen[i] = {} end
        tick()

        if rng:random() < prof[3] then
            local keys = {}
            local KEY = { beside2 = true, onroom = true, besideroom = true, notbeside = true, onlygender = true,
                onlyon = true, onlybeside = true }
            for i = 1, N - 1 do
                for _, c in ipairs(cands[i]) do
                    if KEY[c.kind] and S.size(S.ownDomains(pz, c.atoms)[i]) == 1 then keys[#keys + 1] = c end
                end
            end
            if #keys > 0 then
                local k = rng:choice(keys)
                chosen[k.who] = { k }
            end
        end
        if rng:random() < prof[4] and #gens > 0 then general = { rng:choice(gens) } end
        for i = 1, N - 1 do
            if #chosen[i] == 0 then
                local np = {}
                for _, c in ipairs(cands[i]) do if not c.positional then np[#np + 1] = c end end
                chosen[i] = { pick(rng, np, prof) or pick(rng, cands[i], prof) }
            end
        end

        chosen = repair(pz, cands, chosen, general, vclue)
        if not chosen then return nil end

        if #general > 0 and status(pz, chosen, {}, vclue) then general = {} end
        for j = 1, N - 1 do
            if #chosen[j] >= 2 then
                local singles = {}
                for _, c in ipairs(cands[j]) do
                    if not (c.positional and npos(chosen) >= poscap) then singles[#singles + 1] = c end
                end
                rng:shuffle(singles)
                for k = 1, math.min(10, #singles) do
                    local trial = copyChosen(chosen)
                    trial[j] = { singles[k] }
                    if status(pz, trial, general, vclue) then chosen = trial; break end
                end
            end
        end

        local L = S.logicSolve(pz, atomsOf(chosen, general, vclue), { yield = tick })
        local gr = S.grade(L)
        if target ~= "any" and (S.GRADE_INDEX[gr] or 0) < S.GRADE_INDEX[target] then
            chosen, L = harden(pz, cands, chosen, general, vclue)
            gr = S.grade(L)
        end
        local P
        if aha_on then
            aha_scenes = aha_scenes + 1
            chosen, P, gr = climb(pz, cands, chosen, general, vclue)
            if not St.accept(P, gr, target) then return nil end
        end
        if target ~= "any" and gr ~= target then return nil end
        if npos(chosen) > poscap then return nil end
        local atoms = atomsOf(chosen, general, vclue)
        L = S.logicSolve(pz, atoms, { events = true, yield = tick })
        -- belt and braces: confirm uniqueness with the exhaustive counter once
        local cnt, _, timed_out = S.countSolutions(pz, atoms, 2, 400000)
        if cnt ~= 1 or timed_out then return nil end
        local o = L.order
        if not P and not (o[#o] == pz.victim or o[#o - 1] == pz.victim) then return nil end
        return { pz = pz, anchors = anchors, theme = theme, chosen = chosen, general = general,
                 vclue = vclue, logic = L, grade = S.grade(L), atoms = atoms, profile = P,
                 score = P and St.objective(P, gr, target) or nil }
    end

    local attempts = 0
    while true do
        attempts = attempts + 1
        if attempts > (opts.max_attempts or 400) then return nil, "no case found" end
        local ok, res = pcall(attempt)
        if not ok then
            if res == Stop then return nil, "time" end
            error(res, 0)
        end
        if res then
            res.attempts = attempts
            res.seed = seed
            local texts = {}
            for i, lst in ipairs(res.chosen) do
                local t = {}
                for _, c in ipairs(lst) do t[#t + 1] = c.text end
                texts[i] = table.concat(t, " ")
            end
            texts[N] = res.vclue.text
            res.texts = texts
            if res.profile then
                res.hints = Gen.stepHints(res.pz, res.profile, res.pz.murderer, texts, S.ownDomains(res.pz, res.atoms))
            else
                res.hints = Gen.hints(res.pz, res.atoms, res.logic, res.pz.murderer, texts)
            end
            local title = opts.title or rng:choice(res.theme.titles)
            return Gen.toData(res, title, opts.id), res
        end
    end
end

--------------------------------------------------------------------------------
-- Hints from the solver trace (port of mgen/hints.py)
--------------------------------------------------------------------------------
local function where(pz, x) return string.format("row %d, column %d", pz.row[x] + 1, pz.col[x] + 1) end

local function label(pz, j)
    if j == pz.victim then return pz.names[j] .. " (the victim)" end
    return string.format("%s (%s)", pz.names[j], string.char(64 + j))
end

local function ownerClue(pz, atom)
    local src = atom.src
    if not src then return "a clue" end
    if src.who == nil then return 'the general clue ("' .. src.text .. '")' end
    if src.who == pz.victim then return "the victim's clue (alone with the murderer)" end
    return pz.names[src.who] .. "'s clue (\"" .. src.text .. "\")"
end

local function why(pz, w)
    if w[1] == "empty" then return pz.names[w[2]] .. " would have nowhere left to go" end
    if w[1] == "row" then return "nobody could stand in row " .. (w[2] + 1) end
    if w[1] == "col" then return "nobody could stand in column " .. (w[2] + 1) end
    if w[1] == "clue" then return ownerClue(pz, w[2]) .. " could not be true" end
    return "that leads to a contradiction"
end

local function list(pz, js)
    local names = {}
    for _, j in ipairs(js) do names[#names + 1] = pz.names[j] end
    if #names == 1 then return names[1] end
    return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

function Gen.hints(pz, atoms, logic, murderer, texts)
    local own = S.ownDomains(pz, atoms)
    local hints, seg, before = {}, {}, {}
    for _, e in ipairs(logic.events) do
        if e[1] ~= "place" then
            seg[#seg + 1] = e
        else
            local j, x = e[2], e[3]
            local _He, _him, his = pz:pron(j)
            local name = pz.names[j]
            local clue_text = j ~= pz.victim and texts[j] or nil
            local parts = {}
            local trials, hidden, clues, pairs_ = {}, {}, {}, {}
            for _, t in ipairs(seg) do
                if t[1] == "trial" then trials[#trials + 1] = t
                elseif t[1] == "hidden" and t[2] == j then hidden[#hidden + 1] = t
                elseif t[1] == "clue" then
                    for _, k in ipairs(t[3]) do if k == j then clues[#clues + 1] = t; break end end
                elseif t[1] == "pair" then
                    for _, k in ipairs(t[5]) do if k == j then pairs_[#pairs_ + 1] = t; break end end
                end
            end
            local own1 = S.size(own[j]) == 1
            if #seg == 0 and own1 then
                if clue_text then
                    parts[#parts + 1] = "Only one square fits " .. name .. "'s clue (\"" .. clue_text .. "\")"
                else
                    parts[#parts + 1] = "Only one square fits " .. name .. "'s clue"
                end
            else
                local groups, gorder = {}, {}
                for _, t in ipairs(trials) do
                    local key = t[2] .. "|" .. why(pz, t[4])
                    if not groups[key] then
                        groups[key] = { k = t[2], why = why(pz, t[4]), sq = {} }
                        gorder[#gorder + 1] = key
                    end
                    table.insert(groups[key].sq, where(pz, t[3]))
                end
                table.sort(gorder, function(a, b)
                    local ga, gb = groups[a], groups[b]
                    if (ga.k == j) ~= (gb.k == j) then return ga.k == j end
                    return false
                end)
                for gi = 1, math.min(2, #gorder) do
                    local gr = groups[gorder[gi]]
                    local nm = pz.names[gr.k]
                    if #gr.sq == 1 then
                        parts[#parts + 1] = "Suppose " .. nm .. " were at " .. gr.sq[1] .. ": then " .. gr.why
                            .. ". So " .. nm .. " can't be there"
                    else
                        local shown = {}
                        for k = 1, math.min(3, #gr.sq) do shown[k] = gr.sq[k] end
                        if #gr.sq > 3 then shown[#shown + 1] = "..." end
                        parts[#parts + 1] = nm .. " can't be at " .. table.concat(shown, "; ") .. ": in each case " .. gr.why
                    end
                end
                if #gorder > 2 then parts[#parts + 1] = "Testing the remaining squares the same way rules out a few more" end
                local trial_on_j = false
                for _, t in ipairs(trials) do if t[2] == j then trial_on_j = true end end
                if #trials > 0 and not trial_on_j then
                    parts[#parts + 1] = "That leaves only one possible square for " .. name
                        .. (clue_text and (" that fits " .. his .. " clue (\"" .. clue_text .. "\")") or "")
                end
                if pairs_[1] then
                    local t = pairs_[1]
                    local axis = t[2] == 0 and "rows" or "columns"
                    parts[#parts + 1] = string.format("%s and %s can only use %s %d and %d, so nobody else can be in those %s",
                        pz.names[t[4][1]], pz.names[t[4][2]], axis, t[3][1] + 1, t[3][2] + 1, axis)
                end
                local seen, nseen = {}, 0
                for _, t in ipairs(clues) do
                    local desc = ownerClue(pz, t[2])
                    if not seen[desc] then
                        seen[desc] = true
                        nseen = nseen + 1
                        local at = t[2]
                        if at.type == "Only" then
                            parts[#parts + 1] = "Because of " .. desc .. ", nobody else can be on those squares"
                        elseif at.type == "AreaCount" and at.who == pz.victim then
                            parts[#parts + 1] = "The victim must share an area with exactly one other person"
                        elseif at.who ~= j then
                            parts[#parts + 1] = "Using " .. desc .. ", some squares are ruled out for " .. name
                        else
                            parts[#parts + 1] = name .. "'s own clue (\"" .. tostring(clue_text) .. "\") rules out more squares"
                        end
                        if nseen >= 2 then break end
                    end
                end
                if hidden[1] then
                    local t = hidden[1]
                    parts[#parts + 1] = name .. " is now the only person who can still go in "
                        .. (t[3] == 0 and "row " or "column ") .. (t[4] + 1)
                end
                if #parts == 0 then
                    if #before > 0 then
                        local who = #before <= 2 and list(pz, before) or "everyone placed so far"
                        parts[#parts + 1] = "With the rows and columns of " .. who .. " crossed out, only one square is left for "
                            .. name .. (clue_text and (" that fits " .. his .. " clue (\"" .. clue_text .. "\")") or "")
                    else
                        parts[#parts + 1] = "Only one square fits " .. name .. "'s clue"
                            .. (clue_text and (" (\"" .. clue_text .. "\")") or "")
                    end
                end
            end
            hints[#hints + 1] = table.concat(parts, ". ") .. ". So " .. label(pz, j) .. " must be at " .. where(pz, x)
                .. ". Cross out " .. his .. " row and column."
            before[#before + 1] = j
            seg = {}
        end
    end
    if #hints > 0 and murderer then
        local v = pz.victim
        hints[#hints] = hints[#hints] .. string.format(" %s is the only person in the %s with %s, so %s is the murderer!",
            pz.names[murderer], pz.room_names[pz.area[pz.sol[v]]], pz.names[v], pz.names[murderer])
    end
    return hints
end

--------------------------------------------------------------------------------
-- Hints from the step solver's trace (aha mode; port of mgen/stephints.py)
--------------------------------------------------------------------------------
local function cap(t) return t:sub(1, 1):upper() .. t:sub(2) end

local function stepWhy(pz, w)
    if w[1] == "share" then
        return pz.names[w[2]] .. " and " .. pz.names[w[3]] .. " would have to share a row or column"
    end
    return why(pz, w)
end

local function companion(pz, at)
    if at.desc then return at.desc end
    local owner = pz.names[at.who]
    if at.type == "AreaCount" then
        if at.who == pz.victim then return "the murderer (the one person alone with " .. owner .. ")" end
        if at.cond and at.cond.t == "female" then
            return "the " .. (at.cond.v and "woman" or "man") .. " in " .. owner .. "'s area"
        end
        return "the other person in " .. owner .. "'s area"
    end
    return 'the "someone" in ' .. ownerClue(pz, at)
end

local function lineList(axis, lines)
    local nums = {}
    for i, l in ipairs(lines) do nums[i] = tostring(l + 1) end
    return (axis == 0 and "rows " or "columns ") .. table.concat(nums, ", ", 1, #nums - 1) .. " and " .. nums[#nums]
end

function Gen.stepText(pz, s)
    local t, info = s.tech, s.info
    local hitset, hit = {}, {}
    for _, e in ipairs(s.rm) do
        if not hitset[e[1]] then hitset[e[1]] = true; hit[#hit + 1] = e[1] end
    end
    table.sort(hit)
    if t == "cross-block" then
        local x, j = info[2], info[3]
        local he = pz:pron(j):lower()
        return "Look at " .. pz.names[j] .. ": every square " .. he .. " could still use shares a row or column with "
            .. where(pz, x) .. ". So nobody else can stand at " .. where(pz, x) .. ", or " .. pz.names[j]
            .. " would have nowhere to go"
    elseif t == "forced-cell" then
        local x, axis = info[2], info[4]
        local line = axis == 0 and ("row " .. (pz.row[x] + 1)) or ("column " .. (pz.col[x] + 1))
        local other = axis == 0 and ("column " .. (pz.col[x] + 1)) or ("row " .. (pz.row[x] + 1))
        return "Only one square of " .. line .. " is still open to anyone (" .. where(pz, x)
            .. "). Someone must stand there, so nobody else can use " .. other
    elseif t == "line-clash" then
        local at = info[2]
        if at.type == "Rel" then
            return pz.names[at.who] .. " and " .. pz.names[at.other] .. " can't share a row or column, so "
                .. ownerClue(pz, at) .. " rules out more squares for " .. list(pz, hit)
        end
        if at.who == nil then
            return ownerClue(pz, at) .. " can only hold if nobody shares a row or column; that rules out squares for "
                .. list(pz, hit)
        end
        local _, _, his = pz:pron(at.who)
        if at.who == pz.victim then
            return "The murderer must be in " .. pz.names[at.who] .. "'s area without sharing " .. his
                .. " row or column; that rules out squares for " .. list(pz, hit)
        end
        if at.desc then
            return ownerClue(pz, at) .. " needs " .. at.desc .. " on a square that does not share " .. his
                .. " row or column; that rules out squares for " .. list(pz, hit)
        end
        return ownerClue(pz, at) .. " needs a partner who does not share " .. his
            .. " row or column; that rules out squares for " .. list(pz, hit)
    elseif t == "subset" then
        local axis, lines, combo = info[2], info[3], info[4]
        return list(pz, combo) .. " can only use " .. lineList(axis, lines) .. " between them, so nobody else can be in those "
            .. (axis == 0 and "rows" or "columns")
    elseif t == "witness" then
        local at = info[2]
        if info[1] == "who" then
            local j = info[3]
            return "Who can be " .. companion(pz, at) .. "? Only " .. pz.names[j]
                .. ", because nobody else can still reach a square that fits " .. ownerClue(pz, at) .. ". That rules out "
                .. pz.names[j] .. "'s other squares"
        end
        local x = info[3]
        return "Where can " .. companion(pz, at) .. " stand? Only at " .. where(pz, x)
            .. ", so whoever it is stands there: nobody else can use row " .. (pz.row[x] + 1) .. " or column " .. (pz.col[x] + 1)
    elseif t:sub(1, 6) == "contra" then
        local j, x, w = info[2], info[3], info[5]
        return "Suppose " .. pz.names[j] .. " were at " .. where(pz, x) .. ": then " .. stepWhy(pz, w)
            .. (t == "contra-long" and " (this takes a longer chain of steps)" or "") .. ". So " .. pz.names[j]
            .. " can't be there"
    end
    return nil
end

function Gen.stepHints(pz, P, murderer, texts, own)
    local hints, seg, before = {}, {}, {}
    local inter = {}
    for _, j in ipairs(P.intersection) do inter[j] = true end
    for _, s in ipairs(P.steps) do
        if s.info[1] ~= "place" then
            seg[#seg + 1] = s
        else
            local j, x = s.info[2], s.info[3]
            local _He, _him, his = pz:pron(j)
            local name = pz.names[j]
            local clue_text = j ~= pz.victim and texts[j] or nil
            local parts, have = {}, {}
            local function add(p) if not have[p] then have[p] = true; parts[#parts + 1] = p end end
            if inter[j] and #before == 0 then
                add("Only one square fits both parts of " .. name .. "'s clue (\"" .. tostring(clue_text) .. "\")")
            elseif #seg == 0 and S.size(own[j]) == 1 then
                add("Only one square fits " .. name .. "'s clue" .. (clue_text and (" (\"" .. clue_text .. "\")") or ""))
            else
                local nadv = 0
                for _, t in ipairs(seg) do
                    if t.level >= 2 then
                        local txt = Gen.stepText(pz, t)
                        if txt and not have[txt] then
                            nadv = nadv + 1
                            if nadv <= 3 then add(txt)
                            elseif nadv == 4 then add("The same kind of reasoning rules out a few more squares") end
                        end
                    end
                end
                local nseen = 0
                for _, t in ipairs(seg) do
                    local hitj = false
                    for _, e in ipairs(t.rm) do if e[1] == j then hitj = true; break end end
                    if t.level == 1 and hitj and nseen < 2 then
                        if t.tech == "line-confine" then
                            local axis, line, k = t.info[2], t.info[3], t.info[4]
                            add("All of " .. pz.names[k] .. "'s squares are in " .. (axis == 0 and "row " or "column ")
                                .. (line + 1) .. ", so nobody else can use it")
                        else
                            local at = t.info[2]
                            local src = ownerClue(pz, at)
                            local p
                            if at.type == "Only" then
                                p = "Because of " .. src .. ", nobody else can be on those squares"
                            elseif at.type == "AreaCount" and at.who == pz.victim then
                                p = "The victim must share an area with exactly one other person"
                            elseif at.who == j then
                                p = name .. "'s own clue (\"" .. tostring(clue_text) .. "\") rules out more squares"
                            else
                                p = "Using " .. src .. ", some squares are ruled out for " .. name
                            end
                            if not have[p] then nseen = nseen + 1 end
                            add(p)
                        end
                    end
                end
                for _, t in ipairs(seg) do
                    if t.tech == "hidden-line" and t.info[4] == j then
                        add(name .. " is now the only person who can still go in "
                            .. (t.info[2] == 0 and "row " or "column ") .. (t.info[3] + 1))
                        break
                    end
                end
                if #parts == 0 then
                    if #before > 0 then
                        local who = #before <= 2 and list(pz, before) or "everyone placed so far"
                        add("With the rows and columns of " .. who .. " crossed out, only one square is left for "
                            .. name .. (clue_text and (" that fits " .. his .. " clue (\"" .. clue_text .. "\")") or ""))
                    else
                        add("Only one square fits " .. name .. "'s clue" .. (clue_text and (" (\"" .. clue_text .. "\")") or ""))
                    end
                end
            end
            for i, p in ipairs(parts) do parts[i] = cap(p) end
            hints[#hints + 1] = table.concat(parts, ". ") .. ". So " .. label(pz, j) .. " must be at " .. where(pz, x)
                .. ". Cross out " .. his .. " row and column."
            before[#before + 1] = j
            seg = {}
        end
    end
    if #hints > 0 and murderer then
        local v = pz.victim
        hints[#hints] = hints[#hints] .. string.format(" %s is the only person in the %s with %s, so %s is the murderer!",
            pz.names[murderer], pz.room_names[pz.area[pz.sol[v]]], pz.names[v], pz.names[murderer])
    end
    return hints
end

--------------------------------------------------------------------------------
-- Export to the site's v2 layout (as a Lua table)
--------------------------------------------------------------------------------
local function ahaMeta(P)
    if not P then return nil end
    local out = {}
    for _, e in ipairs(P.episodes) do
        if e.aha then out[#out + 1] = { tech = e.aha_key, placed = e.placed, cascade = e.cascade } end
    end
    return out
end

function Gen.toData(res, title, id)
    local pz = res.pz
    local N = pz.W
    local P = {
        puzzle_version = "2", grid_w = tostring(N), grid_h = tostring(pz.H),
        total_char = tostring(pz.n), total_chars = tostring(pz.n),
        murderer = tostring(pz.murderer - 1),
        difficulty = tostring((S.GRADE_INDEX[res.grade] or 1) - 1),
    }
    for k, h in ipairs(res.hints) do P["player_hint_" .. k .. "_en"] = h end
    local Ch = { title_en_ = title, creator_ = Gen.CREATOR }
    for x = 0, pz.ncell - 1 do
        local key = pz.row[x] .. "_" .. pz.col[x]
        Ch["room_code_" .. key] = tostring(pz.area[x])
        Ch["room_objects_" .. key] = tostring(res.anchors[x])
        Ch["carpet_objects_" .. key] = pz.carpet[x] and "5" or "0"
    end
    for _, a in ipairs(pz.areas) do Ch["room_name_" .. a] = pz.room_names[a] end
    for i = 1, pz.n do
        local k = i - 1
        Ch["char_name_" .. k] = pz.names[i]
        Ch["char_sex_" .. k] = pz.female[i] and "1" or "0"
        Ch["char_quote_en_" .. k] = res.texts[i]
        Ch["solution_x_" .. k] = tostring(pz.col[pz.sol[i]])
        Ch["solution_y_" .. k] = tostring(pz.row[pz.sol[i]])
    end
    for k, g in ipairs(res.general) do Ch["general_clue_" .. (k - 1)] = g.text end
    return {
        PROPERTIES = P,
        CHARACTERS = Ch,
        META = { id = id, theme = res.theme.name, grade = res.grade, trials = res.logic.trials,
                 seed = res.seed, generator = "lua-" .. Gen.VERSION, aha = ahaMeta(res.profile) },
    }
end

return Gen
