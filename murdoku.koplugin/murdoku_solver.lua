--[[--
Murdoku logic core (pure Lua, no KOReader dependencies): puzzle model, clue
atoms, a solution counter and a human-style logical solver used for grading.
A port of tools/generator/mgen/{model,solver}.py.

Conventions: cells are 0-based integers x = r * W + c; people are 1-based
(the victim is the last one). A domain D[j] is a table { [x] = true } with its
size kept in Dn[j].

Difficulty = number of eliminations that needed a one-level "what if" test:
very-easy 0, easy 1-3, medium 4-15, hard 16+.
--]]

local OBJECTS = require("murdoku_objects")

local S = {}

-- Domains are sets { [x] = true }; dom(d) iterates them, first(d) returns one.
local function dom(d) return next, d, nil end
local function first(d) return (next(d)) end
local function newDomain() return {} end
S.dom = dom

local function standable(id)
    if not id or id == 0 then return true end
    if id == 8 or id == 33 then return false end
    local o = OBJECTS[id]
    if not o then return true end
    return o.occupiable == true
end
S.standable = standable

-- Multi-cell objects (same rule as murdoku_puzzle.lua).
S.RIGHT1 = { [6] = true, [119] = true, [21] = true, [22] = true, [90] = true }

--------------------------------------------------------------------------------
-- Puzzle model
--------------------------------------------------------------------------------
local Puzzle = {}
Puzzle.__index = Puzzle

