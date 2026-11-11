--[[--
Tests for the multi-language puzzle loading (Fase 1: site translation patches).

Run from the plugin folder:   luajit tests/test_i18n.lua

Always runs synthetic fixtures; when local Lua fixtures generated from real
murdoku.com downloads exist (tests/fixtures/real.lua, not committed) it also
checks the real merge/parse against them. Build them with:

  curl -s .../play_puzzles/en/puzzle-blackout.json   -o blackout-en.json
  curl -s .../play_puzzles/es/puzzle-blackout-es.json -o blackout-es.json
  curl -s .../play_puzzles/fr/puzzle-blackout-fr.json -o blackout-fr.json
  python3 tests/fixtures/make_fixtures.py tests/fixtures/real.lua \
      blackout-en.json blackout-es.json blackout-fr.json
--]]

local script_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
-- Works both from the plugin folder (plugin at ../) and from the repo root
-- (plugin at ../murdoku.koplugin/).
package.path = script_dir .. "../?.lua;" .. script_dir .. "../murdoku.koplugin/?.lua;"
    .. package.path

local TESTDIR = os.getenv("MURDOKU_TESTDIR") or "/tmp/murdoku-test"

require("tests.stubs").apply(TESTDIR)

local Store = require("murdoku_store")
local Puzzle = require("murdoku_puzzle")

local passed, failed = 0, 0
local function check(cond, name, extra)
    if cond then
        passed = passed + 1
        print("  ok   " .. name)
    else
        failed = failed + 1
        print("  FAIL " .. name .. (extra and ("  (" .. tostring(extra) .. ")") or ""))
    end
end

-- Synthetic v2 puzzle: 5x5, one area, 4 suspects (last = victim) on the diagonal.
local function basePuzzle()
    local C = {}
    for r = 0, 4 do
        for c = 0, 4 do
            C["room_code_" .. r .. "_" .. c] = "1"
            C["room_objects_" .. r .. "_" .. c] = "0"
        end
    end
    C.title_en_ = "Test Case"
    C.room_name_1 = "Kitchen"
    for i = 0, 3 do
        C["char_name_" .. i] = ("Person%d"):format(i + 1)
        C["char_sex_" .. i] = "0"
        C["char_quote_en_" .. i] = ("Quote %d."):format(i)
        C["solution_x_" .. i] = tostring(i)
        C["solution_y_" .. i] = tostring(i)
    end
    return {
        PROPERTIES = { puzzle_version = "2", grid_w = "5", grid_h = "5",
            total_char = "4", total_chars = "4", murderer = "0",
            ["player_hint_1_en"] = "Hint one.", ["player_hint_2_en"] = "Hint two." },
        CHARACTERS = C,
    }
end

print("== parse: English")
local p = Puzzle.parse(basePuzzle(), "test")
check(p and p.title == "Test Case", "en title", p and p.title)
check(p.suspects[1].clue == "Quote 0.", "en quote 1", p.suspects[1].clue)
check(p.rooms[1].name == "Kitchen", "en room name", p.rooms[1].name)
check(p.hints[1] == "Hint one." and p.hints[2] == "Hint two.", "en hints")
check(p.has_solution == true, "has solution")

print("== parse: language fallback (no patch)")
local base = basePuzzle()
p = Puzzle.parse(base, "test", "es")
check(p.title == "Test Case", "es title falls back to en")
check(p.suspects[2].clue == "Quote 1.", "es quote falls back to en")
check(p.hints[1] == "Hint one.", "es hint falls back to en")

