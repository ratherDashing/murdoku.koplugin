--[[--
Step solver that names the technique of every step, and the "designed aha"
profile/accept/objective built on it. Port of tools/generator/mgen/steps.py
and the scoring parts of mgen/aha.py (pure Lua, no KOReader dependencies).

Levels: 0 naked-single, hidden-line; 1 line-confine, clue-*; 2 forced-cell,
cross-block, line-clash; 3 subset (k = 2, 3), witness; 4 contra-short/-long.
--]]

local S = require("murdoku_solver")

local St = {}

local AHA = { ["line-clash"] = true, ["cross-block"] = true, subset = true, witness = true,
    ["contra-short"] = true, intersection = true }
St.AHA = AHA
St.MAX_WHATIFS = 3
St.SCORE_WHATIFS = 8

local function clueName(at)
    local t = at.type
    if t == "Rel" then return "clue-rel" end
    if t == "AreaCount" then return "clue-area" end
    if t == "Only" then return "clue-only" end
    if t == "Exists" then return "clue-exists" end
    if at.global then return "clue-global" end
    return "clue-other"
end

local function sizeOf(d)
    local k = 0
    for _ in next, d do k = k + 1 end
    return k
end

local function counts(D, n)
    local Dn = {}
    for j = 1, n do Dn[j] = sizeOf(D[j]) end
    return Dn
end

