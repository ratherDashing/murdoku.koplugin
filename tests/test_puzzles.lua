-- Validates the parser against a directory of downloaded puzzle JSON files.
-- usage (from repo root, with KOReader's common/ dir providing json):
--   LUA_PATH="$KO/common/?.lua;;" luajit tests/test_puzzles.lua <dir-with-json-files>
local here = arg[0]:match("^(.*)/tests/") or "."
package.path = here .. "/murdoku.koplugin/?.lua;" .. package.path
local json = require("json")
local Puzzle = require("murdoku_puzzle")

local dir = assert(arg[1], "pass a directory of puzzle .json files")
local failures, total = 0, 0
for file in io.popen('ls "' .. dir .. '"'):lines() do
    if file:match("%.json$") then
        total = total + 1
        local f = assert(io.open(dir .. "/" .. file))
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
        end
        if #errs > 0 then
            failures = failures + 1
            print("FAIL", file, table.concat(errs, "; "))
        end
    end
end
print(string.format("%d/%d puzzles OK", total - failures, total))
os.exit(failures == 0 and 0 or 1)
