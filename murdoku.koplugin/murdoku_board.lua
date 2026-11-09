--[[--
Custom-painted widgets for the Murdoku game screen:
  * Board      – the crime scene grid
  * SuspectBar – tappable suspect chips

All drawing is done straight onto the blitbuffer with greys only, so it stays
crisp on e-ink.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText = require("ui/rendertext")
local Size = require("ui/size")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Puzzle = require("murdoku_puzzle")
local Screen = Device.screen

local C = Blitbuffer
local AREA_TINTS = { C.COLOR_WHITE, C.COLOR_GRAY_E, C.Color8(0xF6), C.COLOR_GRAY_D }
-- Squares nobody can stand on: dark fill, white icon/label.
local BLOCKED = C.Color8(0x58)

-- Font:getFace() scales sizes by DPI; we want exact pixel sizes.
local function face(name, px)
    local unit = Screen:scaleBySize(1000) / 1000
    return Font:getFace(name, math.max(5, math.floor(px / unit)))
end

local function textWidth(f, text, bold)
    return RenderText:sizeUtf8Text(0, Screen:getWidth(), f, text, true, bold).x
end

-- Shrink text (by abbreviating) until it fits in max_w.
local function fitText(f, text, max_w, bold)
    if textWidth(f, text, bold) <= max_w then return text end
    -- try abbreviations: "Lily Pad" -> "Lily", then first letters
    local first = text:match("^(%S+)")
    if first and first ~= text and textWidth(f, first, bold) <= max_w then return first end
    for n = #text - 1, 2, -1 do
        local s = text:sub(1, n):gsub("[%s%p]+$", "") .. "…"
        if textWidth(f, s, bold) <= max_w then return s end
    end
    return ""
end

-- Draw text centred at (cx, cy).
local function drawCentered(bb, f, text, cx, cy, color, bold)
    if text == "" then return end
    local w = textWidth(f, text, bold)
    local h, asc = f.ftsize:getHeightAndAscender()
    local baseline = math.floor(cy - h / 2 + asc)
    RenderText:renderUtf8Text(bb, math.floor(cx - w / 2), baseline, f, text, true, bold, color)
end

local function drawLeft(bb, f, text, x, top, color, bold)
    if text == "" then return end
    local _, asc = f.ftsize:getHeightAndAscender()
    RenderText:renderUtf8Text(bb, x, math.floor(top + asc), f, text, true, bold, color)
end

-- Dotted rectangle outline (used for carpets).
local function dottedRect(bb, x, y, w, h, color, dot, gap)
    for i = x, x + w - dot, dot + gap do
        bb:paintRect(i, y, dot, dot, color)
        bb:paintRect(i, y + h - dot, dot, dot, color)
    end
    for j = y, y + h - dot, dot + gap do
        bb:paintRect(x, j, dot, dot, color)
        bb:paintRect(x + w - dot, j, dot, dot, color)
    end
end

-- Thick diagonal cross.
local function drawCross(bb, x, y, size, thick, color)
    for i = 0, size - thick do
        bb:paintRect(x + i, y + i, thick, thick, color)
        bb:paintRect(x + size - thick - i, y + i, thick, thick, color)
    end
end

--------------------------------------------------------------------------------
-- Board
--------------------------------------------------------------------------------

local Board = InputContainer:extend{
    puzzle = nil,
    game = nil,      -- owner, provides state & callbacks
    width = nil,     -- max width available
    height = nil,    -- max height available
}

function Board:init()
    local p = self.puzzle
    -- Edge labels read "R1".."Rn" down the side and "C1".."Cn" across the top.
    local lsz = math.floor(math.min(self.width, self.height) * 0.032)
    lsz = math.max(lsz, Screen:scaleBySize(11))
    -- keep "C16" inside its column on big boards
    local approx = math.min(self.width / (p.w + 0.6), self.height / (p.h + 0.4))
    lsz = math.min(lsz, math.floor(approx * 0.36))
    self.f_label = face("NotoSans-Regular.ttf", lsz)
    local lh = self.f_label.ftsize:getHeightAndAscender()
    self.label_h = math.floor(lh * 1.15)
    self.label_w = textWidth(self.f_label, "R" .. p.h) + math.floor(lsz * 0.5)
    local cell = math.floor(math.min(
        (self.width - self.label_w) / p.w,
        (self.height - self.label_h) / p.h))
    self.cell = cell
    self.grid_w = cell * p.w
    self.grid_h = cell * p.h
    self.dimen = Geom:new{ x = 0, y = 0, w = self.grid_w + self.label_w, h = self.grid_h + self.label_h }

    self.thick = math.max(3, math.floor(cell / 14))
    self.thin = 1
    self.f_letter = face("NotoSans-Bold.ttf", cell * 0.62)
    self.f_object = face("NotoSans-Regular.ttf", math.max(10, cell * 0.2))
    self.f_object_small = face("NotoSans-Regular.ttf", math.max(9, cell * 0.15))
    self.f_room = face("NotoSans-Bold.ttf", math.max(9, cell * 0.17))
    self.f_room_small = face("NotoSans-Bold.ttf", math.max(8, cell * 0.13))
    self.f_note = face("NotoSans-Bold.ttf", math.max(9, cell * 0.21))

    self:computeTints()
    self:computeRoomLabels()

    local range = function() return self.dimen end
    self.ges_events = {
        TapBoard = { GestureRange:new{ ges = "tap", range = range } },
        HoldBoard = { GestureRange:new{ ges = "hold", range = range } },
        SwipeBoard = { GestureRange:new{ ges = "swipe", range = range } },
    }
end

-- Greedy colouring so neighbouring areas get different light greys.
function Board:computeTints()
    local p = self.puzzle
    local neighbours = {}
    for r = 1, p.h do
        for c = 1, p.w do
            local a = p.cells[r][c].area
            neighbours[a] = neighbours[a] or {}
            for _, d in ipairs({ { 0, 1 }, { 1, 0 } }) do
                local n = p.cells[r + d[1]] and p.cells[r + d[1]][c + d[2]]
                if n and n.area ~= a then
                    neighbours[a][n.area] = true
                    neighbours[n.area] = neighbours[n.area] or {}
                    neighbours[n.area][a] = true
                end
            end
        end
    end
    local areas = {}
    for a in pairs(p.rooms) do table.insert(areas, a) end
    table.sort(areas)
    self.tint = {}
    for _, a in ipairs(areas) do
        local used = {}
        for n in pairs(neighbours[a] or {}) do
            if self.tint[n] then used[self.tint[n]] = true end
        end
        local pick = 1
        while used[pick] and pick < #AREA_TINTS do pick = pick + 1 end
        self.tint[a] = pick
    end
end

-- Each area's name is written at its top-left cell, spanning the run of
-- same-area cells to the right.
function Board:computeRoomLabels()
    -- Each area's name goes at the start of its widest horizontal run of
    -- squares (topmost, then leftmost on ties), so long names get room.
    local p = self.puzzle
    self.room_label = {}
    local best = {}
    for r = 1, p.h do
        local c = 1
        while c <= p.w do
            local cell = p.cells[r][c]
            local run = 1
            while c + run <= p.w and p.cells[r][c + run].area == cell.area do run = run + 1 end
            if not cell.void and p.rooms[cell.area] then
                local b = best[cell.area]
                if not b or run > b.span then best[cell.area] = { r = r, c = c, span = run } end
            end
            c = c + run
        end
    end
    for area, b in pairs(best) do
        self.room_label[b.r .. "," .. b.c] = { name = p.rooms[area].name, span = b.span }
    end
end

-- Pick the biggest font that fits the whole name, else abbreviate.
function Board:objectLabel(name, max_w)
    if textWidth(self.f_object, name) <= max_w then return self.f_object, name end
    if textWidth(self.f_object_small, name) <= max_w then return self.f_object_small, name end
    return self.f_object_small, fitText(self.f_object_small, name, max_w)
end

function Board:cellAt(x, y)
    local gx = x - self.dimen.x - self.label_w
    local gy = y - self.dimen.y - self.label_h
    if gx < 0 or gy < 0 or gx >= self.grid_w or gy >= self.grid_h then return nil end
    return math.floor(gy / self.cell) + 1, math.floor(gx / self.cell) + 1
end

function Board:cellRect(r, c)
    return self.dimen.x + self.label_w + (c - 1) * self.cell,
           self.dimen.y + self.label_h + (r - 1) * self.cell
end

-- Object on a square: an icon filling most of it (white on the dark fill for
-- obstacles, black on light for things you can stand on). Falls back to the
-- object's name if there is no icon.
local lfs = require("libs/libkoreader-lfs")
local ICON_DIR = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".") .. "/icons/"

function Board:icon(id, white, size)
    self.icons = self.icons or {}
    local key = id .. (white and "w" or "b") .. size
    local w = self.icons[key]
    if w == nil then
        local fn = ICON_DIR .. (white and "w/" or "") .. id .. ".svg"
        if lfs.attributes(fn, "mode") == "file" then
            local ImageWidget = require("ui/widget/imagewidget")
            w = ImageWidget:new{ file = fn, width = size, height = size, alpha = true, is_icon = true }
        else
            w = false
        end
        self.icons[key] = w
    end
    return w
end

function Board:paintObject(bb, id, obj, blocked, cx, cy, cs, marked)
    local pad = math.max(2, math.floor(cs * 0.08))
    local size = math.floor(cs * (blocked and 0.72 or 0.62))
    local img = self:icon(id, blocked, size)
    if img then
        local ix = math.floor(cx + (cs - size) / 2)
        local iy = math.floor(cy + (cs - size) / 2 + (blocked and 0 or cs * 0.06))
        img:paintTo(bb, ix, iy)
        if marked then bb:lightenRect(ix, iy, size, size, 0.65) end
        return
    end
    local f, label = self:objectLabel(obj.name, cs - 2 * pad)
    if blocked then
        drawCentered(bb, f, label, cx + cs / 2, cy + cs / 2, C.COLOR_WHITE)
    elseif not marked then
        local fh = self.f_object.ftsize:getHeightAndAscender()
        local bh = math.floor(fh + pad)
        local by = math.floor(cy + cs - pad - bh)
        bb:paintBorder(cx + pad, by, cs - 2 * pad, bh, 2, C.COLOR_GRAY_5)
        drawCentered(bb, f, label, cx + cs / 2, by + bh / 2, C.COLOR_GRAY_2)
    end
end

local Textures = require("murdoku_textures")

function Board:paintTexture(bb, cell, cx, cy, cs)
    if not self.game.options.textures then return end
    self.tex = self.tex or {}
    local t = self.tex[cell.area]
    if t == nil then
        local room = self.puzzle.rooms[cell.area]
        t = Textures.forName(room and room.name) or false
        self.tex[cell.area] = t
    end
    if t then
        local tint = self.tint[cell.area]
        t(bb, cx, cy, cs, cs, tint == 4 and C.Color8(0xC4) or C.Color8(0xDD))
    end
end

-- Clue highlight: a light frame inside the square.
function Board:paintHighlight(bb, cx, cy, cs)
    local t = math.max(3, math.floor(cs / 14))
    local inset = math.max(2, math.floor(cs * 0.06)) + math.floor(self.thick / 2)
    bb:paintBorder(cx + inset, cy + inset, cs - 2 * inset, cs - 2 * inset, t, C.COLOR_GRAY_6)
end

function Board:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local p, g = self.puzzle, self.game
    local state = g.state
    local cs = self.cell
    local ox, oy = x + self.label_w, y + self.label_h
    local opts = g.options

    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C.COLOR_WHITE)

    -- row / column numbers
    for c = 1, p.w do
        drawCentered(bb, self.f_label, "C" .. c, ox + (c - 0.5) * cs, y + self.label_h * 0.45, C.COLOR_GRAY_3)
    end
    for r = 1, p.h do
        drawCentered(bb, self.f_label, "R" .. r, x + (self.label_w - self.thick) / 2, oy + (r - 0.5) * cs, C.COLOR_GRAY_3)
    end

    local occupant = {}
    for i, pos in pairs(state.placed) do
        occupant[pos[1] .. "," .. pos[2]] = i
    end
    local hl = g.highlight or {}
    local selected = g.selected
    local conflicts = g.conflicts or {}
    local wrong = g.wrong_cells or {}

    for r = 1, p.h do
        for c = 1, p.w do
            local cell = p.cells[r][c]
            local cx, cy = ox + (c - 1) * cs, oy + (r - 1) * cs
            local k = r .. "," .. c
            local standable = Puzzle.standable(p, r, c)
            local who = occupant[k]

            -- background: blocked squares are dark, everything standable is light
            local obj = Puzzle.objectInfo(cell.obj)
            local blocked = not cell.void and not standable
            if cell.void then
                bb:paintRect(cx, cy, cs, cs, C.COLOR_GRAY_2)
            elseif blocked then
                bb:paintRect(cx, cy, cs, cs, BLOCKED)
            else
                bb:paintRect(cx, cy, cs, cs, AREA_TINTS[self.tint[cell.area]] or C.COLOR_WHITE)
                self:paintTexture(bb, cell, cx, cy, cs)
                if hl[k] then self:paintHighlight(bb, cx, cy, cs) end
            end
            if cell.carpet and not cell.void and not blocked then
                -- rug icon: full size on a bare carpet, small in the corner under an object
                local alone = not obj
                local size = math.floor(cs * (alone and 0.62 or 0.3))
                local img = self:icon(5, false, size)
                if img and not (who and alone) then
                    local ix, iy
                    if alone then
                        ix = math.floor(cx + (cs - size) / 2)
                        iy = math.floor(cy + (cs - size) / 2 + cs * 0.06)
                    else
                        local pad = math.max(2, math.floor(cs * 0.04))
                        ix, iy = cx + cs - size - pad, cy + cs - size - pad
                    end
                    img:paintTo(bb, ix, iy)
                    if state.marks[k] then bb:lightenRect(ix, iy, size, size, 0.65) end
                end
            end

            -- object
            if obj and not cell.void and not (who and not blocked) then
                self:paintObject(bb, cell.obj, obj, blocked, cx, cy, cs, state.marks[k] and true)
            end

            -- player marks
            if who then
                local s = p.suspects[who]
                local box = math.floor(cs * 0.72)
                local bx, by = math.floor(cx + (cs - box) / 2), math.floor(cy + (cs - box) / 2)
                if who == selected then
                    bb:paintRect(bx, by, box, box, C.COLOR_BLACK)
                    drawCentered(bb, self.f_letter, s.letter, cx + cs / 2, cy + cs / 2, C.COLOR_WHITE, true)
                else
                    bb:paintRect(bx, by, box, box, C.COLOR_WHITE)
                    bb:paintBorder(bx, by, box, box, 2, C.COLOR_BLACK)
                    drawCentered(bb, self.f_letter, s.letter, cx + cs / 2, cy + cs / 2, C.COLOR_BLACK, true)
                end
                if conflicts[who] or wrong[k] then
                    -- warn: heavy frame + corner tag
                    bb:paintBorder(cx + 2, cy + 2, cs - 4, cs - 4, math.max(3, self.thick), C.COLOR_BLACK)
                    drawCentered(bb, self.f_note, "!", cx + cs * 0.88, cy + cs * 0.18, C.COLOR_BLACK, true)
                end
            elseif not cell.void and not blocked then
                if state.marks[k] then
                    local sz = math.floor(cs * 0.5)
                    drawCross(bb, math.floor(cx + (cs - sz) / 2), math.floor(cy + (cs - sz) / 2), sz,
                        math.max(2, math.floor(cs / 18)), C.COLOR_BLACK)
                end
                local notes = state.notes[k]
                if notes then
                    local letters = {}
                    for i = 1, #p.suspects do
                        if notes[i] then table.insert(letters, p.suspects[i].letter) end
                    end
                    if #letters > 0 then
                        local text = table.concat(letters, "")
                        text = fitText(self.f_note, text, cs - 6, true)
                        local w = textWidth(self.f_note, text, true)
                        local h = self.f_note.ftsize:getHeightAndAscender()
                        local ny = cy + math.floor(cs * 0.06) + math.floor(self.thick / 2)
                        if state.marks[k] then ny = cy + cs - h - math.floor(cs * 0.04) end
                        bb:paintRect(math.floor(cx + (cs - w) / 2) - 2, ny, w + 4, h, C.COLOR_WHITE)
                        drawLeft(bb, self.f_note, text, math.floor(cx + (cs - w) / 2), ny, C.COLOR_BLACK, true)
                    end
                end
            end
        end
    end

    -- grid lines: thin inside areas, thick between areas
    for r = 1, p.h do
        for c = 1, p.w do
            local cell = p.cells[r][c]
            local cx, cy = ox + (c - 1) * cs, oy + (r - 1) * cs
            local right = p.cells[r][c + 1]
            local below = p.cells[r + 1] and p.cells[r + 1][c]
            if right then
                if right.area ~= cell.area then
                    bb:paintRect(cx + cs - math.floor(self.thick / 2), cy, self.thick, cs, C.COLOR_BLACK)
                else
                    bb:paintRect(cx + cs, cy, self.thin, cs, C.COLOR_GRAY_9)
                end
            end
            if below then
                if below.area ~= cell.area then
                    bb:paintRect(cx, cy + cs - math.floor(self.thick / 2), cs, self.thick, C.COLOR_BLACK)
                else
                    bb:paintRect(cx, cy + cs, cs, self.thin, C.COLOR_GRAY_9)
                end
            end
        end
    end
    -- fix the little gaps where thick lines cross
    for r = 1, p.h - 1 do
        for c = 1, p.w - 1 do
            local tl, tr = p.cells[r][c].area, p.cells[r][c + 1].area
            local bl, br = p.cells[r + 1][c].area, p.cells[r + 1][c + 1].area
            if tl ~= tr or bl ~= br or tl ~= bl or tr ~= br then
                bb:paintRect(ox + c * cs - math.floor(self.thick / 2), oy + r * cs - math.floor(self.thick / 2),
                    self.thick, self.thick, C.COLOR_BLACK)
            end
        end
    end
    -- windows / doors: draw a white gap with a thin line across thick walls
    for key, kind in pairs(p.windows_h) do
        local r, c = key:match("(%d+),(%d+)")
        r, c = tonumber(r), tonumber(c)
        local wx, wy = ox + (c - 1) * cs, oy + (r - 1) * cs - math.floor(self.thick / 2)
        bb:paintRect(wx + cs * 0.2, wy, cs * 0.6, self.thick, C.COLOR_WHITE)
        if kind == 1 then bb:paintRect(wx + cs * 0.2, wy + math.floor(self.thick / 2), cs * 0.6, 1, C.COLOR_BLACK) end
    end
    for key, kind in pairs(p.windows_v) do
        local r, c = key:match("(%d+),(%d+)")
        r, c = tonumber(r), tonumber(c)
        local wx, wy = ox + (c - 1) * cs - math.floor(self.thick / 2), oy + (r - 1) * cs
        bb:paintRect(wx, wy + cs * 0.2, self.thick, cs * 0.6, C.COLOR_WHITE)
        if kind == 1 then bb:paintRect(wx + math.floor(self.thick / 2), wy + cs * 0.2, 1, cs * 0.6, C.COLOR_BLACK) end
    end
    bb:paintBorder(ox - math.floor(self.thick / 2), oy - math.floor(self.thick / 2),
        self.grid_w + self.thick, self.grid_h + self.thick, self.thick, C.COLOR_BLACK)

    -- room names (on top of everything except placed letters)
    if opts.room_names then
        local pad = math.max(2, math.floor(cs * 0.06))
        for key, info in pairs(self.room_label) do
            local r, c = key:match("(%d+),(%d+)")
            r, c = tonumber(r), tonumber(c)
            local cx, cy = ox + (c - 1) * cs, oy + (r - 1) * cs
            local max_w = info.span * cs - 2 * pad - self.thick
            local lx, ly = cx + pad + math.floor(self.thick / 2), cy + math.floor(self.thick / 2)
            -- full name at the normal size, then smaller, then on two lines,
            -- and only then shortened
            local lines, font
            for _, f in ipairs({ self.f_room, self.f_room_small }) do
                if textWidth(f, info.name, true) <= max_w then lines, font = { info.name }, f break end
            end
            if not lines then
                local a, b = info.name:match("^(.-)%s+(%S+)$")
                if a and textWidth(self.f_room_small, a, true) <= max_w
                        and textWidth(self.f_room_small, b, true) <= max_w then
                    lines, font = { a, b }, self.f_room_small
                end
            end
            if not lines then
                font = self.f_room_small
                lines = { fitText(font, info.name, max_w, true) }
            end
            local h = font.ftsize:getHeightAndAscender()
            for n, text in ipairs(lines) do
                if text ~= "" then
                    local w = textWidth(font, text, true)
                    local y = ly + (n - 1) * h
                    bb:paintRect(lx - 2, y, w + 4, h, C.COLOR_WHITE)
                    drawLeft(bb, font, text, lx, y, C.COLOR_BLACK, true)
                end
            end
        end
    end
