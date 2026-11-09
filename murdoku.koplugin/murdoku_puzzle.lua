--[[--
Parses a Murdoku puzzle JSON (as served by murdoku.com/play_puzzles) into a
plain Lua table that the game screen can use.

Two on-disk formats exist:
  * v2 (PROPERTIES.puzzle_version == "2"): cell keys are `name_<row>_<col>`,
    solutions are in `solution_x_<i>` / `solution_y_<i>`.
  * v1 (older, has GRID/OBJECT sections): cell keys are `name_<x>_<y>`, and the
    solution is encoded as each suspect's letter position in editor pixels:
    col = floor((letter_xpos - grid_rx) / cellsize), same for rows.

This module has no KOReader dependencies so it can be unit tested with plain LuaJIT.
--]]

local OBJECTS = require("murdoku_objects")

local Puzzle = {}

local function num(v)
    if v == nil then return nil end
    if type(v) == "number" then return v end
    return tonumber(v)
end

local function int(v)
    local n = num(v)
    if n == nil then return nil end
    return math.floor(n + 0.0000001)
end

local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Merge every section into one flat lookup table (the site does the same).
local function flatten(data)
    local flat = {}
    for _, section in ipairs({ "CHARACTERS", "GRID", "OBJECT", "PROPERTIES" }) do
        local s = data[section]
        if type(s) == "table" then
            for k, v in pairs(s) do
                if flat[k] == nil then flat[k] = v end
            end
        end
    end
    for k, v in pairs(data) do
        if type(v) ~= "table" and flat[k] == nil then flat[k] = v end
    end
    return flat
end

--- Returns object info for a cell object id (never nil for a non-zero id).
function Puzzle.objectInfo(id)
    if not id or id == 0 then return nil end
    local o = OBJECTS[id]
    if o then return o end
    return { name = "Object", occupiable = true }
end

--- Whether a suspect may stand on a cell with this object id.
function Puzzle.isStandable(id)
    if not id or id == 0 then return true end
    local o = OBJECTS[id]
    if not o then return true end
    return o.occupiable == true
end

function Puzzle.isVoid(id)
    return id == 8 or id == 33
end

-- Multi-cell objects are stored only at their anchor cell; the site draws
-- them over the neighbouring empty cells too.
local RIGHT1 = { [6] = true, [119] = true, [21] = true, [22] = true, [90] = true } -- bed, car, carriage
local RIGHT2 = { [56] = true }               -- bus: two more cells to the right
local DOWN1 = { [7] = true, [120] = true }   -- vertical bed: the cell below
local BIG2X2 = { [54] = true }               -- elephant
Puzzle.FOOTPRINT = { right1 = RIGHT1, right2 = RIGHT2, down1 = DOWN1, big2x2 = BIG2X2 }

--- Expand multi-cell objects in a 1-based objs[r][c] grid (in place).
-- Only empty cells are filled; additions are computed from the original grid.
function Puzzle.expandFootprints(objs, H, W)
    local add = {}
    local function push(r, c, g)
        if r <= H and c <= W then table.insert(add, { r, c, g }) end
    end
    for r = 1, H do
        for c = 1, W do
            local g = objs[r][c]
            if RIGHT1[g] then push(r, c + 1, g) end
            if RIGHT2[g] then push(r, c + 1, g); push(r, c + 2, g) end
            if DOWN1[g] then push(r + 1, c, g) end
            if BIG2X2[g] then push(r, c + 1, g); push(r + 1, c, g); push(r + 1, c + 1, g) end
        end
    end
    for _, a in ipairs(add) do
        if objs[a[1]][a[2]] == 0 then objs[a[1]][a[2]] = a[3] end
    end
    return objs
end

