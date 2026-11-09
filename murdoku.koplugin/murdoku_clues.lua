--[[--
True clue sentences for a known solution (pure Lua). Each clue is English text
plus the atoms it means. Port of tools/generator/mgen/clues.py; the sentence
templates are identical so tools/generator --check can verify Lua output too.
--]]

local S = require("murdoku_solver")
local T = require("murdoku_themes")
local A = S.Atom

local C = {}

local ORD = { [0] = "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth" }
local NUM = { [0] = "zero", "one", "two", "three", "four", "five", "six", "seven", "eight" }
local POSITIONAL = { row = true, col = true, compass = true, offset = true }
C.STRONG = { on = true, onroom = true, onlyon = true, beside2 = true, besideroom = true, onlybeside = true,
    onlygender = true, alonewith = true }
C.WEAK = { orroom = true, notroom = true, noton = true, notbeside = true, notwith = true, nogender = true,
    existsg = true, compass = true, with = true, exists = true, samearea = true, withg = true }
C.KIND_W = {
    area = 3, orroom = 1.5, notroom = 1, on = 4, onroom = 2, noton = 0.8, onlyon = 2.5,
    beside = 4, beside2 = 2, besideroom = 1.5, notbeside = 1.5, onlybeside = 1.5,
    alone = 2, aloneroom = 1.5, alonewith = 1.5, alonewithg = 1.5, with = 1.5, notwith = 0.7,
    nogender = 1, onlygender = 1.2, exists = 1.5, existsg = 1, corner = 1,
    row = 0.6, col = 0.6, compass = 0.5, offset = 0.4,
    samearea = 1.2, rowof = 0.8, withg = 1.0,
    victim = 0,
}

local WORD_OF = {}
for w, id in pairs(T.obj_id) do WORD_OF[id] = (w == "bed-v") and "bed" or w end
function C.objWord(id) return WORD_OF[id] end

local function newClue(kind, atoms, text, who)
    local c = { kind = kind, atoms = atoms, text = text, who = who, positional = POSITIONAL[kind] or false }
    for _, a in ipairs(atoms) do a.src = c end
    return c
end
C.newClue = newClue

--- English helpers around a puzzle + anchor grid (0-based flat array of anchor ids).
function C.newCtx(pz, anchors)
    local g = { pz = pz, sol = pz.sol, count = {}, words = {} }
    for x = 0, pz.ncell - 1 do
        local w = WORD_OF[anchors[x]]
        if w then g.count[w] = (g.count[w] or 0) + 1 end
    end
    for w in pairs(g.count) do table.insert(g.words, w) end
    table.sort(g.words)
    for x = 0, pz.ncell - 1 do
        if pz.carpet[x] then table.insert(g.words, "carpet"); break end
    end
    return g
end

local function noun(w) return T.noun[w] or w end

local function art(g, w, only)
    local n = noun(w)
    if T.mass[w] then return "some " .. n end
    if w == "water" then return "the water" end
    if w ~= "carpet" and g.count[w] == 1 and not only then return "the " .. n end
    return (n:sub(1, 1):lower():match("[aeiou]") and "an " or "a ") .. n
end
C.art = art

local function onPhrase(g, w) return T.on_verb[w] .. " " .. art(g, w) end

local function wordAt(g, x)
    local pz = g.pz
    local w = WORD_OF[pz.obj[x]]
    if w and T.on_verb[w] then return w end
    if pz.carpet[x] then return "carpet" end
    return nil
end