end

function Board:onTapBoard(_, ges)
    local r, c = self:cellAt(ges.pos.x, ges.pos.y)
    if r then self.game:onCellTap(r, c) end
    return true
end

function Board:onHoldBoard(_, ges)
    local r, c = self:cellAt(ges.pos.x, ges.pos.y)
    if r then self.game:onCellHold(r, c) end
    return true
end

-- Swipe across cells: mark every cell on the straight line with an X.
function Board:onSwipeBoard(_, ges)
    local r1, c1 = self:cellAt(ges.pos.x, ges.pos.y)
    if not r1 or not ges.end_pos then return true end
    local ex = math.max(self.dimen.x + self.label_w, math.min(ges.end_pos.x, self.dimen.x + self.label_w + self.grid_w - 1))
    local ey = math.max(self.dimen.y + self.label_h, math.min(ges.end_pos.y, self.dimen.y + self.label_h + self.grid_h - 1))
    local r2, c2 = self:cellAt(ex, ey)
    if not r2 then return true end
    local cells = {}
    if math.abs(r2 - r1) >= math.abs(c2 - c1) then
        local step = r2 >= r1 and 1 or -1
        for r = r1, r2, step do table.insert(cells, { r, c1 }) end
    else
        local step = c2 >= c1 and 1 or -1
        for c = c1, c2, step do table.insert(cells, { r1, c }) end
    end
    self.game:onCellsSwipe(cells)
    return true
