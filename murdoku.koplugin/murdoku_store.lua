--[[--
Downloads and caches the Murdoku catalogue and puzzles, and stores progress.

Nothing from murdoku.com is bundled with the plugin: puzzles are fetched from
the same public files the website's player uses, then cached so they can be
played offline.
--]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local BASE_URL = "https://murdoku.com/play_puzzles/"

local Store = {}

local root = DataStorage:getDataDir() .. "/murdoku"
local puzzle_dir = root .. "/puzzles"
local patch_dir = root .. "/patches"
local random_dir = root .. "/random"
-- Our own cases ship with the plugin, in its cases/ folder.
local plugin_dir = (debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./")
local cases_dir = plugin_dir .. "cases"
-- Bundled translation patches for the Originals (one file per case+language,
-- same format as the site's patches). Kept out of cases/ so tools that glob
-- cases/*.json (parser tests, the generator's --check) only see full puzzles.
local translations_dir = plugin_dir .. "translations"

Store.SOURCE_SITE, Store.SOURCE_ORIGINAL, Store.SOURCE_RANDOM = "site", "original", "random"

-- Puzzle content languages. "en" is the base every case is served in; the rest
-- are the player languages of murdoku.com, which ship per-case translation
-- patches at /play_puzzles/{lang}/{id}-{lang}.json.
Store.LANGS = {
    { id = "en", label = "English" },
    { id = "fr", label = "Français" },
    { id = "es", label = "Español" },
    { id = "de", label = "Deutsch" },
    { id = "it", label = "Italiano" },
    { id = "nl", label = "Nederlands" },
    { id = "pl", label = "Polski" },
    { id = "pt", label = "Português" },
    { id = "ko", label = "한국어" },
    { id = "cs", label = "Čeština" },
    { id = "el", label = "Ελληνικά" },
    { id = "ca", label = "Català" },
    { id = "hu", label = "Magyar" },
    { id = "tr", label = "Türkçe" },
    { id = "no", label = "Norsk" },
    { id = "fi", label = "Suomi" },
    { id = "uk", label = "Українська" },
    { id = "ru", label = "Русский" },
    { id = "ro", label = "Română" },
    { id = "vi", label = "Tiếng Việt" },
    { id = "id", label = "Bahasa Indonesia" },
    { id = "ja", label = "日本語" },
    { id = "zh_hans", label = "简体中文" },
    { id = "ar", label = "العربية" },
}
local LANG_IDS = {}
for __, lang in ipairs(Store.LANGS) do LANG_IDS[lang.id] = true end

function Store.isLang(id) return type(id) == "string" and LANG_IDS[id] or false end

--- The selected content language, defaulting to KOReader's UI language when we
--- have puzzle translations for it.
function Store.getLanguage()
    local v = Store.getOption("language", nil)
    if Store.isLang(v) then return v end
    local ok, gettext = pcall(require, "gettext")
    if ok and gettext and type(gettext.current_language) == "string" then
        local code = gettext.current_language:match("^(%a%a)")
        if code and LANG_IDS[code] then return code end
    end
    return "en"
end

--- Where a case comes from, by id.
function Store.sourceOf(id)
    if type(id) ~= "string" then return Store.SOURCE_SITE end
    if id:match("^orig%-") then return Store.SOURCE_ORIGINAL end
    if id:match("^random%-") then return Store.SOURCE_RANDOM end
    return Store.SOURCE_SITE
end

local function ensureDirs()
    util.makePath(puzzle_dir)
    util.makePath(patch_dir)
end

local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function decodeJSON(text)
    local ok, rapidjson = pcall(require, "rapidjson")
    if ok and rapidjson then
        local ok2, data = pcall(rapidjson.decode, text)
        if ok2 and data then return data end
    end
    local json = require("json")
    local ok3, data = pcall(json.decode, text)
    if ok3 then return data end
    return nil
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function writeFile(path, s)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(s)
    f:close()
    return os.rename(tmp, path)
end

--- Synchronous HTTP GET. Returns body or nil, err.
local function httpGet(url)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, headers, status = socket.skip(1, http.request{
        url = url,
        method = "GET",
        headers = { ["Accept"] = "application/json" },
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if code ~= 200 then
        logger.warn("Murdoku: GET", url, "failed:", code, status)
        return nil, tostring(status or code)
    end
    return table.concat(sink)
end

-- "2026-10-25T23:00:00.000Z" -> unix seconds (UTC), or nil.
local function parseISO(s)
    if type(s) ~= "string" then return nil end
    local y, mo, d, h, mi, se = s:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then return nil end
    y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
    -- days from civil (Howard Hinnant's algorithm)
    y = mo <= 2 and y - 1 or y
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (mo + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(se)
end
Store.parseISO = parseISO

local DIFFICULTY_ORDER = { ["very-easy"] = 1, easy = 2, medium = 3, hard = 4, expert = 5 }
local DIFFICULTY_LABEL = {
    ["very-easy"] = "Very easy", easy = "Easy", medium = "Medium", hard = "Hard", expert = "Expert",
}
Store.DIFFICULTY_LABEL = DIFFICULTY_LABEL

local function guessDifficulty(entry)
    if entry.difficulty and DIFFICULTY_LABEL[entry.difficulty] then return entry.difficulty end
    local id = entry.id or ""
    for _, d in ipairs({ "very-easy", "easy", "medium", "hard", "expert" }) do
        if id:sub(-#d - 1) == "-" .. d then return d end
    end
    return nil
end

--- Normalise catalogue entries into what the menu needs.
-- lang: title language ("title_{lang}_" with fallback to the English title).
local function normaliseCatalog(raw, show_retired, lang)
    local list = type(raw) == "table" and (raw.puzzles or raw) or {}
    local now = os.time()
    local out = {}
    for _, e in ipairs(list) do
        local cat = e.category
        local playable = type(e.id) == "string"
            and (cat == nil or cat == "free")
            and not e.id:match("^promo%-")
        local release = parseISO(e.releaseAt)
        local leaving = parseISO(e.leavingAt)
        if playable and release and release > now then playable = false end
        local retired = leaving ~= nil and leaving < now
        if playable and (show_retired or not retired) then
            local diff = guessDifficulty(e)
            local title = lang and lang ~= "en" and e["title_" .. lang .. "_"] or nil
            if type(title) ~= "string" or trim(title) == "" then title = e.title_en_ end
            if type(title) ~= "string" or title == "" then title = e.id end
            table.insert(out, {
                id = e.id,
                source = Store.SOURCE_SITE,
                title = title,
                difficulty = diff,
                difficulty_rank = DIFFICULTY_ORDER[diff] or 9,
                size = e.gridSize,
                release = release or 0,
                retired = retired,
            })
        end
    end
    table.sort(out, function(a, b)
        if a.release ~= b.release then return a.release > b.release end
        return a.title < b.title
    end)
    return out
end

function Store.catalogPath() return root .. "/catalog.json" end

--- Cached catalogue (may be nil if never downloaded).
function Store.cachedCatalog(show_retired, lang)
    local text = readFile(Store.catalogPath())
    if not text then return nil end
    local raw = decodeJSON(text)
    if not raw then return nil end
    return normaliseCatalog(raw, show_retired, lang)
end

--- Download the catalogue (blocking). Returns list or nil, err.
function Store.fetchCatalog(show_retired, lang)
    ensureDirs()
    local body, err = httpGet(BASE_URL .. "_puzzleCatalog.json")
    if not body then return nil, err end
    local raw = decodeJSON(body)
    if not raw then return nil, "could not read catalogue" end
    writeFile(Store.catalogPath(), body)
    return normaliseCatalog(raw, show_retired, lang)
end

local function safeId(id)
    return (id:gsub("[^%w%-_]", "_"))
end

function Store.puzzlePath(id)
    local src = Store.sourceOf(id)
    if src == Store.SOURCE_ORIGINAL then return cases_dir .. "/" .. safeId(id) .. ".json" end
    if src == Store.SOURCE_RANDOM then return random_dir .. "/" .. safeId(id) .. ".json" end
    return puzzle_dir .. "/" .. safeId(id) .. ".json"
end

--- Translation patch for a site case in a given language.
-- Kept out of puzzle_dir on purpose: downloadedIds() scans that folder for
-- "*.json" and would mistake a patch for a playable case.
function Store.patchPath(id, lang)
    return patch_dir .. "/" .. safeId(id) .. "-" .. (lang or "en") .. ".json"
end

--- Bundled translation patch for an Original: translations/{id}-{lang}.json
-- ships with the plugin in the same format as the site's patches.
function Store.originalPatchPath(id, lang)
    return translations_dir .. "/" .. safeId(id) .. "-" .. (lang or "en") .. ".json"
end

function Store.isDownloaded(id)
    return lfs.attributes(Store.puzzlePath(id), "mode") == "file"
end

--- Whether this case has a translation patch for the language available
--- locally: bundled for Originals, downloaded for site cases. "en" (or nil)
--- needs no patch. Used to decide whether a cached case can be played in the
--- selected language or needs its patch re-downloaded first.
function Store.isTranslated(id, lang)
    if not lang or lang == "en" then return true end
    local path = Store.sourceOf(id) == Store.SOURCE_ORIGINAL
        and Store.originalPatchPath(id, lang) or Store.patchPath(id, lang)
    return lfs.attributes(path, "mode") == "file"
end

--- The bundled "Originals" (offline, from cases/index.json).
-- lang: when a bundled patch exists for it, the list shows its title too.
function Store.originals(lang)
    local raw = decodeJSON(readFile(cases_dir .. "/index.json") or "")
    local out = {}
    if type(raw) ~= "table" or type(raw.cases) ~= "table" then return out end
    local now = os.time()
    for _, e in ipairs(raw.cases) do
        local release = parseISO(e.releaseAt) or 0
        if type(e.id) == "string" and release <= now then
            local title = e.title or e.id
            if lang and lang ~= "en" then
                local patch = decodeJSON(readFile(Store.originalPatchPath(e.id, lang)) or "")
                if type(patch) == "table" and type(patch.CHARACTERS) == "table" then
                    local t = patch.CHARACTERS["title_" .. lang .. "_"]
                    if type(t) == "string" and trim(t) ~= "" then title = trim(t) end
                end
            end
            table.insert(out, {
                id = e.id,
                source = Store.SOURCE_ORIGINAL,
                title = title,
                difficulty = DIFFICULTY_LABEL[e.difficulty] and e.difficulty or nil,
                difficulty_rank = DIFFICULTY_ORDER[e.difficulty] or 9,
                size = e.gridSize,
                theme = e.theme,
                release = release,
            })
        end
    end
    return out
end

--- Saved random cases (generated on this device).
function Store.randomCases()
    local out = {}
    if lfs.attributes(random_dir, "mode") ~= "directory" then return out end
    for f in lfs.dir(random_dir) do
        local id = f:match("^(random%-.+)%.json$")
        if id then
            local path = random_dir .. "/" .. f
            local data = decodeJSON(readFile(path) or "")
            if type(data) == "table" then
                local C = data.CHARACTERS or {}
                local P = data.PROPERTIES or {}
                local meta = data.META or {}
                local w, h = tonumber(P.grid_w), tonumber(P.grid_h)
                table.insert(out, {
                    id = id,
                    source = Store.SOURCE_RANDOM,
                    title = C.title_en_ or id,
                    difficulty = DIFFICULTY_LABEL[meta.grade] and meta.grade or nil,
                    difficulty_rank = DIFFICULTY_ORDER[meta.grade] or 9,
                    size = w and h and (w .. "x" .. h) or nil,
                    release = tonumber(meta.created) or lfs.attributes(path, "modification") or 0,
                })
            end
        end
    end
    return out
end

--- Save a generated case (decoded table). Returns the path or nil, err.
function Store.saveRandom(id, data)
    util.makePath(random_dir)
    local ok, text = pcall(function()
        local okr, rapidjson = pcall(require, "rapidjson")
        if okr and rapidjson then return rapidjson.encode(data) end
        return require("json").encode(data)
    end)
    if not ok or not text then return nil, "could not encode case" end
    if not writeFile(Store.puzzlePath(id), text) then return nil, "could not write case" end
    return Store.puzzlePath(id)
end

function Store.deleteRandom(id)
    if Store.sourceOf(id) ~= Store.SOURCE_RANDOM then return false end
    os.remove(Store.puzzlePath(id))
    Store.clearState(id)
    return true
end
--- Overlay a translation patch (the site's /play_puzzles/{lang}/{id}-{lang}.json)
--- onto a base puzzle, section by section, like the site's own player does.
-- Patches carry translated room names and general clues under the *same* keys
-- as the base (room_name_k, general_clue_N), plus quote/title/hint fields
-- suffixed with the language. A patch may park a key in a different section
-- than the base keeps it in (the site stores general_clue_N in CHARACTERS but
-- patches carry it under PROPERTIES); such keys are written to the section
-- that owns them in the base so a later flatten sees the translation. Unknown
-- sections are ignored; META is never copied.
function Store.mergePatch(data, patch)
    if type(data) ~= "table" or type(patch) ~= "table" then return data end
    local sections = { "GRID", "OBJECT", "CHARACTERS", "PROPERTIES" }
    local owner = {}
    for _, section in ipairs(sections) do
        local s = data[section]
        if type(s) == "table" then
            for k in pairs(s) do
                if owner[k] == nil then owner[k] = section end
            end
        end
    end
    for _, section in ipairs(sections) do
        local src = patch[section]
        if type(src) == "table" then
            local dst = type(data[section]) == "table" and data[section] or {}
            for k, v in pairs(src) do
                local target
                if dst[k] ~= nil then
                    target = section
                elseif owner[k] then
                    target = owner[k]
                end
                if target then
                    local t = type(data[target]) == "table" and data[target] or {}
                    t[k] = v
                    data[target] = t
                else
                    dst[k] = v
                end
            end
            data[section] = dst
        end
    end
    for k, v in pairs(patch) do
        if type(k) == "string" and k ~= "META" and type(v) ~= "table" and data[k] == nil then
            data[k] = v
        end
    end
    return data
end
--- Returns decoded puzzle JSON from cache, overlaid with the language patch
--- when one exists: downloaded patches for site cases, bundled ones for
--- Originals. Returns nil when the base file is missing.
function Store.loadCachedPuzzle(id, lang)
    local text = readFile(Store.puzzlePath(id))
    if not text then return nil end
    local data = decodeJSON(text)
    if not data then return nil end
    if lang and lang ~= "en" then
        local path = Store.sourceOf(id) == Store.SOURCE_ORIGINAL
            and Store.originalPatchPath(id, lang) or Store.patchPath(id, lang)
        local ptext = readFile(path)
        if ptext then
            local patch = decodeJSON(ptext)
            if patch then Store.mergePatch(data, patch) end
        end
    end
    return data
end

--- Download a puzzle (blocking), with its translation patch when lang ~= "en".
-- The base is always saved; the patch is only kept when it downloads, so a
-- failed patch download falls back to the (already cached) English content.
-- Returns decoded data or nil, err.
function Store.fetchPuzzle(id, lang)
    ensureDirs()
    local body, err = httpGet(BASE_URL .. "en/" .. id .. ".json")
    if not body then return nil, err end
    local data = decodeJSON(body)
    if not data then return nil, "could not read puzzle" end
    writeFile(Store.puzzlePath(id), body)
    if lang and lang ~= "en" then
        local pbody = httpGet(BASE_URL .. lang .. "/" .. id .. "-" .. lang .. ".json")
        if pbody then
            local patch = decodeJSON(pbody)
            if patch then
                writeFile(Store.patchPath(id, lang), pbody)
                Store.mergePatch(data, patch)
            end
        end
    end
    return data
end

--- List ids of downloaded murdoku.com puzzles (for offline use when there's no catalogue).
function Store.downloadedIds()
    local ids = {}
    if lfs.attributes(puzzle_dir, "mode") ~= "directory" then return ids end
    for f in lfs.dir(puzzle_dir) do
        local id = f:match("^(.+)%.json$")
        if id then table.insert(ids, id) end
    end
    table.sort(ids)
    return ids
end

-- Progress & settings ---------------------------------------------------------

local settings
function Store.settings()
    if not settings then
        ensureDirs()
        settings = LuaSettings:open(root .. "/progress.lua")
    end
    return settings
end

function Store.getOption(name, default)
    local v = Store.settings():readSetting("option_" .. name)
    if v == nil then return default end
    return v
end

function Store.setOption(name, value)
    Store.settings():saveSetting("option_" .. name, value)
    Store.settings():flush()
end

function Store.loadState(id)
    return Store.settings():readSetting("state_" .. id)
end

function Store.saveState(id, state)
    Store.settings():saveSetting("state_" .. id, state)
    Store.settings():flush()
end

function Store.clearState(id)
    Store.settings():delSetting("state_" .. id)
    Store.settings():flush()
end

return Store