local function besideWords(g, x)
    local pz = g.pz
    local set, out = {}, {}
    for _, y in ipairs(pz.nbrs[x]) do
        local w = WORD_OF[pz.obj[y]]
        if w and not T.on_verb[w] and pz.area[y] == pz.area[x] then set[w] = true end
    end
    for w in pairs(set) do out[#out + 1] = w end
    table.sort(out)
    return out
end

local function trueForOthers(pz, i, cells)
    for j = 1, pz.n do
        if j ~= i and cells[pz.sol[j]] then return true end
    end
    return false
end

--- All true sentences for suspect i.
function C.candidates(g, i, rng)
    local pz, sol = g.pz, g.sol
    local x = sol[i]
    local a = pz.area[x]
    local He, _him, his = pz:pron(i)
    local room = pz.room_names[a]
    local occ, occset = {}, {}
    for j = 1, pz.n do
        if j ~= i and pz.area[sol[j]] == a then occ[#occ + 1] = j; occset[j] = true end
    end
    local out = {}
    local function add(kind, atoms, text) out[#out + 1] = newClue(kind, atoms, text, i) end

    local area_cells = pz:areaSet({ a })
    add("area", { A.In(i, area_cells) }, He .. " was in the " .. room .. ".")
    for _, b in ipairs(pz.areas) do
        if b ~= a then
            local r1, r2 = room, pz.room_names[b]
            if rng:random() < 0.5 then r1, r2 = r2, r1 end
            add("orroom", { A.In(i, pz:areaSet({ a, b })) }, He .. " was in the " .. r1 .. " or the " .. r2 .. ".")
            add("notroom", { A.In(i, pz:areaSet({ b }), true) }, He .. " was not in the " .. pz.room_names[b] .. ".")
        end
    end

    local w = wordAt(g, x)
    if w then
        local cells = pz:onSet(w)
        add("on", { A.In(i, cells) }, He .. " was " .. onPhrase(g, w) .. ".")
        add("onroom", { A.In(i, cells), A.In(i, area_cells) }, He .. " was " .. onPhrase(g, w) .. " in the " .. room .. ".")
        if not trueForOthers(pz, i, cells) then
            add("onlyon", { A.In(i, cells), A.Only(i, cells) },
                He .. " was the only person " .. T.on_verb[w] .. " " .. art(g, w, true) .. ".")
        end
    end
    for _, w2 in ipairs(g.words) do
        if T.on_verb[w2] and w2 ~= w and not pz:onSet(w2)[x] then
            add("noton", { A.In(i, pz:onSet(w2), true) }, He .. " was not " .. T.on_verb[w2] .. " " .. art(g, w2, true) .. ".")
        end
    end

    local near = besideWords(g, x)
    local nearset = {}
    for _, w2 in ipairs(near) do
        nearset[w2] = true
        local cells = pz:besideSet(w2)
        add("beside", { A.In(i, cells) }, He .. " was beside " .. art(g, w2) .. ".")
        add("besideroom", { A.In(i, cells), A.In(i, area_cells) }, He .. " was beside " .. art(g, w2) .. " in the " .. room .. ".")
        if not trueForOthers(pz, i, cells) then
            add("onlybeside", { A.In(i, cells), A.Only(i, cells) }, He .. " was the only person beside " .. art(g, w2, true) .. ".")
        end
    end
    for k1 = 1, #near do
        for k2 = k1 + 1, #near do
            local w1, w2 = near[k1], near[k2]
            add("beside2", { A.In(i, pz:besideSet(w1)), A.In(i, pz:besideSet(w2)) },
                He .. " was beside " .. art(g, w1) .. " and " .. art(g, w2) .. ".")
        end
    end
    local inroom = {}
    for y in pairs(pz.area_cells[a]) do
        local w2 = WORD_OF[pz.obj[y]]
        if w2 and not T.on_verb[w2] and not nearset[w2] then inroom[w2] = true end
    end
    local inlist = {}
    for w2 in pairs(inroom) do inlist[#inlist + 1] = w2 end
    table.sort(inlist)
    for _, w2 in ipairs(inlist) do
        add("notbeside", { A.In(i, area_cells), A.In(i, pz:besideSet(w2), true) },
            He .. " was in the " .. room .. ", but not beside " .. art(g, w2) .. ".")
    end

    if #occ == 0 then
        add("alone", { A.AreaCount(i, "alone") }, He .. " was alone.")
        add("aloneroom", { A.In(i, area_cells), A.AreaCount(i, "alone") }, He .. " was alone in the " .. room .. ".")
    elseif #occ == 1 and occ[1] ~= pz.victim then
        local j = occ[1]
        add("alonewith", { A.AreaCount(i, "alonewith", { t = "person", v = j }) }, He .. " was alone with " .. pz.names[j] .. ".")
        add("alonewithg", { A.AreaCount(i, "alonewith", { t = "female", v = pz.female[j] }) },
            He .. " was alone with a " .. (pz.female[j] and "woman" or "man") .. ".")
    end
    for _, j in ipairs(occ) do
        if j ~= pz.victim then
            add("with", { A.AreaCount(i, "with", { t = "person", v = j }) }, He .. " was with " .. pz.names[j] .. ".")
        end
    end
    for j = 1, pz.n - 1 do
        if j ~= i and not occset[j] then
            add("notwith", { A.AreaCount(i, "none", { t = "person", v = j }) }, He .. " was not with " .. pz.names[j] .. ".")
        end
    end
    for _, fem in ipairs({ false, true }) do
        local word = fem and "woman" or "man"
        local has, hasv = 0, false
        for _, j in ipairs(occ) do
            if pz.female[j] == fem then has = has + 1; if j == pz.victim then hasv = true end end
        end
        local same = (fem == pz.female[i])
        if #occ > 0 and has == 0 then
            add("nogender", { A.AreaCount(i, "none", { t = "female", v = fem }) },
                "There was no " .. (same and "other " or "") .. word .. " in " .. his .. " area.")
        end
        if has > 0 and not hasv then
            add("existsg", { A.AreaCount(i, "with", { t = "female", v = fem }) },
                "There was " .. (same and "another" or "a") .. " " .. word .. " in " .. his .. " area.")
        end
        if same and has == 0 then
            local others, exempt = false, {}
            for j = 1, pz.n do
                if j ~= i and pz.female[j] == fem then others = true end
                if pz.female[j] ~= fem then exempt[#exempt + 1] = j end
            end
            if others then
                add("onlygender", { A.In(i, area_cells), A.Only(i, area_cells, exempt) },
                    He .. " was the only " .. word .. " in the " .. room .. ".")
            end
        end
    end
    for _, j in ipairs(occ) do
        local y = sol[j]
        local w2 = wordAt(g, y)
        if w2 then
            local phrase = T.on_verb[w2] .. " " .. art(g, w2, true)
            local at = A.Exists(i, "samearea", pz:onSet(w2))
            at.desc = "the person " .. phrase .. " in " .. pz.names[i] .. "'s area"
            add("exists", { at }, "Someone else in " .. his .. " area was " .. phrase .. ".")
        end
        for _, w3 in ipairs(besideWords(g, y)) do
            local phrase = "beside " .. art(g, w3, true)
            local at = A.Exists(i, "samearea", pz:besideSet(w3))
            at.desc = "the person " .. phrase .. " in " .. pz.names[i] .. "'s area"
            add("exists", { at }, "Someone else in " .. his .. " area was " .. phrase .. ".")
        end
    end

    local N = pz.H
    local r, c = pz.row[x], pz.col[x]
    local rw = (r == 0 and "top row") or (r == N - 1 and "bottom row") or (ORD[r] .. " row")
    local cw = (c == 0 and "first column") or (c == pz.W - 1 and "last column") or (ORD[c] .. " column")
    add("row", { A.In(i, pz:rowSet(r), false, true) }, He .. " was in the " .. rw .. ".")
    add("col", { A.In(i, pz:colSet(c), false, true) }, He .. " was in the " .. cw .. ".")
    if pz:cornerSet()[x] then
        add("corner", { A.In(i, pz:cornerSet()) }, He .. " was in a corner of " .. his .. " area.")
    end

    for j = 1, pz.n do
        if j ~= i then
            local y = sol[j]
            local nm = pz.names[j]
            local ns = pz.row[x] < pz.row[y] and "north" or "south"
            local ew = pz.col[x] < pz.col[y] and "west" or "east"
            add("compass", { A.Rel(i, j, ns) }, He .. " was " .. ns .. " of " .. nm .. ".")
            add("compass", { A.Rel(i, j, ew) }, He .. " was " .. ew .. " of " .. nm .. ".")
            local dr = pz.row[x] - pz.row[y]
            if math.abs(dr) <= 3 then
                local k = math.abs(dr)
                add("offset", { A.Rel(i, j, "rows", dr) },
                    He .. " was exactly " .. NUM[k] .. " row" .. (k > 1 and "s" or "") .. " " .. ns .. " of " .. nm .. ".")
            end
            local dc = pz.col[x] - pz.col[y]
            if math.abs(dc) <= 2 then
                local k = math.abs(dc)
                add("offset", { A.Rel(i, j, "cols", dc) },
                    He .. " was exactly " .. NUM[k] .. " column" .. (k > 1 and "s" or "") .. " " .. ew .. " of " .. nm .. ".")
            end
        end
    end
    return out
end

--- "Someone ..." sentences for suspect i (aha mode; port of
-- clues.existential_candidates). Each atom gets a `desc` for the hints.
function C.existentialCandidates(g, i)
    local pz, sol = g.pz, g.sol
    local x = sol[i]
    local He, _him, _his = pz:pron(i)
    local a = pz.area[x]
    local name = pz.names[i]
    local out = {}
    local function add(kind, at, desc, text)
        at.desc = desc
        out[#out + 1] = newClue(kind, { at }, text, i)
    end
    for _, w in ipairs(g.words) do
        if T.on_verb[w] then
            local cells = pz:onSet(w)
            if next(cells) and not (w == "carpet" and cells[x]) then
                local phrase = T.on_verb[w] .. " " .. art(g, w, true)
                local occ_on = false
                for j = 1, pz.n do
                    if j ~= i and pz.area[sol[j]] == a and cells[sol[j]] then occ_on = true end
                end
                if occ_on then
                    add("samearea", A.Exists(i, "samearea", cells), "the person " .. phrase .. " in " .. name .. "'s area",
                        He .. " was in the same area as someone " .. phrase .. ".")
                end
                for _, kw in ipairs({ { -1, "north" }, { 1, "south" } }) do
                    local k = kw[1]
                    local hit = false
                    for j = 1, pz.n do
                        if j ~= i and pz.row[x] - pz.row[sol[j]] == k and cells[sol[j]] then hit = true end
                    end
                    if hit then
                        add("rowof", A.Exists(i, "rows", cells, nil, k),
                            "the person " .. phrase .. " one row " .. (k < 0 and "south" or "north") .. " of " .. name,
                            He .. " was exactly one row " .. kw[2] .. " of someone " .. phrase .. ".")
                    end
                end
            end
        end
    end
    for _, fw in ipairs({ { false, "man" }, { true, "woman" } }) do
        local hit = false
        for j = 1, pz.n - 1 do
            if j ~= i and pz.area[sol[j]] == a and pz.female[j] == fw[1] then hit = true end
        end
        if hit then
            add("withg", A.AreaCount(i, "with", { t = "female", v = fw[1] }), "the " .. fw[2] .. " in " .. name .. "'s area",
                He .. " was with a " .. fw[2] .. ".")
        end
    end
    return out
end

--- True puzzle-wide clues.
function C.generalCandidates(g)
    local pz, sol = g.pz, g.sol
    local out = {}
    for _, w in ipairs(g.words) do
        local cells, phrase
        if T.on_verb[w] then
            cells, phrase = pz:onSet(w), T.on_verb[w] .. " " .. art(g, w, true)
        else
            cells, phrase = pz:besideSet(w), "beside " .. art(g, w, true)
        end
        if next(cells) then
            local k = 0
            for j = 1, pz.n do if cells[sol[j]] then k = k + 1 end end
            if k == 0 then
                out[#out + 1] = newClue("g-none", { A.Count(cells, 0, 0) }, "No one was " .. phrase .. ".")
            elseif k == 1 then
                out[#out + 1] = newClue("g-one", { A.Count(cells, 1, 1) }, "There was exactly one person " .. phrase .. ".")
            elseif k == 2 then
                out[#out + 1] = newClue("g-two", { A.Count(cells, 2, 2) }, "There were exactly two people " .. phrase .. ".")
            end
        end
    end
    local cnt, nused = {}, 0
    for j = 1, pz.n do
        local a = pz.area[sol[j]]
        if not cnt[a] then nused = nused + 1 end
        cnt[a] = (cnt[a] or 0) + 1
    end
    if nused == #pz.areas then
        out[#out + 1] = newClue("g-noempty", { A.NoEmptyArea() }, "There was no empty area.")
    end
    local loner = false
    for _, k in pairs(cnt) do if k == 1 then loner = true end end
    if not loner then
        out[#out + 1] = newClue("g-noloner", { A.NoLoner() }, "No area contained exactly one person.")
    end
    return out
end

function C.victimClue(pz)
    local He = pz:pron(pz.victim)
    return newClue("victim", { A.AreaCount(pz.victim, "alonewith", nil) },
        "The Victim. " .. He .. " was alone with the murderer.", pz.victim)
end

return C