end

--------------------------------------------------------------------------------
-- SuspectBar
--------------------------------------------------------------------------------

local SuspectBar = InputContainer:extend{
    puzzle = nil,
    game = nil,
    width = nil,
}

function SuspectBar:init()
    local n = #self.puzzle.suspects
    local min_chip = Screen:scaleBySize(62)
    self.per_row = math.max(1, math.min(n, math.floor(self.width / min_chip)))
    self.rows = math.ceil(n / self.per_row)
    self.per_row = math.ceil(n / self.rows) -- balance rows
    self.chip_w = math.floor(self.width / self.per_row)
    self.chip_h = Screen:scaleBySize(56)
    self.gap = Screen:scaleBySize(3)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.rows * self.chip_h }
    self.f_letter = face("NotoSans-Bold.ttf", self.chip_h * 0.42)
    self.f_name = face("NotoSans-Regular.ttf", self.chip_h * 0.24)
    local range = function() return self.dimen end
    self.ges_events = {
        TapChip = { GestureRange:new{ ges = "tap", range = range } },
        HoldChip = { GestureRange:new{ ges = "hold", range = range } },
    }
end

function SuspectBar:chipAt(x, y)
    local col = math.floor((x - self.dimen.x) / self.chip_w)
    local row = math.floor((y - self.dimen.y) / self.chip_h)
    local i = row * self.per_row + col + 1
    if i >= 1 and i <= #self.puzzle.suspects and col < self.per_row then return i end
