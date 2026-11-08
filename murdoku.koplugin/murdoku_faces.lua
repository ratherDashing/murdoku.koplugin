--[[--
Suspect portraits composed from bundled Open Peeps parts (CC0, Pablo Stanley).

Each face is a plain SVG written once to the data dir, named after its part
spec, so the file name is unique per face (ImageWidget's cache ignores file
modification times). Cases from murdoku.com carry char_hair/char_facial/...
fields; for cases without them (Originals, Random) the look is derived from a
hash of the name, so a person always looks the same.
--]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local PLUGIN_DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
local PARTS = PLUGIN_DIR .. "/faces/parts/"
local CACHE = DataStorage:getDataDir() .. "/murdoku/faces/"

local MALE = { "short1", "short2", "short3", "short4", "short5", "flatTop", "pomp", "shaved2", "noHair1",
    "grayShort", "medium1", "dreads1", "afro", "cornrows", "twists", "mohawk" }
local FEMALE = { "long", "bun", "bangs", "longBangs", "medium2", "longCurly", "mediumBangs", "bun2", "buns",
    "grayBun", "mediumStraight", "longAfro", "bantuKnots", "twists2", "grayMedium", "medium3" }
local FACIAL = { "full", "full2", "full3", "full4", "goatee1", "goatee2", "chin", "moustache1", "moustache2",
    "moustache3", "moustache4", "moustache5", "moustache6", "moustache7", "moustache8", "moustache9" }
local GLASSES = { "glasses", "glasses2", "glasses3", "glasses4", "glasses5", "sunglasses", "sunglasses2" }
local FACES = { "calm", "serious", "suspicious", "smile", "concerned", "cheeky", "solemn", "driven" }
local HAIR = { "#2c1b18", "#4a312c", "#724133", "#a55728", "#b58143", "#d6b370", "#ecdcbf", "#e8e1e1" }
local HATS = { [3] = "hatHip", [1001] = "hatBeanie", [1003] = "hatBeanie", [1004] = "turban", [1005] = "hatHip" }

local Faces = {}

local function hash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
    return h
end

--- Part spec for a suspect: { head, face, facialHair?, accessories?, hair }.
function Faces.spec(s)
    local c = s.char
    if not c then
        local h = hash(s.name or "?")
        c = {
            hair = h % 16,
            haircolor = math.floor(h / 16) % 8,
            facial = (not s.female and math.floor(h / 128) % 3 == 0) and (math.floor(h / 384) % 16 + 1) or 0,
            accessory = (math.floor(h / 7000) % 4 == 0) and (math.floor(h / 28000) % 7 + 1) or 0,
            hat = (math.floor(h / 300000) % 9 == 0) and 3 or 0,
        }
    end
    local sex_f = s.female
    local heads = sex_f and FEMALE or MALE
    local sp = {}
    local hat = c.hat or 0
    sp.head = HATS[hat] or (hat ~= 0 and (hat % 2 == 1 and "hatBeanie" or "hatHip")) or heads[(c.hair or 0) % #heads + 1]
    sp.face = FACES[((c.hair or 0) + (c.haircolor or 0) + (c.facial or 0)) % #FACES + 1]
    if (c.facial or 0) ~= 0 and not sex_f then sp.facialHair = FACIAL[(c.facial - 1) % #FACIAL + 1] end
    if (c.accessory or 0) ~= 0 then
        sp.accessories = (c.accessory == 1) and "glasses" or GLASSES[c.accessory % #GLASSES + 1]
    end
    sp.hair = HAIR[(c.haircolor or 0) % #HAIR + 1]
    return sp
end

--- Short description of visible traits, e.g. "glasses · beard".
function Faces.traits(s)
    local sp = Faces.spec(s)
    local t = {}
    if sp.accessories then table.insert(t, sp.accessories:find("sun") and "sunglasses" or "glasses") end
    if sp.facialHair then table.insert(t, sp.facialHair:find("moustache") and "moustache" or "beard") end
    if sp.head:find("^hat") or sp.head == "turban" then table.insert(t, sp.head == "turban" and "turban" or "hat") end
    return t
end

local part_cache = {}
local function part(path)
    if part_cache[path] == nil then
        local f = io.open(PARTS .. path, "r")
        local svg = f and f:read("*a") or ""
        if f then f:close() end
        part_cache[path] = svg:match("^%s*<svg[^>]*>(.*)</svg>%s*$") or ""
    end
    return part_cache[path]
end

--- Path to the SVG file for suspect s (created on first use), or nil.
function Faces.file(s)
    local sp = Faces.spec(s)
    local key = table.concat({ sp.head, sp.face, sp.facialHair or "-", sp.accessories or "-", sp.hair:sub(2) }, "_")
    local fn = CACHE .. "v1_" .. key .. ".svg"
    if lfs.attributes(fn, "mode") == "file" then return fn end
    if lfs.attributes(CACHE, "mode") ~= "directory" then
        lfs.mkdir(DataStorage:getDataDir() .. "/murdoku")
        lfs.mkdir(CACHE)
    end
    local body = part("base.svg") .. part("head/" .. sp.head .. ".svg") .. part("face/" .. sp.face .. ".svg")
    if sp.facialHair then body = body .. part("facialHair/" .. sp.facialHair .. ".svg") end
    if sp.accessories then body = body .. part("accessories/" .. sp.accessories .. ".svg") end
    body = body:gsub("#SKIN0", "#ffffff"):gsub("#CLOTH0", "#ffffff"):gsub("#HAIR00", sp.hair)
    local f = io.open(fn, "w")
    if not f then return nil end
    f:write('<svg xmlns="http://www.w3.org/2000/svg" width="704" height="704" viewBox="0 0 704 704" fill="none">',
        body, "</svg>")
    f:close()
    return fn
end

return Faces