--- Parse decoded JSON into a puzzle.
-- @treturn table|nil puzzle
-- @treturn string|nil error message
function Puzzle.parse(data, id)
    if type(data) ~= "table" then return nil, "invalid puzzle data" end
    local P = data.PROPERTIES or {}
    local flat = flatten(data)
    local W, H = int(P.grid_w or flat.grid_w), int(P.grid_h or flat.grid_h)
    if not W or not H or W < 3 or H < 3 or W > 24 or H > 24 then
        return nil, "unsupported grid size"
    end
    local version = tostring(P.puzzle_version or "")
    local v2 = (tonumber(version) or 0) >= 2

    -- key for cell (r, c), 0-based
    local function key(name, r, c)
        if v2 then return name .. "_" .. r .. "_" .. c end
        return name .. "_" .. c .. "_" .. r
    end

    local p = {
        id = id,
        w = W,
        h = H,
        version = v2 and 2 or 1,
        title = trim(flat.title_en_) ~= "" and trim(flat.title_en_) or (id or "Untitled"),
        creator = trim(flat.creator_ or flat.creator),
        difficulty = int(P.difficulty),
        cells = {},     -- cells[r][c] = { area=, room=, obj=, carpet=bool }, 1-based
        rooms = {},     -- rooms[code] = { name=, cells = {{r,c},...} }
        suspects = {},  -- 1-based list
        hints = {},
        windows_h = {}, -- ["r,c"] = kind ; edge above cell (r,c), r in 1..H+1
        windows_v = {}, -- ["r,c"] = kind ; edge left of cell (r,c), c in 1..W+1
    }

    -- Sub-rooms are drawn separately on the site but count as their main room.
    local subroom_of = {}
    for k, v in pairs(flat) do
        local code = k:match("^room_subroom_(%d+)$")
        if code and int(v) == 1 then
            local main = int(flat["room_subroom_mainroom_" .. code])
            if main then subroom_of[tonumber(code)] = main end
        end
    end

    -- Raw object ids first, so multi-cell objects can be expanded before use.
    local objs = {}
    for r = 1, H do
        objs[r] = {}
        for c = 1, W do
            objs[r][c] = int(flat[key("room_objects", r - 1, c - 1)]) or 0
        end
    end
    Puzzle.expandFootprints(objs, H, W)

    for r = 1, H do
        p.cells[r] = {}
        for c = 1, W do
            local room = int(flat[key("room_code", r - 1, c - 1)]) or 0
            local obj = objs[r][c]
            local carpet = int(flat[key("carpet_objects", r - 1, c - 1)]) or 0
            local area = subroom_of[room] or room
            p.cells[r][c] = {
                room = room,
                area = area,
                obj = obj,
                carpet = carpet > 0,
                void = Puzzle.isVoid(obj),
            }
            if not p.rooms[area] then
                p.rooms[area] = { cells = {} }
            end
            table.insert(p.rooms[area].cells, { r, c })
        end
    end
    for code, room in pairs(p.rooms) do
        local name = trim(flat["room_name_" .. code])
        room.name = name ~= "" and name or ("Area " .. code)
    end
    local rx, ry, cs = num(P.grid_rx), num(P.grid_ry), num(P.cellsize)
    if not v2 and rx and ry and cs and cs > 0 then
        -- v1: the site draws each room_name_k as free text at (xpos, ypos); the
        -- label's position, not k, says which area it names.
        local bypos, used = {}, {}
        for k = 0, 199 do
            local name = trim(flat["room_name_" .. k])
            local x, y = num(flat["room_name_xpos_" .. k]), num(flat["room_name_ypos_" .. k])
            if name ~= "" and x and y then
                local r, c = math.floor((y - ry) / cs) + 1, math.floor((x - rx) / cs) + 1
                if r >= 1 and r <= H and c >= 1 and c <= W then
                    local a = p.cells[r][c].area
                    if not bypos[a] then
                        bypos[a] = name
                        used[name] = true
                    end
                end
            end
        end
        for code, room in pairs(p.rooms) do
            if bypos[code] then
                room.name = bypos[code]
            elseif used[room.name] then
                room.name = "Area " .. code
            end
        end
    end

    -- Windows/doors live on cell edges (rare).
    for k, v in pairs(flat) do
        local kind = int(v)
        if kind and kind > 0 then
            local a, b = k:match("^room_windows_h_(%d+)_(%d+)$")
            if a then
                local x, y = tonumber(a), tonumber(b)
                if v2 then x, y = y, x end
                p.windows_h[(y + 1) .. "," .. (x + 1)] = kind
            else
                a, b = k:match("^room_windows_v_(%d+)_(%d+)$")
                if a then
                    local x, y = tonumber(a), tonumber(b)
                    if v2 then x, y = y, x end
                    p.windows_v[(y + 1) .. "," .. (x + 1)] = kind
                end
            end
        end
    end

    -- Suspects
    local count = 0
    while flat["char_name_" .. count] ~= nil and trim(flat["char_name_" .. count]) ~= "" do
        count = count + 1
    end
    local total = int(P.total_char or flat.total_char)
    if total and total > 0 and total < count then count = total end
    if count < 3 then return nil, "not enough suspects" end

    for i = 0, count - 1 do
        local quote = trim(flat["char_quote_en_" .. i])
        local sub = trim(flat["char_subquote_en_" .. i])
        -- v1 splits a clue across quote/subquote ("He was at the " .. "Judge's Bench.")
        local clue = trim((quote .. " " .. sub):gsub("%s+", " "))
        clue = clue:gsub("<[^>]+>", "")

        local sr, sc
        local sx, sy = num(flat["solution_x_" .. i]), num(flat["solution_y_" .. i])
        if v2 and sx and sy then
            sr, sc = math.floor(sy) + 1, math.floor(sx) + 1
        elseif rx and ry and cs and cs > 0 then
            local lx, ly = num(flat["letter_xpos_" .. i]), num(flat["letter_ypos_" .. i])
            if lx and ly then
                sc = math.floor((lx - rx) / cs) + 1
                sr = math.floor((ly - ry) / cs) + 1
            end
        end
        if sr then sr = math.max(1, math.min(H, sr)) end
        if sc then sc = math.max(1, math.min(W, sc)) end

        local name = trim(flat["char_name_" .. i])
        -- looks (murdoku.com cases only), used for the portrait
        local char
        if flat["char_hair_" .. i] ~= nil then
            char = {
                hair = int(flat["char_hair_" .. i]) or 0,
                haircolor = int(flat["char_haircolor_" .. i]) or 0,
                facial = int(flat["char_facial_" .. i]) or 0,
                accessory = int(flat["char_accessory_" .. i]) or 0,
                hat = int(flat["char_hat_" .. i]) or 0,
            }
        end
        table.insert(p.suspects, {
            char = char,
            index = i + 1,
            letter = string.char(64 + i + 1), -- A, B, C...
            name = name,
            female = int(flat["char_sex_" .. i]) == 1,
            clue = clue,
            sol = sr and { sr, sc } or nil,
        })
    end
    -- The victim is always the last character.
    p.victim = count
    p.suspects[count].letter = "V"
    p.suspects[count].is_victim = true
    local m = int(P.murderer or flat.murderer)
    p.murderer = m and (m + 1) or nil

    -- Hints: v2 uses player_hint_N_en, v1 uses solution_text_EN_N (and sometimes player_hint_N_en).
    local hints = {}
    for n = 1, 30 do
        local h = trim(flat["player_hint_" .. n .. "_en"])
        if h ~= "" then table.insert(hints, h) end
    end
    if #hints == 0 then
        for n = 0, 30 do
            local h = trim(flat["solution_text_EN_" .. n])
            if h ~= "" then table.insert(hints, h) end
        end
    end
    p.hints = hints

    -- Show each person by the first letter of their name when those letters
    -- are all different (the site numbers them A, B, C... which nearly always
    -- matches, but not quite always). Hints that say "(F)" follow along.
    local firsts, remap, clash = {}, {}, false
    for _, sp in ipairs(p.suspects) do
        local fl = sp.name:sub(1, 1):upper()
        if not fl:match("%u") or firsts[fl] then clash = true break end
        firsts[fl] = true
    end
    if not clash then
        for _, sp in ipairs(p.suspects) do
            local fl = sp.name:sub(1, 1):upper()
            if fl ~= sp.letter then remap[sp.letter] = fl; sp.letter = fl end
        end
        if next(remap) then
            for n, h in ipairs(p.hints) do
                p.hints[n] = h:gsub("%((%u)%)", function(l) return "(" .. (remap[l] or l) .. ")" end)
            end
        end
    end

    -- General clues apply to everyone. The site uses clue_custom_text<N> and
    -- (v2) general_clue_<N>, often with the same text in both.
    local general, seen = {}, {}
    for n = 0, 20 do
        for _, field in ipairs({ "clue_custom_text" .. n, "general_clue_" .. n }) do
            local t = trim(tostring(flat[field] or ""):gsub("<[^>]+>", ""):gsub("%s+", " "))
            if t ~= "" and not seen[t] then
                seen[t] = true
                table.insert(general, t)
            end
        end
    end
    p.general_clues = general

    p.has_solution = true
    for _, s in ipairs(p.suspects) do
        if not s.sol then p.has_solution = false end
    end
    return p
