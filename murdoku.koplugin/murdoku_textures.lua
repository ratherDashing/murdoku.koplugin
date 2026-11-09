-- Procedural, e-ink friendly area textures painted straight into a BlitBuffer (optional, off by default).
-- Every painter has the signature fn(bb, x, y, w, h, color) and uses ABSOLUTE screen
-- coordinates for its lattice, so a pattern flows seamlessly across the cells of one area.
local Blitbuffer = require("ffi/blitbuffer")
local T = {}

local function hash(i, j)
    local h = (i * 374761393 + j * 668265263) % 2147483647
    h = (h % 65521) * 40503 % 2147483647
    return h
end

-- clip-aware tiny rect
local function rect(bb, cx, cy, cw, ch, x, y, w, h, c)
    local x0, y0 = math.max(x, cx), math.max(y, cy)
    local x1, y1 = math.min(x + w, cx + cw), math.min(y + h, cy + ch)
    if x1 > x0 and y1 > y0 then bb:paintRect(x0, y0, x1 - x0, y1 - y0, c) end
end

local function lattice(x, y, w, h, sx, sy, fn)
    for j = math.floor(y / sy) - 1, math.floor((y + h) / sy) + 1 do
        for i = math.floor(x / sx) - 1, math.floor((x + w) / sx) + 1 do
            fn(i, j, i * sx, j * sy)
        end
    end
end

-- Grass: little "v" tufts on a jittered lattice.  (woods, yard, park, garden, golf holes: texture 10)
function T.grass(bb, x, y, w, h, c)
    c = c or Blitbuffer.COLOR_GRAY_B
    lattice(x, y, w, h, 22, 20, function(i, j, px, py)
        local r = hash(i, j)
        px = px + r % 13 + ((j % 2) * 11); py = py + math.floor(r / 13) % 9
        rect(bb, x, y, w, h, px, py, 2, 7, c)
        rect(bb, x, y, w, h, px - 3, py + 1, 2, 2, c); rect(bb, x, y, w, h, px - 4, py - 1, 2, 2, c)
        rect(bb, x, y, w, h, px + 3, py + 1, 2, 2, c); rect(bb, x, y, w, h, px + 4, py - 1, 2, 2, c)
    end)
end

-- Water: short horizontal "~" wavelets, staggered rows.  (lake, sea, river, pond, pool: texture 11/12 + blue colour)
function T.water(bb, x, y, w, h, c)
    c = c or Blitbuffer.COLOR_GRAY_B
    lattice(x, y, w, h, 30, 16, function(i, j, px, py)
        px = px + (j % 2) * 15
        local amp = { 0, -1, -2, -2, -1, 0, 1, 2, 2, 1, 0, -1, -2, -2, -1, 0 }
        for k = 1, #amp do rect(bb, x, y, w, h, px + k, py + amp[k], 1, 2, c) end
    end)
end

-- Sand: sparse random 2px dots.  (beach, desert, sand: texture 11 + yellow colour)
function T.sand(bb, x, y, w, h, c)
    c = c or Blitbuffer.COLOR_GRAY_B
    lattice(x, y, w, h, 9, 9, function(i, j, px, py)
        local r = hash(i, j)
        if r % 3 == 0 then rect(bb, x, y, w, h, px + r % 7, py + math.floor(r / 7) % 7, 2, 2, c) end
    end)
end

-- Wood planks: horizontal boards with staggered butt joints.  (cabin, porch, shed, dock, tavern: texture 3)
function T.wood(bb, x, y, w, h, c)
    c = c or Blitbuffer.COLOR_GRAY_B
    local ph = 20
    for j = math.floor(y / ph), math.floor((y + h) / ph) do
        local py = j * ph
        rect(bb, x, y, w, h, x, py, w, 1, c)
        local off = (hash(j, 7) % 5) * 23
        for px = math.floor((x - off) / 110) * 110 + off, x + w, 110 do
            rect(bb, x, y, w, h, px, py, 1, ph, c)
        end
        -- a faint grain dash per board segment
        rect(bb, x, y, w, h, x + (hash(j, 3) % 60), py + 9, 14, 1, c)
    end
