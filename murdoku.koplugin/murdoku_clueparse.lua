--[[--
A small reader for clue sentences, used for display only:
  * Parse.html(p, text)       – clue as HTML with the keywords in bold
  * Parse.cells(p, i)         – set of "r,c" squares a suspect's clue points
                                at (area, on/beside an object, row, column,
                                corner), or nil if nothing was recognised
Positive clauses are intersected; "not" clauses subtract.
--]]

local Puzzle = require("murdoku_puzzle")
local OBJECTS = require("murdoku_objects")

local Parse = {}

local ORD = { first = 1, second = 2, third = 3, fourth = 4, fifth = 5, sixth = 6, seventh = 7,
    eighth = 8, ninth = 9, tenth = 10, eleventh = 11, twelfth = 12 }

local KEYWORDS = { "north", "south", "east", "west", "northeast", "northwest", "southeast", "southwest",
    "beside", "next to", "not", "only", "alone", "corner", "row", "column", "exactly", "no", "nobody",
    "with", "man", "woman", "men", "women", "victim", "murderer", "same", "different", "everyone" }

local function esc(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- Lower-case phrases to make bold, longest first (cached per puzzle).
local function phrases(p)
    if p._kw then return p._kw end
    local set = {}
    for _, w in ipairs(KEYWORDS) do set[w] = true end
    for _, room in pairs(p.rooms) do
        if room.name then set[room.name:lower()] = true end
    end
    for _, s in ipairs(p.suspects) do set[s.name:lower()] = true end
    for id, o in pairs(OBJECTS) do
        if id ~= 0 and o.name then
            local n = o.name:lower()
            set[n] = true
            set[n .. "s"] = true
            set[n .. "es"] = true
        end
    end
    local list = {}
    for k in pairs(set) do table.insert(list, k) end
    table.sort(list, function(a, b) return #a > #b end)
    p._kw = list
    return list
end

local function isWordChar(ch)
    return ch ~= "" and ch:match("[%w']") ~= nil
end

--- Clue text as an HTML fragment with keywords in <b>.
function Parse.html(p, text)
    local list = phrases(p)
    local lower = text:lower()
    local out = {}
    local i, n = 1, #text
    local plain_start = 1
    while i <= n do
        local prev = i > 1 and lower:sub(i - 1, i - 1) or ""
        local matched
        if not isWordChar(prev) and isWordChar(lower:sub(i, i)) then
            for _, ph in ipairs(list) do
                if lower:sub(i, i + #ph - 1) == ph and not isWordChar(lower:sub(i + #ph, i + #ph)) then
                    matched = ph
                    break
                end
            end
        end
        if matched then
            table.insert(out, esc(text:sub(plain_start, i - 1)))
            table.insert(out, "<b>" .. esc(text:sub(i, i + #matched - 1)) .. "</b>")
            i = i + #matched
            plain_start = i
        else
            i = i + 1
        end
    end
    table.insert(out, esc(text:sub(plain_start)))
    return table.concat(out)
end

-- Names the site's clues use that differ from our object names.
local ALIASES = {
    ["mud puddle"] = { 34, 142 }, ["water puddle"] = { 34 }, ["puddle"] = { 34, 142 },
    ["cash register"] = { 28, 94, 141 }, ["sand pit"] = { 24 }, ["sand tile"] = { 24 },
    ["path tile"] = { 140 }, ["cart"] = { 71, 98 }, ["golf tee"] = { 78 }, ["lilypad"] = { 79, 104 },
    ["lily pad"] = { 79, 104 }, ["boat"] = { 25, 73, 74, 76, 77, 110, 111, 112, 113, 124 },
    ["animal"] = { 15, 17, 26, 35, 40, 47, 48, 50, 52, 53, 54, 55, 59, 62, 64, 68, 84, 91, 96, 137, 151 },
}

-- Object ids whose (lower-case) name matches word w (singular or plural).
local function objectIds(w)
    for _, cand in ipairs({ w, (w:gsub("es$", "")), (w:gsub("s$", "")) }) do
        local a = ALIASES[cand]
        if a then
            local ids = {}
            for _, id in ipairs(a) do ids[id] = true end
            return ids
        end
    end
    local ids = {}
    for id, o in pairs(OBJECTS) do
        if id ~= 0 and o.name then
            local n = o.name:lower()
            if w == n or w == n .. "s" or w == n .. "es" then ids[id] = true end
        end
    end
    return next(ids) and ids or nil
end

-- Find an object phrase right after position pos in sentence s.
local function objectAfter(s, pos)
    local rest = s:sub(pos):gsub("^%s*(%a+)%s+", function(det)
        if det == "a" or det == "an" or det == "the" or det == "some" or det == "one" then return "" end
    end)
    local w1, w2 = rest:match("^%s*([%a']+)%s*([%a']*)")
    if not w1 then return nil end
    if w2 and w2 ~= "" then
        local ids = objectIds(w1 .. " " .. w2)
        if ids then return ids end
    end
    return objectIds(w1)
end

local function cellsWhere(p, pred)
    local set = {}
    for r = 1, p.h do
        for c = 1, p.w do
            if Puzzle.standable(p, r, c) and pred(r, c, p.cells[r][c]) then set[r .. "," .. c] = true end
        end
    end
    return set
end

local function intersect(a, b)
    if not a then return b end
    local out = {}
    for k in pairs(a) do if b[k] then out[k] = true end end
    return out
end

local function sentenceCells(p, s, placed, self_i)
    if s:find("%f[%a]not%f[%A]") or s:find("n't") or s:find("%f[%a]no%f[%A]") or s:find("nobody")
            or s:find("someone") or s:find("%f[%a]else%f[%A]") or s:find("%f[%a]who%f[%A]") or s:find("everyone") or s:find("there was")
            or s:find("there were") or s:find("of an? w?o?man%f[%A]") or s:find("of the w?o?man%f[%A]")
            or s:find("of a person") then
        -- these describe somebody else, not where this person stands
        return nil
    end
    -- relative to a person who is already on the board
    local NUM = { one = 1, two = 2, three = 3, four = 4, five = 5, six = 6, seven = 7, eight = 8 }
    local rel_set
    if placed then
        for j, sp in ipairs(p.suspects) do
            local nm = sp.name:lower()
            local a = j ~= self_i and placed[j] and s:find("%f[%a]" .. nm:gsub("%p", "%%%0") .. "%f[%A]")
            if a then
                local pr, pc = placed[j][1], placed[j][2]
                local pred
                local n, unit, dir = s:match("exactly (%a+) (%a+) (%a+) of " .. nm)
                local k = n and (NUM[n] or tonumber(n))
                if k and unit and dir then
                    local isrow = unit:match("^row")
                    if isrow and dir == "north" then pred = function(r) return r == pr - k end
                    elseif isrow and dir == "south" then pred = function(r) return r == pr + k end
                    elseif not isrow and dir == "west" then pred = function(_, c) return c == pc - k end
                    elseif not isrow and dir == "east" then pred = function(_, c) return c == pc + k end end
                else
                    dir = s:match("(%a+) of " .. nm)
                    if dir == "north" then pred = function(r) return r < pr end
                    elseif dir == "south" then pred = function(r) return r > pr end
                    elseif dir == "west" then pred = function(_, c) return c < pc end
                    elseif dir == "east" then pred = function(_, c) return c > pc end
                    elseif s:find("with " .. nm) then
                        local area = p.cells[pr][pc].area
                        pred = function(_, _, cell) return cell.area == area end
                    end
                end
                if pred then rel_set = intersect(rel_set, cellsWhere(p, pred)) end
            end
        end
    end
    local set = rel_set
    -- area
    local best, best_len
    for code, room in pairs(p.rooms) do
        local name = room.name and room.name:lower()
        if name and #name > (best_len or 0) and s:find(name, 1, true) then best, best_len = code, #name end
    end
    if best then
        set = intersect(set, cellsWhere(p, function(_, _, cell) return cell.area == best end))
        -- blank the area name out so "in the Tool Shed" isn't read as "in a tool"
        local name = p.rooms[best].name:lower()
        local a = s:find(name, 1, true)
        s = s:sub(1, a - 1) .. string.rep("_", #name) .. s:sub(a + #name)
    end
    -- beside an object (same area only)
    for _, kw in ipairs({ "beside", "next to" }) do
        local start = 1
        while true do
            local b = s:find(kw, start, true)
            if not b then break end
            start = b + #kw
            local ids = objectAfter(s, b + #kw)
            if ids then
                set = intersect(set, cellsWhere(p, function(r, c, cell)
                    for _, d in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
                        local n = Puzzle.cell(p, r + d[1], c + d[2])
                        if n and not n.void and n.area == cell.area and ids[n.obj] then return true end
                    end
                    return false
                end))
            end
        end
    end
    -- on a carpet (carpets are a separate layer, not an object)
    if s:find("carpet") and (s:find("on a carpet") or s:find("on the carpet") or s:find("on carpet")) then
        set = intersect(set, cellsWhere(p, function(_, _, cell) return cell.carpet end))
    end
    -- on / in / sitting in an object
    for _, verb in ipairs({ "on ", "in ", "inside ", "under " }) do
        local start = 1
        while true do
            local a = s:find(verb, start, true)
            if not a then break end
            start = a + 1
            if a == 1 or not s:sub(a - 1, a - 1):match("%a") then
                local ids = objectAfter(s, a + #verb)
                if ids and ids[5] then ids = nil end -- carpets handled above
                if ids then
                    set = intersect(set, cellsWhere(p, function(_, _, cell) return ids[cell.obj] == true end))
                    break
                end
            end
        end
    end
    -- row / column
    local function line(word, n)
        local idx
        local ord = s:match("(%a+) " .. word)
        if ord == "last" or ord == "bottom" or ord == "rightmost" then idx = n
        elseif ord == "top" or ord == "leftmost" then idx = 1
        elseif ord and ORD[ord] then idx = ORD[ord]
        elseif s:match("(%d+)%a%a " .. word) then idx = tonumber(s:match("(%d+)%a%a " .. word))
        else idx = tonumber(s:match(word .. " (%d+)")) end
        return idx
    end
    local row = line("row", p.h)
    if row and not s:find("rows? north") and not s:find("rows? south") then
        set = intersect(set, cellsWhere(p, function(r) return r == row end))
    end
    local col = line("column", p.w)
    if col and not s:find("columns? east") and not s:find("columns? west") then
        set = intersect(set, cellsWhere(p, function(_, c) return c == col end))
    end
    -- corner of the area
    if s:find("corner of h") then
        set = intersect(set, cellsWhere(p, function(r, c, cell)
            local function wall(dr, dc)
                local n = Puzzle.cell(p, r + dr, c + dc)
                return not n or n.void or n.area ~= cell.area
            end
            local up, down, left, right = wall(-1, 0), wall(1, 0), wall(0, -1), wall(0, 1)
            return (up or down) and (left or right)
        end))
    end
    return set
end

local function negatable(c)
    return not (c:find("someone") or c:find("%f[%a]else%f[%A]") or c:find("everyone") or c:find("nobody")
        or c:find("there was") or c:find("there were") or c:find("%f[%a]no%f[%A]"))
end

--- Squares a suspect's clue points at, or nil.
-- Positive clauses are intersected; "not ..." clauses (not in the X, not beside
-- a Y, not on a chair, not in the first row) take their squares away.
function Parse.cells(p, i, placed)
    local s = p.suspects[i]
    if not s or s.is_victim then return nil end
    local set, minus
    for sentence in (s.clue .. "."):gmatch("([^%.!?]+)[%.!?]") do -- the last sentence may lack a full stop
        -- "in the Shipyard, but not beside the box": read each clause on its own
        local low = sentence:lower():gsub(",? but ", "|"):gsub(",? and ", "|"):gsub(",? nor ", "|not ")
            :gsub("; ", "|"):gsub(", ", "|")
        for clause in (low .. "|"):gmatch("([^|]+)|") do
            local neg = clause:find("%f[%a]not%f[%A]") or clause:find("n't")
            if neg then
                if negatable(clause) then
                    local pos = clause:gsub("n't", ""):gsub("%f[%a]not%s+", "")
                    local cs = sentenceCells(p, pos, placed, i)
                    if cs and next(cs) then
                        minus = minus or {}
                        for k in pairs(cs) do minus[k] = true end
                    end
                end
            elseif clause:find(" or ") then
                -- "in the Fiction area or in the Archives": either part will do
                local union, all = {}, true
                local lead
                for part in (clause .. " or "):gmatch("(.-) or ") do
                    local cs = sentenceCells(p, part, placed, i)
                    if not cs and lead then cs = sentenceCells(p, lead .. part, placed, i) end
                    lead = lead or part:match("^(.*%f[%a]beside%s+)") or part:match("^(.*%f[%a]on%s+)")
                        or part:match("^(.*%f[%a]in%s+)")
                    if not cs then all = false break end
                    for k in pairs(cs) do union[k] = true end
                end
                if all then set = intersect(set, union) end
            else
                local cs = sentenceCells(p, clause, placed, i)
                if cs then set = intersect(set, cs) end
            end
        end
    end
    -- "not" parts take squares away; on their own they show every other square
    if minus then
        set = set or cellsWhere(p, function() return true end)
        for k in pairs(minus) do set[k] = nil end
    end
    if set and next(set) == nil then return nil end
    return set
end

return Parse