local function prune(pz, at, D, n)
    local out = {}
    if at.type == "Only" then
        for j = 1, n do
            if j ~= at.who and not at.exempt[j] then
                for x in next, D[j] do if at.cells[x] then out[#out + 1] = { j, x } end end
            end
        end
        return out
    end
    local f = S.PRUNE[at.type]
    if f then f(pz, at, D, out, counts(D, n)) end
    return out
end

-- keep removals that are still in the domains, without duplicates; also a key set
local function real(D, rm)
    local out, seen = {}, {}
    for _, e in ipairs(rm) do
        local j, x = e[1], e[2]
        local key = j * 4096 + x
        if D[j][x] and not seen[key] then
            seen[key] = true
            out[#out + 1] = e
        end
    end
    return out, seen
end

local Solver = {}
Solver.__index = Solver

function St.newSolver(pz, atoms, max_whatifs)
    local n = pz.n
    local self = setmetatable({ pz = pz, n = n, max_whatifs = max_whatifs }, Solver)
    self.D0 = S.ownDomains(pz, atoms)
    local dyn, wit, ins = {}, {}, {}
    for j = 1, n do ins[j] = {} end
    for _, at in ipairs(atoms) do
        if at.type == "In" then
            table.insert(ins[at.who], at)
        else
            dyn[#dyn + 1] = at
            if at.type == "Exists" or (at.type == "AreaCount" and (at.mode == "with" or at.mode == "alonewith")
                    and not (at.cond and at.cond.t == "person")) then
                wit[#wit + 1] = at
            end
        end
    end
    self.dyn, self.witness_atoms = dyn, wit
    self.intersection = {}
    for j = 1, n do
        local us = ins[j]
        if #us >= 2 and sizeOf(self.D0[j]) <= 2 then
            local all = true
            for _, u in ipairs(us) do
                if sizeOf(S.Atom.allowed(pz, u)) < 3 then all = false; break end
            end
            if all then self.intersection[#self.intersection + 1] = j end
        end
    end
    return self
end

function Solver:whyContradiction(D)
    local pz, n = self.pz, self.n
    for j = 1, n do if next(D[j]) == nil then return { "empty", j } end end
    if pz.exact then
        local ur, uc = {}, {}
        for j = 1, n do
            for x in next, D[j] do ur[pz.row[x]] = true; uc[pz.col[x]] = true end
        end
        for r = 0, pz.H - 1 do if not ur[r] then return { "row", r } end end
        for c = 0, pz.W - 1 do if not uc[c] then return { "col", c } end end
    end
    local asg, na = {}, 0
    local sr, sc = {}, {}
    for j = 1, n do
        local x = next(D[j])
        if next(D[j], x) == nil then
            asg[j] = x
            na = na + 1
            local r, c = pz.row[x], pz.col[x]
            if sr[r] then return { "share", sr[r], j } end
            if sc[c] then return { "share", sc[c], j } end
            sr[r], sc[c] = j, j
        end
    end
    local complete = na == n
    for _, at in ipairs(self.dyn) do
        if not S.check(pz, at, asg, complete) then return { "clue", at } end
    end
    return nil
end

-- Finders: call emit(tech, rm, info); emit returns true to stop the search.
function Solver:tNaked(D, placed, emit)
    local pz, n = self.pz, self.n
    for j = 1, n do
        if not placed[j] then
            local x = next(D[j])
            if x ~= nil and next(D[j], x) == nil then
                local rm = {}
                local r, c = pz.row[x], pz.col[x]
                for k = 1, n do
                    if k ~= j then
                        for y in next, D[k] do
                            if pz.row[y] == r or pz.col[y] == c then rm[#rm + 1] = { k, y } end
                        end
                    end
                end
                if emit("naked-single", rm, { "place", j, x }) then return true end
            end
        end
    end
end

function Solver:tHidden(D, placed, emit)
    local pz, n = self.pz, self.n
    if not pz.exact then return end
    for axis = 0, 1 do
        local lineof = axis == 0 and pz.row or pz.col
        local size = axis == 0 and pz.H or pz.W
        for line = 0, size - 1 do
            local who, cnt = nil, 0
            for j = 1, n do
                for y in next, D[j] do
                    if lineof[y] == line then cnt = cnt + 1; who = j; break end
                end
                if cnt > 1 then break end
            end
            if cnt == 1 then
                local rm = {}
                for y in next, D[who] do if lineof[y] ~= line then rm[#rm + 1] = { who, y } end end
                if #rm > 0 and emit("hidden-line", rm, { "line", axis, line, who }) then return true end
            end
        end
    end
end

function Solver:tConfine(D, placed, emit)
    local pz, n = self.pz, self.n
    for j = 1, n do
        local x = next(D[j])
        if not placed[j] and x ~= nil and next(D[j], x) ~= nil then
            for axis = 0, 1 do
                local lineof = axis == 0 and pz.row or pz.col
                local line, one = lineof[x], true
                for y in next, D[j] do if lineof[y] ~= line then one = false; break end end
                if one then
                    local rm = {}
                    for k = 1, n do
                        if k ~= j then
                            for y in next, D[k] do if lineof[y] == line then rm[#rm + 1] = { k, y } end end
                        end
                    end
                    if #rm > 0 and emit("line-confine", rm, { "line", axis, line, j }) then return true end
                end
            end
        end
    end
end

function Solver:tClue(D, placed, emit, want_clash)
    local pz, n = self.pz, self.n
    for _, at in ipairs(self.dyn) do
        local rm = real(D, prune(pz, at, D, n))
        if #rm > 0 then
            pz.line_aware = false
            local ok, relaxed = pcall(prune, pz, at, D, n)
            pz.line_aware = nil
            if not ok then error(relaxed, 0) end
            local _, rset = real(D, relaxed)
            local plain, clash = {}, {}
            for _, e in ipairs(rm) do
                if rset[e[1] * 4096 + e[2]] then plain[#plain + 1] = e else clash[#clash + 1] = e end
            end
            if not want_clash and #plain > 0 then
                if emit(clueName(at), plain, { "clue", at }) then return true end
            end
            if want_clash and #clash > 0 then
                if emit("line-clash", clash, { "clue", at }) then return true end
            end
        end
    end
end

function Solver:tForcedCell(D, placed, emit)
    local pz, n = self.pz, self.n
    if not pz.exact then return end
    for axis = 0, 1 do
        local lineof = axis == 0 and pz.row or pz.col
        local other = axis == 0 and pz.col or pz.row
        local size = axis == 0 and pz.H or pz.W
        for line = 0, size - 1 do
            local cell, many = nil, false
            for j = 1, n do
                for y in next, D[j] do
                    if lineof[y] == line then
                        if cell == nil then cell = y elseif cell ~= y then many = true; break end
                    end
                end
                if many then break end
            end
            if cell ~= nil and not many then
                local rm = {}
                for k = 1, n do
                    for y in next, D[k] do
                        if other[y] == other[cell] and y ~= cell then rm[#rm + 1] = { k, y } end
                    end
                end
                if #rm > 0 and emit("forced-cell", rm, { "cell", cell, nil, axis }) then return true end
            end
        end
    end
end

function Solver:tCross(D, placed, emit)
    local pz, n = self.pz, self.n
    for j = 1, n do
        if not placed[j] then
            local dj = {}
            for y in next, D[j] do dj[#dj + 1] = y end
            if #dj >= 2 and #dj <= 8 then
                local rows, cols, nr, nc = {}, {}, 0, 0
                for _, y in ipairs(dj) do
                    if not rows[pz.row[y]] then rows[pz.row[y]] = true; nr = nr + 1 end
                    if not cols[pz.col[y]] then cols[pz.col[y]] = true; nc = nc + 1 end
                end
                if nr > 1 and nc > 1 then
                    local rl, cl = {}, {}
                    for r in pairs(rows) do rl[#rl + 1] = r end
                    for c in pairs(cols) do cl[#cl + 1] = c end
                    table.sort(rl); table.sort(cl)
                    for _, r in ipairs(rl) do
                        for _, c in ipairs(cl) do
                            local all = true
                            for _, y in ipairs(dj) do
                                if pz.row[y] ~= r and pz.col[y] ~= c then all = false; break end
                            end
                            if all then
                                local x = r * pz.W + c
                                local rm = {}
                                for k = 1, n do if k ~= j and D[k][x] then rm[#rm + 1] = { k, x } end end
                                if #rm > 0 and emit("cross-block", rm, { "cell", x, j }) then return true end
                            end
                        end
                    end
                end
            end
        end
    end
end

function Solver:tSubset(D, placed, emit)
    local pz, n = self.pz, self.n
    if not pz.exact then return end
    local free = {}
    for j = 1, n do
        local x = next(D[j])
        if not placed[j] and x ~= nil and next(D[j], x) ~= nil then free[#free + 1] = j end
    end
    for axis = 0, 1 do
        local lineof = axis == 0 and pz.row or pz.col
        local lines, nl = {}, {}
        for _, j in ipairs(free) do
            local s, k = {}, 0
            for y in next, D[j] do
                if not s[lineof[y]] then s[lineof[y]] = true; k = k + 1 end
            end
            lines[j], nl[j] = s, k
        end
        for k = 2, 3 do
            local cand = {}
            for _, j in ipairs(free) do if nl[j] <= k then cand[#cand + 1] = j end end
            local m = #cand
            local function try(combo)
                local u, nu = {}, 0
                for _, j in ipairs(combo) do
                    for l in pairs(lines[j]) do
                        if not u[l] then u[l] = true; nu = nu + 1 end
                    end
                end
                if nu ~= k then return false end
                local inC = {}
                for _, j in ipairs(combo) do inC[j] = true end
                local rm = {}
                for o = 1, n do
                    if not inC[o] then
                        for y in next, D[o] do if u[lineof[y]] then rm[#rm + 1] = { o, y } end end
                    end
                end
                if #rm == 0 then return false end
                local ul = {}
                for l in pairs(u) do ul[#ul + 1] = l end
                table.sort(ul)
                return emit("subset", rm, { "subset", axis, ul, { unpack(combo) } })
            end
            if k == 2 then
                for a = 1, m - 1 do
                    for b = a + 1, m do
                        if try({ cand[a], cand[b] }) then return true end
                    end
                end
            else
                for a = 1, m - 2 do
                    for b = a + 1, m - 1 do
                        for c = b + 1, m do
                            if try({ cand[a], cand[b], cand[c] }) then return true end
                        end
                    end
                end
            end
        end
    end
end

function Solver:tWitness(D, placed, emit)
    local pz, n = self.pz, self.n
    for _, at in ipairs(self.witness_atoms) do
        local persons, np, cells, ncell, cellOne = {}, 0, {}, 0, nil
        local personOne
        for x in next, D[at.who] do
            for j = 1, n do
                if j ~= at.who then
                    local okType
                    if at.type == "Exists" then
                        okType = at.fem == nil or pz.female[j] == at.fem
                    else
                        okType = not (at.cond and at.cond.t == "female" and pz.female[j] ~= at.cond.v)
                    end
                    if okType then
                        for y in next, D[j] do
                            local hit
                            if at.type == "Exists" then
                                hit = pz:free(x, y) and at.fn(pz, x, y) and (at.cells == nil or at.cells[y])
                            else
                                hit = pz.area[y] == pz.area[x] and pz:free(x, y)
                            end
                            if hit then
                                if not persons[j] then persons[j] = true; np = np + 1; personOne = j end
                                if not cells[y] then cells[y] = true; ncell = ncell + 1; cellOne = y end
                            end
                        end
                    end
                end
            end
        end
        if np == 1 and not placed[personOne] then
            local rm = {}
            for y in next, D[personOne] do if not cells[y] then rm[#rm + 1] = { personOne, y } end end
            if #rm > 0 and emit("witness", rm, { "who", at, personOne }) then return true end
        end
        if ncell == 1 then
            local x = cellOne
            local rm = {}
            for k = 1, n do
                for y in next, D[k] do
                    if (pz.row[y] == pz.row[x] or pz.col[y] == pz.col[x]) and y ~= x then rm[#rm + 1] = { k, y } end
                end
                if not persons[k] and D[k][x] then rm[#rm + 1] = { k, x } end
            end
            rm = real(D, rm)
            if #rm > 0 and emit("witness", rm, { "where", at, x }) then return true end
        end
    end
end

local LEVELS = {
    [0] = { "tNaked", "tHidden" },
    [1] = { "tConfine", "tClue" },
    [2] = { "tForcedCell", "tCross", "tClueClash" },
    [3] = { "tSubset", "tWitness" },
}
function Solver:tClueClash(D, placed, emit) return self:tClue(D, placed, emit, true) end

--- Moves at one level: list of {tech, rm, info}; first_only stops at the first.
function Solver:movesAt(D, placed, level, first_only)
    local out = {}
    local function emit(tech, rm, info)
        if #rm == 0 and info[1] ~= "place" then return false end
        out[#out + 1] = { tech, rm, info }
        return first_only
    end
    for _, f in ipairs(LEVELS[level]) do
        if self[f](self, D, placed, emit) then return out end
    end
    return out
end

local function apply(D, placed, mv, order)
    for _, e in ipairs(mv[2]) do D[e[1]][e[2]] = nil end
    if mv[3][1] == "place" then
        placed[mv[3][2]] = true
        if order then order[#order + 1] = mv[3][2] end
    end
end

local function copyD(D, n)
    local T = {}
    for j = 1, n do
        local t = {}
        for x in next, D[j] do t[x] = true end
        T[j] = t
    end
    return T
end

local function copyPlaced(p)
    local t = {}
    for k, v in pairs(p) do t[k] = v end
    return t
end

--- Apply moves up to maxlevel until stuck; returns nil, or depth + reason on contradiction.
function Solver:fixpoint(D, placed, maxlevel, budget)
    local k = 0
    while k < (budget or 300) do
        local why = self:whyContradiction(D)
        if why then return k, why end
        local np = 0
        for _ in pairs(placed) do np = np + 1 end
        if np == self.n then return nil end
        local moved = false
        for lv = 0, maxlevel do
            local mv = self:movesAt(D, placed, lv, true)
            if #mv > 0 then
                apply(D, placed, mv[1])
                k = k + 1
                moved = true
                break
            end
        end
        if not moved then return nil end
    end
    return nil
end

function Solver:whatIf(D, placed)
    local n = self.n
    local idx = {}
    local sz = {}
    for j = 1, n do sz[j] = sizeOf(D[j]); idx[j] = j end
    table.sort(idx, function(a, b) if sz[a] ~= sz[b] then return sz[a] < sz[b] end return a < b end)
    local cands = {}
    for _, j in ipairs(idx) do
        if sz[j] > 1 then
            local xs = {}
            for x in next, D[j] do xs[#xs + 1] = x end
            table.sort(xs)
            for _, x in ipairs(xs) do cands[#cands + 1] = { j, x } end
        end
    end
    for _, maxlevel in ipairs({ 1, 3 }) do
        local best
        for _, c in ipairs(cands) do
            local j, x = c[1], c[2]
            local T = copyD(D, n)
            T[j] = { [x] = true }
            local depth, why = self:fixpoint(T, copyPlaced(placed), maxlevel)
            if depth then
                if not best or depth < best[1] then best = { depth, j, x, why } end
                if maxlevel == 1 and depth <= 1 then break end
                if maxlevel == 3 then break end
            end
            if self.yield then self.yield() end
        end
        if best then
            local name = (maxlevel == 1 and best[1] <= 4) and "contra-short" or "contra-long"
            return { name, { { best[2], best[3] } }, { "whatif", best[2], best[3], best[1], best[4] } }
        end
    end
    return nil
end

function Solver:run()
    local n = self.n
    local D = copyD(self.D0, n)
    local placed, order, steps = {}, {}, {}
    local status, whatifs, nplaced = "stuck", 0, 0
    for _ = 1, 2000 do
        if self:whyContradiction(D) then status = "contradiction"; break end
        if nplaced == n then status = "solved"; break end
        local mv, lv, avail
        for lev = 0, 3 do
            local ms = self:movesAt(D, placed, lev, false)
            if #ms > 0 then
                mv = ms[1]
                for _, m in ipairs(ms) do if m[3][1] == "place" then mv = m; break end end
                lv, avail = lev, #ms
                break
            end
        end
        if not mv then
            whatifs = whatifs + 1
            if self.max_whatifs and whatifs > self.max_whatifs then status = "too-many-whatifs"; break end
            mv = self:whatIf(D, placed)
            if not mv then break end
            lv, avail = 4, 1
        end
        steps[#steps + 1] = { tech = mv[1], level = lv, avail = avail, info = mv[3], placed_before = nplaced, rm = mv[2] }
        apply(D, placed, mv, order)
        if mv[3][1] == "place" then nplaced = nplaced + 1 end
        if self.yield then self.yield() end
    end
    return { status = status, steps = steps, order = order, intersection = self.intersection }
end

--------------------------------------------------------------------------------
-- Profile, score, accept
--------------------------------------------------------------------------------
function St.episodes(steps, n)
    local eps, cur = {}, nil
    for i, s in ipairs(steps) do
        if s.level >= 2 then
            if not cur then
                cur = { pos = s.placed_before / n, placed = s.placed_before, key = s.tech, techs = {}, start = i, whatifs = 0 }
            end
            cur.techs[#cur.techs + 1] = s.tech
            if s.tech:sub(1, 6) == "contra" then cur.whatifs = cur.whatifs + 1 end
        elseif s.info[1] == "place" and cur then
            eps[#eps + 1] = cur
            cur = nil
        end
    end
    if cur then eps[#eps + 1] = cur end
    for _, e in ipairs(eps) do
        local k = 0
        for i = e.start + #e.techs, #steps do
            local t = steps[i]
            if t.level >= 2 then break end
            if t.info[1] == "place" then k = k + 1 end
        end
        e.cascade = k
        local named = AHA[e.key]
        e.aha_key = named and e.key or nil
        for _, t in ipairs(e.techs) do
            if t == "witness" or t == "subset" then named = true end
            if not e.aha_key and AHA[t] then e.aha_key = t end
        end
        e.aha_key = e.aha_key or e.key
        e.aha = (named and true or false) and e.whatifs <= 3
    end
    return eps
end

function St.profile(pz, atoms, max_whatifs, yield)
    local sv = St.newSolver(pz, atoms, max_whatifs)
    sv.yield = yield
    local R = sv:run()
    local n = pz.n
    local techs = {}
    for _, s in ipairs(R.steps) do techs[s.tech] = (techs[s.tech] or 0) + 1 end
    local eps = St.episodes(R.steps, n)
    local P = { status = R.status, steps = R.steps, episodes = eps, order = R.order, intersection = R.intersection,
        techs = techs, n_aha = 0, aha_mid = 0, max_cascade = 0, whatifs = 0, aha_keys = {} }
    for _, e in ipairs(eps) do
        if e.aha then
            P.n_aha = P.n_aha + 1
            P.aha_keys[#P.aha_keys + 1] = e.aha_key
            if e.pos >= 0.15 and e.pos <= 0.8 then P.aha_mid = P.aha_mid + 1 end
            if e.cascade > P.max_cascade then P.max_cascade = e.cascade end
        end
    end
    P.whatifs = (techs["contra-short"] or 0) + (techs["contra-long"] or 0)
    P.n_long = techs["contra-long"] or 0
    local o = R.order
    P.victim_late = o[#o] == pz.victim or o[#o - 1] == pz.victim
    local nok = 0
    for x = 0, pz.ncell - 1 do if pz.ok[x] then nok = nok + 1 end end
    local d0, givens = 0, 0
    for j = 1, n - 1 do
        local s = sizeOf(sv.D0[j])
        d0 = d0 + s / nok
        if s == 1 then givens = givens + 1 end
    end
    P.d0, P.givens = d0 / (n - 1), givens
    return P
end

function St.midAhas(P, min_cascade)
    local out = {}
    for _, e in ipairs(P.episodes) do
        if e.aha and e.pos >= 0.15 and e.pos <= 0.8 and e.cascade >= (min_cascade or 2) then out[#out + 1] = e end
    end
    return out
end

function St.funScore(P, whatif_penalty)
    if P.status ~= "solved" then return -10 end
    local s = 2 * math.min(P.aha_mid, 2) + 0.5 * math.min(P.n_aha - P.aha_mid, 2)
    s = s + 0.25 * math.min(P.max_cascade, 4)
    if P.victim_late then s = s + 1 end
    if #P.intersection > 0 then s = s + 0.5 end
    if whatif_penalty then
        s = s - 0.15 * math.max(0, P.whatifs - 3) - math.min(P.n_long, 4)
    end
    return math.max(s, -5)
end

function St.accept(P, gr, target)
    if P.status ~= "solved" or not P.victim_late then return false end
    if target ~= "any" and gr ~= target then return false end
    if target ~= "hard" and (P.whatifs > St.MAX_WHATIFS or P.n_long > 0) then return false end
    return #St.midAhas(P) > 0
end

function St.objective(P, gr, target)
    if P.status ~= "solved" then return -99 end
    local hard = target == "hard"
    local sc = St.funScore(P, not hard)
    sc = sc + 10 * math.min(P.d0, 0.35) - P.givens
    if not hard and P.whatifs > St.MAX_WHATIFS then sc = sc - 2 - 0.3 * P.whatifs end
    for _, e in ipairs(St.midAhas(P)) do
        if e.aha_key ~= "contra-short" then sc = sc + 1; break end
    end
    local gi, ti = S.GRADE_INDEX[gr], S.GRADE_INDEX[target]
    if gi and ti then sc = sc - 3 * math.abs(gi - ti) end
    return sc
end

return St