print("== mergePatch + parse: Spanish")
local esPatch = {
    CHARACTERS = {
        title_es_ = "Caso de prueba",
        room_name_1 = "Cocina",
        ["char_quote_es_1"] = "Cita uno.",   -- quote 0 left empty on purpose
    },
    PROPERTIES = { ["player_hint_1_es"] = "Pista uno." },
}
base = basePuzzle()
Store.mergePatch(base, esPatch)
p = Puzzle.parse(base, "test", "es")
check(p.title == "Caso de prueba", "es title", p.title)
check(p.rooms[1].name == "Cocina", "es room name (same key as base)", p.rooms[1].name)
check(p.suspects[1].clue == "Quote 0.", "empty es quote falls back to en", p.suspects[1].clue)
check(p.suspects[2].clue == "Cita uno.", "es quote 2", p.suspects[2].clue)
check(p.suspects[3].clue == "Quote 2.", "missing es quote falls back to en", p.suspects[3].clue)
check(p.hints[1] == "Pista uno.", "es hint 1", p.hints[1])
check(p.hints[2] == "Hint two.", "es hint 2 falls back to en", p.hints[2])

print("== mergePatch: safety")
local merged = Store.mergePatch({ PROPERTIES = { a = "1" }, META = { id = "x" } },
    { CHARACTERS = { b = "2" }, PROPERTIES = { c = "3" }, META = { id = "evil" } })
check(merged.PROPERTIES.a == "1" and merged.PROPERTIES.c == "3", "sections merged")
check(merged.CHARACTERS.b == "2", "section added when missing")
check(merged.META.id == "x", "META never overwritten")
check(Store.mergePatch(nil, esPatch) == nil, "nil base tolerated")
check(Store.mergePatch(basePuzzle(), nil) ~= nil, "nil patch tolerated")

print("== Store.getLanguage")
os.remove(TESTDIR .. "/murdoku/progress.lua")
check(Store.getLanguage() == "en", "default is en (no gettext in tests)", Store.getLanguage())
Store.setOption("language", "es")
check(Store.getLanguage() == "es", "stored option wins", Store.getLanguage())
Store.setOption("language", "zz")
check(Store.getLanguage() == "en", "unknown code ignored", Store.getLanguage())
check(Store.isLang("ca") and not Store.isLang("EN"), "isLang")

print("== catalog titles per language")
os.execute("mkdir -p '" .. TESTDIR .. "/murdoku'")
local cat = io.open(Store.catalogPath(), "w")
cat:write([[{"puzzles":[
  {"id":"puzzle-x","category":"free","releaseAt":"2026-01-01T00:00:00.000Z","gridSize":"5x5",
   "title_en_":"X Case","title_es_":"Caso X"},
  {"id":"puzzle-y","category":"free","releaseAt":"2026-01-01T00:00:00.000Z","gridSize":"5x5",
   "title_en_":"Y Case","title_es_":"   "}
]}]])
cat:close()
local list = Store.cachedCatalog(false, "es")
check(list[1].title == "Caso X", "es catalog title", list[1] and list[1].title)
check(list[2].title == "Y Case", "blank es title falls back to en", list[2] and list[2].title)
list = Store.cachedCatalog(false, "en")
check(list[1].title == "X Case", "en catalog title", list[1] and list[1].title)

print("== loadCachedPuzzle with patch from disk")
os.execute("mkdir -p '" .. TESTDIR .. "/murdoku/puzzles' '" .. TESTDIR .. "/murdoku/patches'")
local f = io.open(Store.puzzlePath("test"), "wb")
f:write([[{"PROPERTIES":{"puzzle_version":"2","grid_w":"5","grid_h":"5","murderer":"0"},"CHARACTERS":{"title_en_":"Disk Case"}}]])
f:close()
local pf = io.open(Store.patchPath("test", "es"), "wb")
pf:write([[{"CHARACTERS":{"title_es_":"Caso de disco"}}]])
pf:close()
local data = Store.loadCachedPuzzle("test", "es")
check(data and data.CHARACTERS.title_es_ == "Caso de disco", "patch loaded from disk")
data = Store.loadCachedPuzzle("test")
check(data and data.CHARACTERS.title_es_ == nil, "no language -> base only")