end

function SuspectBar:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local p, g = self.puzzle, self.game
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C.COLOR_WHITE)
    for i, s in ipairs(p.suspects) do
        local row = math.floor((i - 1) / self.per_row)
        local col = (i - 1) % self.per_row
        local cx = x + col * self.chip_w + self.gap
        local cy = y + row * self.chip_h + self.gap
        local w, h = self.chip_w - 2 * self.gap, self.chip_h - 2 * self.gap
        local placed = g.state.placed[i] ~= nil
        local fg = C.COLOR_BLACK
        if i == g.selected then
            bb:paintRect(cx, cy, w, h, C.COLOR_BLACK)
            fg = C.COLOR_WHITE
        else
            bb:paintRect(cx, cy, w, h, placed and C.COLOR_GRAY_D or C.COLOR_WHITE)
            bb:paintBorder(cx, cy, w, h, 2, C.COLOR_BLACK)
        end
        drawCentered(bb, self.f_letter, s.letter, cx + w / 2, cy + h * 0.36, fg, true)
        local name = fitText(self.f_name, s.name, w - 4)
        drawCentered(bb, self.f_name, name, cx + w / 2, cy + h * 0.78, fg)
        if placed then
            -- small tick bar in the corner shows "already on the board"
            local t = math.max(4, math.floor(h * 0.12))
            bb:paintRect(cx + w - t - 3, cy + 3, t, t, fg)
        end
    end
