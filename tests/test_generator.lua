-- On-device generator test: fixed seeds, every case must parse with the normal
-- parser, have a valid stored solution, a unique solution, and the right grade.
-- usage (from repo root):
--   LUA_PATH="$KO/common/?.lua;;" luajit tests/test_generator.lua [per_size=20] [difficulties=very-easy,easy,medium]
local here = arg[0]:match("^(.*)/tests/") or "."
package.path = here .. "/murdoku.koplugin/?.lua;" .. package.path
local Gen = require("murdoku_gen")
local S = require("murdoku_solver")
local Puzzle = require("murdoku_puzzle")
local St = require("murdoku_steps")

local per = tonumber(arg[1]) or 20
local diffs = {}
for d in (arg[2] or "very-easy,easy,medium"):gmatch("[^,]+") do diffs[#diffs + 1] = d end

local failures, total = 0, 0
local function fail(msg) failures = failures + 1; print("FAIL", msg) end

local function validate(data, res, label)
    local p, err = Puzzle.parse(data, "random-test")
    if not p then return fail(label .. " parse: " .. tostring(err)) end
    if not p.has_solution then return fail(label .. " no solution") end
    local placements = {}
    for i, s in ipairs(p.suspects) do placements[i] = s.sol end
    if next(Puzzle.conflicts(p, placements)) then return fail(label .. " solution breaks row/column/obstacle rules") end
    -- victim alone with the murderer
    local v = p.suspects[p.victim].sol
    local with = {}
    for i, s in ipairs(p.suspects) do
        if i ~= p.victim and p.cells[s.sol[1]][s.sol[2]].area == p.cells[v[1]][v[2]].area then with[#with + 1] = i end
    end
    if #with ~= 1 or with[1] ~= p.murderer then return fail(label .. " murderer is not alone with the victim") end
    -- uniqueness with the exhaustive counter (generous node limit)
    local cnt, sols, timed_out = S.countSolutions(res.pz, res.atoms, 2, 5000000)
    if timed_out or cnt ~= 1 then return fail(label .. " solutions: " .. cnt .. (timed_out and " (timeout)" or "")) end
    for j = 1, res.pz.n do
        if sols[1][j] ~= res.pz.sol[j] then return fail(label .. " unique solution differs from stored") end
    end
    -- parsed board matches the generator's model (multi-cell objects expanded)
    for x = 0, res.pz.ncell - 1 do
        local c = p.cells[res.pz.row[x] + 1][res.pz.col[x] + 1]
        if c.obj ~= res.pz.obj[x] or c.area ~= res.pz.area[x] then return fail(label .. " board mismatch") end
    end
    if #p.hints ~= res.pz.n then return fail(label .. " expected one hint per person") end
    -- "designed aha" cases: re-profile from the final atoms and re-check the accept filter
    if res.profile then
        local P = St.profile(res.pz, res.atoms, nil)
        if not St.accept(P, res.grade, res.grade) then return fail(label .. " aha case fails the accept filter") end
        if #St.midAhas(P) == 0 then return fail(label .. " aha case without a mid-solve aha") end
    end
end

print(string.format("%-6s %-10s %5s %8s %8s %8s %5s  %s", "size", "difficulty", "ok", "mean s", "max s", "attempts", "aha",
    "grades"))
for N = 5, 9 do
    for _, diff in ipairs(diffs) do
        local times, ok, grades, att, aha = {}, 0, {}, 0, 0
        for k = 1, per do
            local seed = 10000 * N + 100 * k + #diff
            total = total + 1
            local t = os.clock()
            local data, res = Gen.generate{ size = N, difficulty = diff, seed = seed }
            times[#times + 1] = os.clock() - t
            local label = string.format("%dx%d %s seed %d", N, N, diff, seed)
            if not data then
                fail(label .. " no case: " .. tostring(res))
            else
                local before = failures
                validate(data, res, label)
                if res.grade ~= diff then fail(label .. " graded " .. res.grade) end
                if failures == before then ok = ok + 1 end
                grades[res.grade] = (grades[res.grade] or 0) + 1
                att = att + res.attempts
                if res.profile then aha = aha + 1 end
            end
        end
        local sum, mx = 0, 0
        for _, t in ipairs(times) do sum = sum + t; mx = math.max(mx, t) end
        local g = {}
        for k, v in pairs(grades) do g[#g + 1] = k .. "=" .. v end
        table.sort(g)
        print(string.format("%dx%-4d %-10s %2d/%-2d %8.2f %8.2f %8.1f %5d  %s", N, N, diff, ok, per, sum / per, mx,
            att / per, aha, table.concat(g, " ")))
        io.stdout:flush()
    end
end
print(string.format("%d/%d generated cases OK", total - failures, total))
os.exit(failures == 0 and 0 or 1)