-- Real fixtures (murdoku.com content, generated locally, not committed)
local ok_real, real = pcall(dofile, script_dir .. "fixtures/real.lua")
if ok_real and type(real) == "table" and real["blackout-en"] then
    print("== real murdoku.com fixture (puzzle-blackout)")
    local en, es, fr = real["blackout-en"], real["blackout-es"], real["blackout-fr"]
    local pen = Puzzle.parse(en, "puzzle-blackout")
    check(pen.title == "Blackout", "en title", pen.title)
    local pes = Puzzle.parse(Store.mergePatch(en, es), "puzzle-blackout", "es")
    check(pes.title == "El Apagón", "es title", pes.title)
    check(pes.suspects[1].clue == "Estaba solo.", "es quote 1", pes.suspects[1].clue)
    local names = {}
    for __, room in pairs(pes.rooms) do names[#names + 1] = room.name end
    local found = false
    for __, n in ipairs(names) do if n == "Salón" then found = true end end
    check(found and #names > 0, "es room names translated", table.concat(names, " | "))
    local gen = {}
    for __, t in ipairs(pes.general_clues) do gen[#gen + 1] = t end
    check(gen[1] == "Había exactamente una persona en una cama.", "es general clue", gen[1])
    check(#pes.hints > 0 and pes.hints[1]:find("empezar", 1, true) ~= nil, "es hints", pes.hints[1])
    local pfr = Puzzle.parse(Store.mergePatch(en, fr), "puzzle-blackout", "fr")
    check(pfr.suspects[1].clue == "Il était seul.", "fr quote 1", pfr.suspects[1].clue)
    check(pfr.title ~= nil and pfr.title ~= "", "fr title present", pfr.title)
    -- sanity: same grid & solution in both languages
    check(pes.suspects[1].sol[1] == pen.suspects[1].sol[1]
        and pes.suspects[1].sol[2] == pen.suspects[1].sol[2], "solution identical across languages")
    check(pes.murderer == pen.murderer, "murderer identical across languages")
else
    print("== real murdoku.com fixture: not present, skipped")
end

-- Bundled Originals in Spanish (Fase 2): cases/{id}-es.json, verified against
-- the English base with real data committed to the repo.
local function eq(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if b[k] == nil or not eq(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local PILOT = { "orig-a-thorny-problem", "orig-a-will-and-a-way", "orig-bear-country",
    "orig-black-run", "orig-canoe-trip", "orig-delayed-departure", "orig-exam-day",
    "orig-fog-in-the-harbour", "orig-fog-on-the-rocks", "orig-grave-matters",
    "orig-last-orders", "orig-message-in-a-bottle", "orig-mosquito-season",
    "orig-muddy-boots", "orig-night-of-the-mummy", "orig-opening-night",
    "orig-reunion-night", "orig-room-service", "orig-rum-and-rope", "orig-tea-for-two",
    "orig-the-bell-tolls", "orig-the-curators-secret", "orig-the-final-act",
    "orig-the-frozen-lake", "orig-the-keepers-last-watch", "orig-the-last-dinner-party",
    "orig-the-midnight-special", "orig-the-night-express", "orig-the-penthouse-suite",
    "orig-the-scarecrow-knows" }
local SAME_IN_ES = { Suite = true, Bar = true }

print("== bundled Originals: Spanish patches (Fase 2)")
for __, id in ipairs(PILOT) do
    local ben = Store.loadCachedPuzzle(id)
    local bes = Store.loadCachedPuzzle(id, "es")
    check(ben and bes, id .. ": base + bundled patch load")
    if ben and bes then
        check(Store.originalPatchPath(id, "es"):find("%-es%.json$") ~= nil, id .. ": patch path shape")
        local pen = Puzzle.parse(ben, id)
        local pes = Puzzle.parse(bes, id, "es")
        check(pes.title ~= nil and pes.title ~= "" and pes.title ~= pen.title,
            id .. ": title translated", pes.title)
        check(#pen.suspects == #pes.suspects and #pen.hints == #pes.hints
            and #pen.general_clues == #pes.general_clues, id .. ": same counts")
        local cells_ok = true
        for r = 1, #pen.cells do
            for c = 1, #pen.cells[r] do
                if pen.cells[r][c].area ~= pes.cells[r][c].area
                    or pen.cells[r][c].obj ~= pes.cells[r][c].obj then
                    cells_ok = false
                end
            end
        end
        check(cells_ok, id .. ": identical areas and objects")
        local sols_ok = true
        for i, s in ipairs(pen.suspects) do
            if not eq(s.sol, pes.suspects[i].sol) then sols_ok = false end
        end
        check(sols_ok and pen.murderer == pes.murderer, id .. ": identical solution and murderer")
        check(pes.suspects[1].clue:find("She was", 1, true) == nil
            and pes.suspects[1].clue:find("He was", 1, true) == nil,
            id .. ": quotes in Spanish", pes.suspects[1].clue)
        local en_names = {}
        for __, room in pairs(pen.rooms) do en_names[room.name] = true end
        local stray = 0
        for __, room in pairs(pes.rooms) do
            if en_names[room.name] and not SAME_IN_ES[room.name] then stray = stray + 1 end
        end
        check(stray == 0, id .. ": room names translated")
    end
end
-- objectInfo follows the language of the last parsed puzzle
local before_lang = Puzzle.current_lang
Puzzle.current_lang = "es"
check(Puzzle.objectInfo(1).name == "Planta", "objectInfo es name", Puzzle.objectInfo(1).name)
check(Puzzle.objectInfo(9).name == "Cajón" and Puzzle.objectInfo(42).name == "Caja",
    "objectInfo es Crate/Box", tostring(Puzzle.objectInfo(9).name) .. "/" .. tostring(Puzzle.objectInfo(42).name))
Puzzle.current_lang = "en"
check(Puzzle.objectInfo(1).name == "Plant", "objectInfo en name")
check(Puzzle.objectInfo(9).name == "Crate" and Puzzle.objectInfo(42).name == "Box",
    "objectInfo en Crate/Box")
Puzzle.current_lang = before_lang

-- Store.isTranslated: patch availability for the selected language
local lfs = require("libs/libkoreader-lfs")
local real_attr, present = lfs.attributes, {}
lfs.attributes = function(path, what)
    if what == "mode" and present[path] then return "file" end
    return real_attr(path, what)
end
check(Store.isTranslated("puzzle-x") == true, "isTranslated en default")
check(Store.isTranslated("puzzle-x", "en") == true, "isTranslated en explicit")
check(Store.isTranslated("puzzle-x", "ca") == false, "isTranslated site patch absent")
present[Store.patchPath("puzzle-x", "ca")] = true
check(Store.isTranslated("puzzle-x", "ca") == true, "isTranslated site patch present")
present[Store.patchPath("puzzle-x", "ca")] = nil
present[Store.originalPatchPath("orig-mosquito-season", "es")] = true
check(Store.isTranslated("orig-mosquito-season", "es") == true, "isTranslated original bundled")
present[Store.originalPatchPath("orig-mosquito-season", "es")] = nil
check(Store.isTranslated("orig-mosquito-season", "es") == false, "isTranslated original missing")
lfs.attributes = real_attr

-- LANGS sanity: 24 site languages, unique ids and labels, en first
local seen_ids, seen_labels = {}, {}
for __, lang in ipairs(Store.LANGS) do
    seen_ids[lang.id] = (seen_ids[lang.id] or 0) + 1
    seen_labels[lang.label] = true
end
local dup, bad = nil, nil
for id, n in pairs(seen_ids) do
    if n > 1 or id == "" or type(id) ~= "string" then dup = id end
end
if seen_labels[""] or seen_labels[true] then bad = true end
check(#Store.LANGS == 24 and Store.LANGS[1].id == "en", "LANGS count and en first")
check(dup == nil, "LANGS unique valid ids", tostring(dup))
check(bad == nil, "LANGS labels non-empty")
check(Store.isLang("ca") and Store.isLang("zh_hans") and not Store.isLang("xx"),
    "isLang covers new languages")

-- list titles per language from the bundled patches
local originals = Store.originals("es")
local titles = {}
for __, e in ipairs(originals) do titles[e.id] = e.title end
check(titles["orig-mosquito-season"] == "Temporada de mosquitos",
    "originals(es) title", titles["orig-mosquito-season"])
check(Store.originals()[1].title ~= nil, "originals() without lang still works")

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