end

function SuspectBar:onTapChip(_, ges)
    local i = self:chipAt(ges.pos.x, ges.pos.y)
    if i then self.game:onSuspectTap(i) end
    return true
end

function SuspectBar:onHoldChip(_, ges)
    local i = self:chipAt(ges.pos.x, ges.pos.y)
    if i then self.game:onSuspectHold(i) end
    return true
end

--------------------------------------------------------------------------------
-- Toolbar: a row of icon buttons (no text). Active tools are drawn inverted.
--------------------------------------------------------------------------------

local ImageWidget = require("ui/widget/imagewidget")
local PLUGIN_DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."

local Toolbar = InputContainer:extend{
    width = nil,
    height = nil,
    items = nil, -- { { id=, icon=, callback=, active=function() } }
}

function Toolbar:init()
    local n = #self.items
    self.btn_w = math.floor(self.width / n)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    local isz = math.floor(self.height * 0.56)
    self.isz = isz
    for _, it in ipairs(self.items) do
        it.img = ImageWidget:new{ file = PLUGIN_DIR .. "/toolbar/" .. it.icon .. ".svg",
            width = isz, height = isz, alpha = true, is_icon = true }
        it.img_w = ImageWidget:new{ file = PLUGIN_DIR .. "/toolbar/" .. it.icon .. "-w.svg",
            width = isz, height = isz, alpha = true, is_icon = true }
    end
    local range = function() return self.dimen end
    self.ges_events = {
        TapTool = { GestureRange:new{ ges = "tap", range = range } },
        HoldTool = { GestureRange:new{ ges = "hold", range = range } },
    }