--- area/obj/carpet: flat 0-based arrays (obj already expanded).
function S.newPuzzle(H, W, area, obj, carpet, names, female, room_names, sol, murderer)
    local pz = setmetatable({
        H = H, W = W, n = #names, ncell = H * W,
        area = area, obj = obj, carpet = carpet,
        names = names, female = female, room_names = room_names,
        sol = sol, murderer = murderer,
        row = {}, col = {}, ok = {}, nbrs = {}, areas = {}, area_cells = {}, _cache = {},
    }, Puzzle)
    pz.victim = pz.n
    pz.exact = (pz.n == H and pz.n == W)
    local seen = {}
    for x = 0, pz.ncell - 1 do
        local r, c = math.floor(x / W), x % W
        pz.row[x], pz.col[x] = r, c
        pz.ok[x] = standable(obj[x]) or nil
        local a = area[x]
        if not seen[a] then
            seen[a] = true
            table.insert(pz.areas, a)
            pz.area_cells[a] = {}
        end
        pz.area_cells[a][x] = true
        local nb = {}
        if r > 0 then nb[#nb + 1] = x - W end
        if r < H - 1 then nb[#nb + 1] = x + W end
        if c > 0 then nb[#nb + 1] = x - 1 end
        if c < W - 1 then nb[#nb + 1] = x + 1 end
        pz.nbrs[x] = nb
    end
    table.sort(pz.areas)
    return pz
end

-- line_aware = false: two-person pruning ignores "nobody shares a row/column"
-- (the step solver toggles it to recognise "line-clash" deductions).
function Puzzle:free(x, y)
    if self.line_aware == false then return true end
    return self.row[x] ~= self.row[y] and self.col[x] ~= self.col[y]
end

-- Object name of an id, lowercased ("carpet" for carpets).
local function objName(id)
    local o = OBJECTS[id]
    return o and o.name:lower() or nil
end
S.objName = objName

--- Cells holding an object named `word` (any covered cell), or carpets.
function Puzzle:objCells(word)
    local key = "obj:" .. word
    if not self._cache[key] then
        local s = {}
        for x = 0, self.ncell - 1 do
            if word == "carpet" then
                if self.carpet[x] or self.obj[x] == 5 then s[x] = true end
            elseif self.obj[x] ~= 0 and objName(self.obj[x]) == word then
                s[x] = true
            end
        end
        self._cache[key] = s
    end
    return self._cache[key]
end

function Puzzle:onSet(word)
    local key = "on:" .. word
    if not self._cache[key] then
        local s = {}
        for x in pairs(self:objCells(word)) do
            if self.ok[x] then s[x] = true end
        end
        self._cache[key] = s
    end
    return self._cache[key]
end

function Puzzle:besideSet(word)
    local key = "beside:" .. word
    if not self._cache[key] then
        local src = self:objCells(word)
        local s = {}
        for x = 0, self.ncell - 1 do
            if self.ok[x] then
                for _, y in ipairs(self.nbrs[x]) do
                    if src[y] and self.area[y] == self.area[x] then s[x] = true; break end
                end
            end
        end
        self._cache[key] = s
    end
    return self._cache[key]
end

function Puzzle:areaSet(list)
    local s = {}
    for _, a in ipairs(list) do
        for x in pairs(self.area_cells[a] or {}) do
            if self.ok[x] then s[x] = true end
        end
    end
    return s
end

function Puzzle:rowSet(r)
    local s = {}
    for c = 0, self.W - 1 do
        local x = r * self.W + c
        if self.ok[x] then s[x] = true end
    end
    return s
end

function Puzzle:colSet(c)
    local s = {}
    for r = 0, self.H - 1 do
        local x = r * self.W + c
        if self.ok[x] then s[x] = true end
    end
    return s
end

--- Squares with a wall (area border or scene edge) on two sides that meet.
function Puzzle:cornerSet()
    if not self._cache.corner then
        local s = {}
        for x = 0, self.ncell - 1 do
            if self.ok[x] then
                local r, c = self.row[x], self.col[x]
                local function wall(dr, dc)
                    local rr, cc = r + dr, c + dc
                    return rr < 0 or rr >= self.H or cc < 0 or cc >= self.W
                        or self.area[rr * self.W + cc] ~= self.area[x]
                end
                if (wall(-1, 0) or wall(1, 0)) and (wall(0, -1) or wall(0, 1)) then s[x] = true end
            end
        end
        self._cache.corner = s
    end
    return self._cache.corner
end

function Puzzle:pron(j)
    if self.female[j] then return "She", "her", "her" end
    return "He", "him", "his"
end

--------------------------------------------------------------------------------
-- Atoms
--------------------------------------------------------------------------------
local function allPeople(pz)
    local t = {}
    for j = 1, pz.n do t[j] = j end
    return t
end

local function match(pz, j, x, cond)
    if not cond then return true end
    if cond.t == "person" then return j == cond.v end
    if cond.t == "female" then return pz.female[j] == cond.v end
    if cond.t == "cells" then return cond.v[x] == true end
    error("bad cond")
end

local function typeOk(pz, j, cond)
    return cond == nil or (cond.t == "female" and pz.female[j] == cond.v) or (cond.t == "person" and j == cond.v)
end

local function forcedArea(pz, Dj)
    local a
    for x in dom(Dj) do
        if a == nil then a = pz.area[x]
        elseif pz.area[x] ~= a then return nil end
    end
    return a
end

local function could(pz, D, j, cells, cond, x)
    if cond and cond.t == "person" and cond.v ~= j then return false end
    if cond and cond.t == "female" and pz.female[j] ~= cond.v then return false end
    for y in dom(D[j]) do
        if cells[y] and pz:free(x, y) and (not cond or cond.t ~= "cells" or cond.v[y]) then return true end
    end
    return false
end

local A = {}
S.Atom = A

--- Owner stands in `cells` (or outside them with neg).
function A.In(who, cells, neg, positional)
    return { type = "In", who = who, cells = cells, neg = neg or false, positional = positional or false, unary = true }
end

function A.allowed(pz, at)
    local s = {}
    for x = 0, pz.ncell - 1 do
        if pz.ok[x] and ((at.cells[x] == true) ~= at.neg) then s[x] = true end
    end
    return s
end

--- Nobody but the owner (and the exempt people) stands in `cells`.
function A.Only(who, cells, exempt)
    local ex = {}
    for _, j in ipairs(exempt or {}) do ex[j] = true end
    return { type = "Only", who = who, cells = cells, exempt = ex }
end

function A.AreaCount(who, mode, cond)
    return { type = "AreaCount", who = who, mode = mode, cond = cond }
end

local REL = {
    north = function(pz, a, b) return pz.row[a] < pz.row[b] end,
    south = function(pz, a, b) return pz.row[a] > pz.row[b] end,
    west = function(pz, a, b) return pz.col[a] < pz.col[b] end,
    east = function(pz, a, b) return pz.col[a] > pz.col[b] end,
    samearea = function(pz, a, b) return pz.area[a] == pz.area[b] end,
}
local function relFn(kind, k)
    if kind == "rows" then return function(pz, a, b) return pz.row[a] - pz.row[b] == k end end
    if kind == "cols" then return function(pz, a, b) return pz.col[a] - pz.col[b] == k end end
    return assert(REL[kind], kind)
end

function A.Rel(who, other, kind, k)
    return { type = "Rel", who = who, other = other, kind = kind, k = k, fn = relFn(kind, k), positional = true }
end

function A.Exists(who, kind, cells, fem, k)
    return { type = "Exists", who = who, kind = kind, cells = cells, fem = fem, k = k, fn = relFn(kind, k) }
end

function A.Count(cells, lo, hi)
    return { type = "Count", cells = cells, lo = lo, hi = hi, global = true }
end

function A.NoEmptyArea() return { type = "NoEmptyArea", global = true } end
function A.NoLoner() return { type = "NoLoner", global = true } end

local function involves(pz, at)
    if at.type == "Rel" then return { at.who, at.other } end
    if at.type == "In" then return { at.who } end
    return allPeople(pz)
end

-- check(pz, at, asg, complete): asg = { [j] = cell } for placed people
local CHECK = {}
function CHECK.Only(pz, at, asg)
    for j = 1, pz.n do
        local x = asg[j]
        if x and j ~= at.who and not at.exempt[j] and at.cells[x] then return false end
    end
    return true
end
function CHECK.AreaCount(pz, at, asg, complete)
    local me = asg[at.who]
    if me == nil then return true end
    local area = pz.area
    local a = area[me]
    local m, cond = at.mode, at.cond
    local nothers, oj, ox = 0, nil, nil
    local matched = false
    for j = 1, pz.n do
        local x = asg[j]
        if x and j ~= at.who and area[x] == a then
            nothers = nothers + 1
            oj, ox = j, x
            if m == "alone" then return false end
            if match(pz, j, x, cond) then
                matched = true
                if m == "none" then return false end
            end
        end
    end
    if m == "alone" or m == "none" then return true end
    if m == "alonewith" then
        if nothers > 1 then return false end
        if nothers == 1 and not match(pz, oj, ox, cond) then return false end
        if cond and cond.t == "person" and asg[cond.v] and area[asg[cond.v]] ~= a then return false end
        if complete then return nothers == 1 end
        return true
    end
    if m == "with" then
        if cond and cond.t == "person" and asg[cond.v] then return matched end
        if complete then return matched end
        return true
    end
    error("bad mode " .. tostring(m))
end
function CHECK.Rel(pz, at, asg)
    local a, b = asg[at.who], asg[at.other]
    if a == nil or b == nil then return true end
    return at.fn(pz, a, b)
end
function CHECK.Exists(pz, at, asg, complete)
    local me = asg[at.who]
    if me == nil or not complete then return true end
    for j = 1, pz.n do
        local y = asg[j]
        if y and j ~= at.who and (at.fem == nil or pz.female[j] == at.fem) and at.fn(pz, me, y)
                and (at.cells == nil or at.cells[y]) then
            return true
        end
    end
    return false
end
function CHECK.Count(pz, at, asg, complete)
    local k = 0
    for j = 1, pz.n do
        local x = asg[j]
        if x and at.cells[x] then k = k + 1 end
    end
    if k > at.hi then return false end
    if complete then return k >= at.lo end
    return true
end
function CHECK.NoEmptyArea(pz, at, asg, complete)
    if not complete then return true end
    local used, n = {}, 0
    for j = 1, pz.n do
        local x = asg[j]
        if x and not used[pz.area[x]] then used[pz.area[x]] = true; n = n + 1 end
    end
    return n == #pz.areas
end
function CHECK.NoLoner(pz, at, asg, complete)
    if not complete then return true end
    local cnt = {}
    for j = 1, pz.n do
        local x = asg[j]
        if x then cnt[pz.area[x]] = (cnt[pz.area[x]] or 0) + 1 end
    end
    for _, k in pairs(cnt) do if k == 1 then return false end end
    return true
end
function CHECK.In() return true end

-- prune(pz, at, D, out): append {j, x} eliminations to out
local PRUNE = {}
function PRUNE.AreaCount(pz, at, D, out)
    local w, m, cond = at.who, at.mode, at.cond
    local forced = {}
    for j = 1, pz.n do forced[j] = forcedArea(pz, D[j]) end
    for x in dom(D[w]) do
        local a = pz.area[x]
        local ac = pz.area_cells[a]
        local must = {}
        for j = 1, pz.n do
            if j ~= w and forced[j] == a then must[#must + 1] = j end
        end
        local drop = false
        if m == "alone" then
            drop = #must > 0
        elseif m == "alonewith" then
            if #must > 1 then
                drop = true
            else
                for _, j in ipairs(must) do
                    if not (typeOk(pz, j, cond) or cond.t == "cells") then drop = true end
                end
                if not drop then
                    local any = false
                    for j = 1, pz.n do
                        if j ~= w and could(pz, D, j, ac, cond, x) then any = true; break end
                    end
                    drop = not any
                end
            end
        elseif m == "with" then
            local any = false
            for j = 1, pz.n do
                if j ~= w and could(pz, D, j, ac, cond, x) then any = true; break end
            end
            drop = not any
        elseif m == "none" then
            for _, j in ipairs(must) do
                if cond and cond.t ~= "cells" and typeOk(pz, j, cond) then drop = true end
            end
        end
        if drop then out[#out + 1] = { w, x } end
    end
    local fa = forced[w]
    if fa ~= nil then
        local ac = pz.area_cells[fa]
        for j = 1, pz.n do
            if j ~= w then
                local inside, outside = false, false
                if m == "alone" or (m == "none" and cond and cond.t ~= "cells" and typeOk(pz, j, cond)) then
                    inside = true
                elseif m == "alonewith" and cond and cond.t == "person" then
                    if j == cond.v then outside = true else inside = true end
                elseif m == "alonewith" and cond and cond.t == "female" and pz.female[j] ~= cond.v then
                    inside = true
                elseif m == "with" and cond and cond.t == "person" and j == cond.v then
                    outside = true
                end
                if inside or outside then
                    for y in dom(D[j]) do
                        if (ac[y] == true) == inside then out[#out + 1] = { j, y } end
                    end
                end
            end
        end
        if m == "alonewith" then
            local must = {}
            local nmust = 0
            for j = 1, pz.n do
                if j ~= w and forced[j] == fa then must[j] = true; nmust = nmust + 1 end
            end
            if nmust > 0 then
                for j = 1, pz.n do
                    if j ~= w and not must[j] then
                        for y in dom(D[j]) do
                            if ac[y] then out[#out + 1] = { j, y } end
                        end
                    end
                end
            end
        end
    end
end
function PRUNE.Rel(pz, at, D, out)
    local fn = at.fn
    for a in dom(D[at.who]) do
        local ok = false
        for b in dom(D[at.other]) do
            if pz:free(a, b) and fn(pz, a, b) then ok = true; break end
        end
        if not ok then out[#out + 1] = { at.who, a } end
    end
    for b in dom(D[at.other]) do
        local ok = false
        for a in dom(D[at.who]) do
            if pz:free(a, b) and fn(pz, a, b) then ok = true; break end
        end
        if not ok then out[#out + 1] = { at.other, b } end
    end
end
function PRUNE.Exists(pz, at, D, out)
    for x in dom(D[at.who]) do
        local ok = false
        for j = 1, pz.n do
            if j ~= at.who and (at.fem == nil or pz.female[j] == at.fem) then
                for y in dom(D[j]) do
                    if pz:free(x, y) and at.fn(pz, x, y) and (at.cells == nil or at.cells[y]) then ok = true; break end
                end
            end
            if ok then break end
        end
        if not ok then out[#out + 1] = { at.who, x } end
    end
end
function PRUNE.Count(pz, at, D, out, Dn)
    local placed, nplaced = {}, 0
    for j = 1, pz.n do
        if Dn[j] == 1 then
            local x = first(D[j])
            if at.cells[x] then placed[j] = true; nplaced = nplaced + 1 end
        end
    end
    if nplaced >= at.hi then
        for j = 1, pz.n do
            if not placed[j] then
                for x in dom(D[j]) do if at.cells[x] then out[#out + 1] = { j, x } end end
            end
        end
    end
    local can = {}
    for j = 1, pz.n do
        for x in dom(D[j]) do if at.cells[x] then can[#can + 1] = j; break end end
    end
    if #can <= at.lo then
        for _, j in ipairs(can) do
            for x in dom(D[j]) do if not at.cells[x] then out[#out + 1] = { j, x } end end
        end
    end
end
function PRUNE.NoEmptyArea(pz, at, D, out)
    for _, a in ipairs(pz.areas) do
        local can, nc = nil, 0
        for j = 1, pz.n do
            for x in dom(D[j]) do
                if pz.area[x] == a then nc = nc + 1; can = j; break end
            end
            if nc > 1 then break end
        end
        if nc == 1 then
            for x in dom(D[can]) do if pz.area[x] ~= a then out[#out + 1] = { can, x } end end
        end
    end
end
function PRUNE.NoLoner(pz, at, D, out)
    for j = 1, pz.n do
        for x in dom(D[j]) do
            local a = pz.area[x]
            local ok = false
            for k = 1, pz.n do
                if k ~= j then
                    for y in dom(D[k]) do
                        if pz.area[y] == a and pz:free(x, y) then ok = true; break end
                    end
                end
                if ok then break end
            end
            if not ok then out[#out + 1] = { j, x } end
        end
    end
end

local function check(pz, at, asg, complete) return CHECK[at.type](pz, at, asg, complete) end
S.check = check
S.PRUNE = PRUNE

--------------------------------------------------------------------------------
-- Domains
--------------------------------------------------------------------------------
local function size(t)
    local k = 0
    for _, v in pairs(t) do if v == true then k = k + 1 end end
    return k
end
S.size = size

--- Domains from each person's own unary atoms only.
function S.ownDomains(pz, atoms)
    local D = {}
    for j = 1, pz.n do
        D[j] = newDomain()
        for x = 0, pz.ncell - 1 do if pz.ok[x] then D[j][x] = true end end
    end
    for _, at in ipairs(atoms) do
        if at.type == "In" then
            local Dj = D[at.who]
            for x in dom(Dj) do
                if (at.cells[x] == true) == at.neg then Dj[x] = nil end
            end
        end
    end
    return D
end

local function baseDomains(pz, atoms, events)
    local D = S.ownDomains(pz, atoms)
    for _, at in ipairs(atoms) do
        if at.type == "Only" then
            local hit = {}
            for j = 1, pz.n do
                if j ~= at.who and not at.exempt[j] then
                    local any = false
                    for x in dom(D[j]) do
                        if at.cells[x] then D[j][x] = nil; any = true end
                    end
                    if any then hit[#hit + 1] = j end
                end
            end
            if events and #hit > 0 then events[#events + 1] = { "clue", at, hit } end
        end
    end
    local Dn = {}
    for j = 1, pz.n do Dn[j] = size(D[j]) end
    return D, Dn
end

local function dynamicAtoms(atoms)
    local out = {}
    for _, at in ipairs(atoms) do
        if at.type ~= "In" and at.type ~= "Only" then out[#out + 1] = at end
    end
    return out
end

--------------------------------------------------------------------------------
-- Solution counter
--------------------------------------------------------------------------------
--- Returns count (up to limit), solutions (list of {cells by person}), timed_out.
function S.countSolutions(pz, atoms, limit, node_limit)
    limit = limit or 2
    node_limit = node_limit or 300000
    local D = baseDomains(pz, atoms)
    local dyn = dynamicAtoms(atoms)
    local by = {}
    for j = 1, pz.n do by[j] = {} end
    for _, at in ipairs(dyn) do
        local seen = {}
        for _, j in ipairs(involves(pz, at)) do
            if not seen[j] then seen[j] = true; table.insert(by[j], at) end
        end
    end
    local list = {}
    for j = 1, pz.n do
        list[j] = {}
        for x = 0, pz.ncell - 1 do if D[j][x] then table.insert(list[j], x) end end
    end
    local sols, asg, nasg = {}, {}, 0
    local used_r, used_c = {}, {}
    for k = 0, math.max(pz.H, pz.W) do used_r[k] = false; used_c[k] = false end
    local nodes, stop = 0, false
    local row, col, n = pz.row, pz.col, pz.n
    local function rec()
        if stop then return end
        nodes = nodes + 1
        if nodes > node_limit then stop = true; return end
        if nasg == n then
            for _, at in ipairs(dyn) do
                if not check(pz, at, asg, true) then return end
            end
            local s = {}
            for j = 1, n do s[j] = asg[j] end
            sols[#sols + 1] = s
            if #sols >= limit then stop = true end
            return
        end
        local best, bestn = nil, math.huge
        for j = 1, n do
            if asg[j] == nil then
                local k = 0
                local lj = list[j]
                for t = 1, #lj do
                    local x = lj[t]
                    if not used_r[row[x]] and not used_c[col[x]] then k = k + 1 end
                end
                if k < bestn then
                    best, bestn = j, k
                    if k == 0 then return end
                end
            end
        end
        local lb = list[best]
        local cand = {}
        for t = 1, #lb do
            local x = lb[t]
            if not used_r[row[x]] and not used_c[col[x]] then cand[#cand + 1] = x end
        end
        local checks = by[best]
        for t = 1, #cand do
            local x = cand[t]
            asg[best] = x; nasg = nasg + 1
            used_r[row[x]] = true; used_c[col[x]] = true
            local ok = true
            for q = 1, #checks do
                if not check(pz, checks[q], asg, false) then ok = false; break end
            end
            if ok then rec() end
            used_r[row[x]] = false; used_c[col[x]] = false
            asg[best] = nil; nasg = nasg - 1
            if stop then return end
        end
    end
    rec()
    return #sols, sols, nodes > node_limit, nodes
end

--------------------------------------------------------------------------------
-- Logical solver
--------------------------------------------------------------------------------
-- A contradiction is raised with error({ contradiction = why }) where why is
-- { "empty", j } | { "row", r } | { "col", c } | { "clue", atom }.
local function contra(why) error({ contradiction = why }, 0) end

local function remove(D, Dn, j, x)
    if D[j][x] then D[j][x] = nil; Dn[j] = Dn[j] - 1; return true end
    return false
end

local function propagate(pz, D, Dn, dyn, events, placed)
    local n, row, col = pz.n, pz.row, pz.col
    local changed = true
    while changed do
        changed = false
        for j = 1, n do
            if Dn[j] == 0 then contra({ "empty", j }) end
            if Dn[j] == 1 and not placed[j] then
                placed[j] = true
                local x = first(D[j])
                for k = 1, n do
                    if k ~= j then
                        for y in dom(D[k]) do
                            if row[y] == row[x] or col[y] == col[x] then
                                remove(D, Dn, k, y); changed = true
                            end
                        end
                    end
                end
                if events then events[#events + 1] = { "place", j, x } end
            end
        end
        if not changed then
            local asg, na = {}, 0
            for j = 1, n do
                if Dn[j] == 1 then asg[j] = first(D[j]); na = na + 1 end
            end
            for _, at in ipairs(dyn) do
                if not check(pz, at, asg, na == n) then contra({ "clue", at }) end
            end
            if pz.exact then
                -- hidden singles: a row/column only one person can still use
                for axis = 0, 1 do
                    local lineof = axis == 0 and row or col
                    local nlines = axis == 0 and pz.H or pz.W
                    for line = 0, nlines - 1 do
                        local who, nwho = nil, 0
                        for j = 1, n do
                            for y in dom(D[j]) do
                                if lineof[y] == line then who = j; nwho = nwho + 1; break end
                            end
                            if nwho > 1 then break end
                        end
                        if nwho == 0 then contra({ axis == 0 and "row" or "col", line }) end
                        if nwho == 1 then
                            local any = false
                            for y in dom(D[who]) do
                                if lineof[y] ~= line then remove(D, Dn, who, y); any = true end
                            end
                            if any then
                                changed = true
                                if events then events[#events + 1] = { "hidden", who, axis, line } end
                            end
                        end
                    end
                    if changed then break end
                end
                if not changed then
                    -- pairs: two people confined to the same two lines
                    for axis = 0, 1 do
                        local lineof = axis == 0 and row or col
                        local groups = {}
                        for j = 1, n do
                            if Dn[j] > 1 then
                                local l1, l2, more = nil, nil, false
                                for y in dom(D[j]) do
                                    local l = lineof[y]
                                    if l1 == nil or l == l1 then l1 = l
                                    elseif l2 == nil or l == l2 then l2 = l
                                    else more = true; break end
                                end
                                if l2 and not more then
                                    local key = math.min(l1, l2) * 100 + math.max(l1, l2)
                                    groups[key] = groups[key] or {}
                                    table.insert(groups[key], j)
                                end
                            end
                        end
                        for key, js in pairs(groups) do
                            if #js == 2 then
                                local la, lb = math.floor(key / 100), key % 100
                                local hit = {}
                                for k = 1, n do
                                    if k ~= js[1] and k ~= js[2] then
                                        local any = false
                                        for y in dom(D[k]) do
                                            if lineof[y] == la or lineof[y] == lb then remove(D, Dn, k, y); any = true end
                                        end
                                        if any then hit[#hit + 1] = k end
                                    end
                                end
                                if #hit > 0 then
                                    changed = true
                                    if events then events[#events + 1] = { "pair", axis, { la, lb }, js, hit } end
                                end
                            end
                        end
                        if changed then break end
                    end
                end
            end
            if not changed then
                for _, at in ipairs(dyn) do
                    local prune = PRUNE[at.type]
                    if prune then
                        local rm = {}
                        prune(pz, at, D, rm, Dn)
                        local hit, hitset = {}, {}
                        for _, e in ipairs(rm) do
                            if remove(D, Dn, e[1], e[2]) and not hitset[e[1]] then
                                hitset[e[1]] = true
                                hit[#hit + 1] = e[1]
                            end
                        end
                        if #hit > 0 then
                            changed = true
                            if events then
                                table.sort(hit)
                                events[#events + 1] = { "clue", at, hit }
                            end
                            break
                        end
                    end
                end
            end
        end
    end
    local all = true
    for j = 1, n do if Dn[j] ~= 1 then all = false; break end end
    if all then
        local asg = {}
        for j = 1, n do asg[j] = first(D[j]) end
        for _, at in ipairs(dyn) do
            if not check(pz, at, asg, true) then contra({ "clue", at }) end
        end
    end
end

local function copyDomains(D, Dn, n)
    local T, Tn = {}, {}
    for j = 1, n do
        local t = {}
        for x in next, D[j] do t[x] = true end
        T[j], Tn[j] = t, Dn[j]
    end
    return T, Tn
end

local function copySet(s)
    local t = {}
    for k, v in pairs(s) do t[k] = v end
    return t
end

local function sortedCells(Dj)
    local t = {}
    for x in dom(Dj) do t[#t + 1] = x end
    table.sort(t)
    return t
end

--- Logical solve. Returns { solved, trials, events, order, D }.
-- opts.events (bool) records a trace; opts.yield (function) is called now and
-- then so a caller can time-slice; opts.max_trials stops early.
function S.logicSolve(pz, atoms, opts)
    opts = opts or {}
    local events = opts.events and {} or nil
    local D, Dn = baseDomains(pz, atoms, events)
    local dyn = dynamicAtoms(atoms)
    local placed, trials = {}, 0
    local order = {}
    local function result(solved)
        if events then
            for _, e in ipairs(events) do if e[1] == "place" then order[#order + 1] = e[2] end end
        end
        return { solved = solved, trials = trials, events = events or {}, order = order, D = D, Dn = Dn }
    end
    local ok, err = pcall(propagate, pz, D, Dn, dyn, events, placed)
    if not ok then
        if type(err) == "table" and err.contradiction then return result(false) end
        error(err, 0)
    end
    local rounds = 0
    local function done()
        for j = 1, pz.n do if Dn[j] ~= 1 then return false end end
        return true
    end
    while not done() and rounds < 400 do
        rounds = rounds + 1
        if opts.yield then opts.yield() end
        if opts.max_trials and trials > opts.max_trials then break end
        local progress = false
        local idx = {}
        for j = 1, pz.n do idx[j] = j end
        table.sort(idx, function(a, b)
            if Dn[a] ~= Dn[b] then return Dn[a] < Dn[b] end
            return a < b
        end)
        for _, j in ipairs(idx) do
            if Dn[j] > 1 then
                for _, x in ipairs(sortedCells(D[j])) do
                    local T, Tn = copyDomains(D, Dn, pz.n)
                    T[j] = newDomain()
                    T[j][x] = true
                    Tn[j] = 1
                    local tok, terr = pcall(propagate, pz, T, Tn, dyn, nil, copySet(placed))
                    if not tok then
                        if type(terr) ~= "table" or not terr.contradiction then error(terr, 0) end
                        remove(D, Dn, j, x)
                        trials = trials + 1
                        if events then events[#events + 1] = { "trial", j, x, terr.contradiction } end
                        progress = true
                        break
                    end
                end
                if progress then break end
            end
        end
        if not progress then break end
        ok, err = pcall(propagate, pz, D, Dn, dyn, events, placed)
        if not ok then
            if type(err) == "table" and err.contradiction then return result(false) end
            error(err, 0)
        end
    end
    -- the order is needed even without a full trace
    if not events then
        -- cheap re-derivation: people in increasing order of when they became single is not
        -- tracked without events; callers that need the order ask for events.
    end
    return result(done())
end

S.GRADES = { "very-easy", "easy", "medium", "hard" }
S.GRADE_INDEX = { ["very-easy"] = 1, easy = 2, medium = 3, hard = 4 }

function S.grade(res)
    if not res.solved then return "needs-guessing" end
    local t = res.trials
    if t == 0 then return "very-easy" end
    if t <= 3 then return "easy" end
    if t <= 15 then return "medium" end
    return "hard"
end

return S
