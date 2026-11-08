-- Validates the parser against a directory of puzzle JSON files.
-- usage (from repo root, with KOReader's common/ dir providing json):
--   LUA_PATH="$KO/common/?.lua;;" luajit tests/test_puzzles.lua [dir-with-json-files...]
-- Built-in synthetic checks always run; each directory adds per-file checks.
local here = arg[0]:match("^(.*)/tests/") or "."
package.path = here .. "/murdoku.koplugin/?.lua;" .. package.path
local json = require("json")
local Puzzle = require("murdoku_puzzle")

local failures, total = 0, 0
local function fail(what, msg)
    failures = failures + 1
    print("FAIL", what, msg)
end

--------------------------------------------------------------------------------
-- Synthetic checks (no external files needed)
--------------------------------------------------------------------------------
local function synthetic(v2, extra)
    local P = { grid_w = "5", grid_h = "5", total_char = "3", murderer = "0" }
    if v2 then P.puzzle_version = "2" else P.grid_rx = "100"; P.grid_ry = "200"; P.cellsize = "50" end
    local C = {}
    for r = 0, 4 do
        for c = 0, 4 do
            local k = v2 and (r .. "_" .. c) or (c .. "_" .. r)
            C["room_code_" .. k] = (c < 3) and 1 or 2
            C["room_objects_" .. k] = 0
        end
    end
    for i, n in ipairs({ "Ann", "Bob", "Vic" }) do
        C["char_name_" .. (i - 1)] = n
        C["char_sex_" .. (i - 1)] = 0
        C["char_quote_en_" .. (i - 1)] = "Clue."
        C["solution_x_" .. (i - 1)] = i - 1
        C["solution_y_" .. (i - 1)] = i - 1
        C["letter_xpos_" .. (i - 1)] = 100 + 50 * (i - 1) + 10
        C["letter_ypos_" .. (i - 1)] = 200 + 50 * (i - 1) + 10
    end
    for k, v in pairs(extra or {}) do C[k] = v end
    return { PROPERTIES = P, CHARACTERS = C }
end

local synth_total, synth_fail = 0, 0
local function check(name, cond)
    synth_total = synth_total + 1
    if not cond then synth_fail = synth_fail + 1; print("FAIL", "synthetic", name) end
end

do -- multi-cell objects
    local d = synthetic(true, {
        room_objects_0_0 = 21,  -- car: covers (0,1)
        room_objects_1_0 = 56,  -- bus: covers (1,1), (1,2)
        room_objects_2_4 = 7,   -- vertical bed: covers (3,4)
        room_objects_2_0 = 54,  -- elephant: 2x2
        room_objects_0_4 = 6,   -- bed at the right edge: nothing to expand into
        room_objects_3_1 = 1,   -- a plant blocks the elephant's bottom-right cell
    })
    local p = assert(Puzzle.parse(d, "syn"))
    local o = function(r, c) return p.cells[r][c].obj end
    check("car spans 2 cells", o(1, 1) == 21 and o(1, 2) == 21 and o(1, 3) == 0)
    check("bus spans 3 cells", o(2, 1) == 56 and o(2, 2) == 56 and o(2, 3) == 56 and o(2, 4) == 0)
    check("vertical bed spans 2 rows", o(3, 5) == 7 and o(4, 5) == 7 and o(5, 5) == 0)
    check("elephant spans 2x2 but keeps existing objects", o(3, 1) == 54 and o(3, 2) == 54 and o(4, 1) == 54 and o(4, 2) == 1)
    check("bed at edge", o(1, 5) == 6)
end

do -- general clues
    local d = synthetic(true, {
        general_clue_0 = " There was no empty area. ",
        clue_custom_text1 = "There was no empty area.",
        general_clue_1 = "Every man was beside a table.",
        clue_custom_text2 = "<b>No one</b> was in the   Garden.",
    })
    local p = assert(Puzzle.parse(d, "syn"))
    local g = p.general_clues
    check("general clues de-duplicated and trimmed", #g == 3 and g[1] == "There was no empty area."
        and g[2] == "Every man was beside a table." and g[3] == "No one was in the Garden.")
    check("no general clues -> empty list", #assert(Puzzle.parse(synthetic(true), "syn")).general_clues == 0)
end

do -- v1 room names follow the label position, not the area code
    local d = synthetic(false, {
        room_name_1 = "East Wing", room_name_xpos_1 = 100 + 50 * 4 + 5, room_name_ypos_1 = 200 + 5,
        room_name_2 = "West Wing", room_name_xpos_2 = 100 + 5, room_name_ypos_2 = 200 + 5,
    })
    local p = assert(Puzzle.parse(d, "syn"))
    check("v1 label position wins", p.rooms[1].name == "West Wing" and p.rooms[2].name == "East Wing")
    -- v2 keeps the code -> name mapping
    local d2 = synthetic(true, { room_name_1 = "West Wing", room_name_2 = "East Wing" })
    local p2 = assert(Puzzle.parse(d2, "syn"))
    check("v2 names by code", p2.rooms[1].name == "West Wing" and p2.rooms[2].name == "East Wing")
end
print(string.format("%d/%d synthetic checks OK", synth_total - synth_fail, synth_total))

--------------------------------------------------------------------------------
-- Real / bundled puzzle files
--------------------------------------------------------------------------------
local OBJ_WORDS = { car = true, bed = true, bus = true, carriage = true }

local function checkFile(path, file)
    total = total + 1
    local f = assert(io.open(path))
    local data = json.decode(f:read("*a")); f:close()
    local p, err = Puzzle.parse(data, (file:gsub("%.json$", "")))
    local errs = {}
    if not p then
        errs[#errs + 1] = err
    elseif not p.has_solution then
        errs[#errs + 1] = "no solution"
    else
        local placements = {}
        for i, s in ipairs(p.suspects) do placements[i] = s.sol end
        for i in pairs(Puzzle.conflicts(p, placements)) do
            errs[#errs + 1] = "conflict " .. p.suspects[i].name
        end
        if not Puzzle.check(p, placements).solved then errs[#errs + 1] = "check failed" end
        -- the victim must be alone with the murderer
        local v = p.suspects[p.victim].sol
        local varea = p.cells[v[1]][v[2]].area
        local inroom = {}
        for i, s in ipairs(p.suspects) do
            if p.cells[s.sol[1]][s.sol[2]].area == varea then inroom[#inroom + 1] = i end
        end
        if #inroom ~= 2 or (inroom[1] ~= p.murderer and inroom[2] ~= p.murderer) then
            errs[#errs + 1] = "victim not alone with murderer"
        end
        -- simple literal clues must agree with the stored solution:
        --   "He was in the Kitchen."  -> the solution cell's area name
        --   "She was in a car."       -> the solution cell's object (multi-cell objects)
        local names = {}
        for _, room in pairs(p.rooms) do names[room.name:lower()] = true end
        for _, s in ipairs(p.suspects) do
            local cell = p.cells[s.sol[1]][s.sol[2]]
            for sentence in s.clue:gmatch("[^.]+") do
                local where = sentence:match("^%s*S?h?e was in the ([%w' %-]+)$")
                    or sentence:match("^%s*He was in the ([%w' %-]+)$")
                if where and names[where:lower()] and p.rooms[cell.area].name:lower() ~= where:lower() then
                    errs[#errs + 1] = s.name .. " is not in the " .. where
                end
                local thing = sentence:match("^%s*S?h?e was [io]n an? (%a+)$")
                    or sentence:match("^%s*He was [io]n an? (%a+)$")
                if thing and OBJ_WORDS[thing:lower()] then
                    local o = Puzzle.objectInfo(cell.obj)
                    if not o or o.name:lower() ~= thing:lower() then
                        errs[#errs + 1] = s.name .. " is not on a " .. thing
                    end
                end
            end
        end
    end
    if #errs > 0 then
        fail(file, table.concat(errs, "; "))
    end
    return p
end

for i = 1, #arg do
    local dir = arg[i]
    for file in io.popen('ls "' .. dir .. '"'):lines() do
        if file:match("%.json$") and file ~= "index.json" then
            checkFile(dir .. "/" .. file, file)
        end
    end
end
print(string.format("%d/%d puzzles OK", total - failures, total))
os.exit((failures == 0 and synth_fail == 0) and 0 or 1)