end

-- Tiles: square grid, 3 tiles per 90 px cell.  (kitchen, bathroom, restroom: textures 1/4/8/15/16/29)
function T.tiles(bb, x, y, w, h, c)
    c = c or Blitbuffer.COLOR_GRAY_D
    local s = 30
    for px = math.floor(x / s) * s, x + w, s do rect(bb, x, y, w, h, px, y, 1, h, c) end
    for py = math.floor(y / s) * s, y + h, s do rect(bb, x, y, w, h, x, py, w, 1, c) end
end

-- Cobbles / stone path: small rings on a jittered lattice.  (path, rocky shore, courtyard, cliffs: texture 2/21/22)
function T.cobble(bb, x, y, w, h, c)
    c = c or Blitbuffer.COLOR_GRAY_B
    lattice(x, y, w, h, 20, 18, function(i, j, px, py)
        local r = hash(i, j)
        local cx, cy = px + (j % 2) * 10 + r % 4, py + math.floor(r / 4) % 4
        local rad = 6 + r % 3
        -- ring = 4 short arcs approximated with rects (paintCircle cannot be clipped)
        rect(bb, x, y, w, h, cx - rad, cy - 2, 1, 4, c); rect(bb, x, y, w, h, cx + rad, cy - 2, 1, 4, c)
        rect(bb, x, y, w, h, cx - 2, cy - rad, 4, 1, c); rect(bb, x, y, w, h, cx - 2, cy + rad, 4, 1, c)
        rect(bb, x, y, w, h, cx - rad + 1, cy - rad + 2, 2, 2, c); rect(bb, x, y, w, h, cx + rad - 2, cy - rad + 2, 2, 2, c)
        rect(bb, x, y, w, h, cx - rad + 1, cy + rad - 3, 2, 2, c); rect(bb, x, y, w, h, cx + rad - 2, cy + rad - 3, 2, 2, c)
    end)
end

-- Canvas / carpet: sparse diagonal hatching.  (tent: texture 7; carpets)
function T.hatch(bb, x, y, w, h, c)
    c = c or Blitbuffer.COLOR_GRAY_D
    local s = 14
    for k = math.floor((x + y) / s) * s, x + y + w + h, s do
        for t = 0, w + h, 2 do
            local px, py = k - (y + t), y + t
            rect(bb, x, y, w, h, px, py, 2, 2, c)
        end
    end
end

-- Suggested texture-id -> painter mapping (ids from room_texture_<k>; colour/name refine 11 and 12).
T.by_id = { [1] = "tiles", [2] = "cobble", [3] = "wood", [4] = "tiles", [7] = "hatch", [8] = "tiles", [10] = "grass",
            [11] = "sand_or_water", [12] = "water_or_path", [15] = "tiles", [16] = "tiles", [19] = "sand", [21] = "cobble",
            [22] = "cobble", [29] = "tiles" }

-- Pick a painter from an area's name.
local BY_WORD = {
    grass = { "wood", "forest", "garden", "park", "yard", "meadow", "field", "lawn", "orchard", "farm",
        "pasture", "golf", "green", "grove", "jungle", "hill", "camp" },
    water = { "lake", "sea", "river", "pond", "pool", "water", "bay", "ocean", "lagoon", "stream", "creek", "harbor", "harbour" },
    sand = { "beach", "sand", "desert", "dune", "shore", "arena" },
    wood = { "cabin", "porch", "dock", "shed", "deck", "tavern", "barn", "attic", "pier", "stage", "boardwalk", "saloon" },
    tiles = { "kitchen", "bath", "restroom", "toilet", "lab", "shower", "locker", "laundry", "pantry" },
    cobble = { "path", "courtyard", "road", "street", "plaza", "trail", "square", "alley", "cave", "patio", "platform" },
}

function T.forName(name)
    name = (name or ""):lower()
    -- "wood" must not match "woods" (forest) as planks
    if name:find("woods") then return T.grass end
    for painter, words in pairs(BY_WORD) do
        for _, w in ipairs(words) do
            if name:find(w, 1, true) then return T[painter] end
        end
    end
end

return T