end

function Puzzle.cell(p, r, c)
    return p.cells[r] and p.cells[r][c]
end

function Puzzle.standable(p, r, c)
    local cell = Puzzle.cell(p, r, c)
    if not cell or cell.void then return false end
    return Puzzle.isStandable(cell.obj)
end

--- Human readable description of a cell.
function Puzzle.describe(p, r, c)
    local cell = Puzzle.cell(p, r, c)
    if not cell then return "" end
    local head = string.format("R%d C%d", r, c)
    if cell.void then
        return head .. "\nNot part of the scene."
    end
    local o = Puzzle.objectInfo(cell.obj)
    local what
    if o and cell.obj ~= 0 then what = o.name end
    if cell.carpet then what = what and (what .. " on a carpet") or "Carpet" end
    what = what or "Empty floor"
    local can = Puzzle.standable(p, r, c) and "You can stand here." or "You can't stand here."
    return string.format("%s · %s\n%s\n%s", head, p.rooms[cell.area].name, what, can)
end

--- Check a placement map { [suspect_index] = {r,c} } against the solution.
-- @treturn table { placed=, correct=, wrong = {indices}, solved = bool }
function Puzzle.check(p, placements)
    local res = { placed = 0, correct = 0, wrong = {}, solved = false }
    for i, s in ipairs(p.suspects) do
        local pos = placements[i]
        if pos then
            res.placed = res.placed + 1
            if s.sol and s.sol[1] == pos[1] and s.sol[2] == pos[2] then
                res.correct = res.correct + 1
            else
                table.insert(res.wrong, i)
            end
        end
    end
    res.solved = res.correct == #p.suspects
    return res
end

--- Rule violations visible without knowing the solution
-- (two suspects in one row/column, or someone on an object nobody can stand on).
function Puzzle.conflicts(p, placements)
    local bad = {}
    local rows, cols = {}, {}
    for i, pos in pairs(placements) do
        rows[pos[1]] = rows[pos[1]] or {}
        table.insert(rows[pos[1]], i)
        cols[pos[2]] = cols[pos[2]] or {}
        table.insert(cols[pos[2]], i)
        if not Puzzle.standable(p, pos[1], pos[2]) then bad[i] = true end
    end
    for _, list in pairs(rows) do
        if #list > 1 then for _, i in ipairs(list) do bad[i] = true end end
    end
    for _, list in pairs(cols) do
        if #list > 1 then for _, i in ipairs(list) do bad[i] = true end end
    end
    return bad
end

return Puzzle
