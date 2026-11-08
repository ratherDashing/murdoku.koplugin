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

    for r = 1, H do
        p.cells[r] = {}
        for c = 1, W do
            local room = int(flat[key("room_code", r - 1, c - 1)]) or 0
            local obj = int(flat[key("room_objects", r - 1, c - 1)]) or 0
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

    local rx, ry, cs = num(P.grid_rx), num(P.grid_ry), num(P.cellsize)
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
        table.insert(p.suspects, {
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
    local parts = { string.format("Row %d, Column %d", r, c) }
    if cell.void then
        table.insert(parts, "Not part of the scene")
        return table.concat(parts, "\n")
    end
    table.insert(parts, "Area: " .. p.rooms[cell.area].name)
    local o = Puzzle.objectInfo(cell.obj)
    if o and cell.obj ~= 0 then
        table.insert(parts, o.name .. (o.occupiable == true and " (can stand/sit here)" or " (nobody can be here)"))
    end
    if cell.carpet then table.insert(parts, "Carpet") end
    if not o and not cell.carpet then table.insert(parts, "Empty floor") end
    return table.concat(parts, "\n")
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
