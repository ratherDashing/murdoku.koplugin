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

local function ensureDirs()
    util.makePath(puzzle_dir)
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
local function normaliseCatalog(raw, show_retired)
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
            table.insert(out, {
                id = e.id,
                title = e.title_en_ or e.id,
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
function Store.cachedCatalog(show_retired)
    local text = readFile(Store.catalogPath())
    if not text then return nil end
    local raw = decodeJSON(text)
    if not raw then return nil end
    return normaliseCatalog(raw, show_retired)
end

--- Download the catalogue (blocking). Returns list or nil, err.
function Store.fetchCatalog(show_retired)
    ensureDirs()
    local body, err = httpGet(BASE_URL .. "_puzzleCatalog.json")
    if not body then return nil, err end
    local raw = decodeJSON(body)
    if not raw then return nil, "could not read catalogue" end
    writeFile(Store.catalogPath(), body)
    return normaliseCatalog(raw, show_retired)
end

local function safeId(id)
    return (id:gsub("[^%w%-_]", "_"))
end

function Store.puzzlePath(id)
    return puzzle_dir .. "/" .. safeId(id) .. ".json"
end

function Store.isDownloaded(id)
    return lfs.attributes(Store.puzzlePath(id), "mode") == "file"
end

--- Returns decoded puzzle JSON from cache, or nil.
function Store.loadCachedPuzzle(id)
    local text = readFile(Store.puzzlePath(id))
    if not text then return nil end
    return decodeJSON(text)
end

--- Download a puzzle (blocking). Returns decoded data or nil, err.
function Store.fetchPuzzle(id)
    ensureDirs()
    local body, err = httpGet(BASE_URL .. "en/" .. id .. ".json")
    if not body then return nil, err end
    local data = decodeJSON(body)
    if not data then return nil, "could not read puzzle" end
    writeFile(Store.puzzlePath(id), body)
    return data
end

--- List ids of downloaded puzzles (for offline use when there's no catalogue).
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