end

function Toolbar:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C.COLOR_WHITE)
    local gap = Screen:scaleBySize(3)
    for i, it in ipairs(self.items) do
        local bx = x + (i - 1) * self.btn_w + gap
        local w, h = self.btn_w - 2 * gap, self.dimen.h - 2 * gap
        local active = it.active and it.active()
        local enabled = not it.enabled or it.enabled()
        if active then
            bb:paintRect(bx, y + gap, w, h, C.COLOR_BLACK)
        else
            bb:paintBorder(bx, y + gap, w, h, Size.border.thin, enabled and C.COLOR_BLACK or C.COLOR_GRAY_9)
        end
        local img = active and it.img_w or it.img
        img:paintTo(bb, math.floor(bx + (w - self.isz) / 2), math.floor(y + gap + (h - self.isz) / 2))
        if not enabled then
            -- grey it out with a light veil
            bb:lightenRect(bx + 2, y + gap + 2, w - 4, h - 4, 0.6)
        end
    end
end

function Toolbar:itemAt(x)
    local i = math.floor((x - self.dimen.x) / self.btn_w) + 1
    return self.items[i]
end

function Toolbar:onTapTool(_, ges)
    local it = self:itemAt(ges.pos.x)
    if it and (not it.enabled or it.enabled()) then it.callback() end
    return true
end

function Toolbar:onHoldTool(_, ges)
    local it = self:itemAt(ges.pos.x)
    if it and it.label then
        UIManager:show(InfoMessage:new{ text = it.label, timeout = 2 })
    end
    return true
end

return {
    Board = Board,
    SuspectBar = SuspectBar,
    Toolbar = Toolbar,
}
