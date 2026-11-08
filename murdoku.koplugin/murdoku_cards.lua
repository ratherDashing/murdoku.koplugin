--[[--
Suspect cards and popups for the game screen:
  * SuspectPanel – paged cards (face, letter badge + name, clue) under the
                   board in portrait and beside it in landscape
  * showSuspectPopup – XRay-style bottom sheet for a held suspect
  * showCellCard  – compact floating card for a held square
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local lfs = require("libs/libkoreader-lfs")
local Faces = require("murdoku_faces")
local Puzzle = require("murdoku_puzzle")
local Screen = Device.screen

local C = Blitbuffer
local PLUGIN_DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."

-- Letter badge: white letter on a black square (outlined when placed).
local function badge(letter, face, inverted)
    local tw = TextWidget:new{ text = letter, face = face, bold = true,
        fgcolor = inverted and C.COLOR_BLACK or C.COLOR_WHITE }
    return FrameContainer:new{
        bordersize = Size.border.thick, color = C.COLOR_BLACK, margin = 0,
        padding = 0, padding_left = Size.padding.small, padding_right = Size.padding.small,
        background = inverted and C.COLOR_WHITE or C.COLOR_BLACK,
        tw,
    }
end

local function faceImage(s, size)
    local fn = Faces.file(s)
    if not fn then return HorizontalSpan:new{ width = size } end
    return ImageWidget:new{ file = fn, width = size, height = size, alpha = true }
end

--------------------------------------------------------------------------------
-- SuspectPanel
--------------------------------------------------------------------------------

local SuspectPanel = InputContainer:extend{
    puzzle = nil,
    game = nil,
    width = nil,
    height = nil,
}

function SuspectPanel:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.f_strip = Font:getFace("cfont", 16)
    self.f_name = Font:getFace("cfont", 13)
    self.f_clue = Font:getFace("cfont", 14)
    self.f_badge = Font:getFace("cfont", 12)
    local n = #self.puzzle.suspects
    self.cols = self.width >= Screen:scaleBySize(500) and 2 or 1
    -- one line for the status strip, two if the general clues need it
    local line = self.f_strip.ftsize:getHeightAndAscender()
    local lines = self.cols == 2 and 1 or 2
    local gen = self.puzzle.general_clues
    if gen and #gen > 0 then
        local tb = TextBoxWidget:new{ text = "General: " .. table.concat(gen, " "), face = self.f_strip,
            width = self.width - Screen:scaleBySize(90) - 2 * Size.padding.small }
        lines = math.max(lines, math.min(3, #tb.vertical_string_list))
        tb:free()
    end
    self.strip_h = math.floor(line * lines + Size.padding.small * 2)
    self.strip_h = math.max(self.strip_h, Screen:scaleBySize(30))
    local avail = self.height - self.strip_h
    local min_h = Screen:scaleBySize(72)
    self.rows = math.max(1, math.floor(avail / min_h))
    -- don't make more rows than needed
    self.rows = math.min(self.rows, math.ceil(n / self.cols))
    self.per_page = self.rows * self.cols
    self.pages = math.ceil(n / self.per_page)
    self.card_w = math.floor(self.width / self.cols)
    self.card_h = math.min(math.floor(avail / self.rows), Screen:scaleBySize(130))
    self.page = 1
    local range = function() return self.dimen end
    self.ges_events = {
        TapPanel = { GestureRange:new{ ges = "tap", range = range } },
        HoldPanel = { GestureRange:new{ ges = "hold", range = range } },
        SwipePanel = { GestureRange:new{ ges = "swipe", range = range } },
    }
    self:build()
end

function SuspectPanel:showSuspect(i)
    if not i then return end
    local pg = math.floor((i - 1) / self.per_page) + 1
    if pg ~= self.page then
        self.page = pg
    end
end

function SuspectPanel:build()
    local p, g = self.puzzle, self.game
    local gap = Size.padding.small
    self.cards = {}
    local first = (self.page - 1) * self.per_page + 1
    for i = first, math.min(#p.suspects, first + self.per_page - 1) do
        local s = p.suspects[i]
        local selected = g.selected == i
        local pos = g.state.placed[i]
        local bw = selected and Size.border.thick * 2 or Size.border.thin
        local w, h = self.card_w - 2 * gap, self.card_h - 2 * gap
        local bw_max = Size.border.thick * 2
        local pad = Size.padding.small + (bw_max - bw)
        local inner_h = h - 2 * bw - 2 * pad
        -- left column: face with the letter badge and name under it
        local col_w = math.floor(math.min(w * 0.3, Screen:scaleBySize(110)))
        local head = HorizontalGroup:new{ align = "center",
            badge(s.letter, self.f_badge, pos ~= nil),
            HorizontalSpan:new{ width = Size.padding.small },
            TextWidget:new{ text = s.name, face = self.f_name, bold = true,
                max_width = col_w - Screen:scaleBySize(24) },
        }
        local fsz = math.max(10, math.min(col_w, inner_h - head:getSize().h))
        local left = VerticalGroup:new{ align = "center",
            faceImage(s, fsz),
            head,
        }
        local text_w = w - 2 * bw - 2 * pad - math.max(col_w, head:getSize().w) - Size.padding.default
        local clue = s.clue
        if pos then clue = clue .. string.format("  [R%d C%d]", pos[1], pos[2]) end
        local body = TextBoxWidget:new{
            text = clue, face = self.f_clue, width = text_w,
            height = inner_h, height_overflow_show_ellipsis = true,
        }
        local card = FrameContainer:new{
            width = w, height = h, bordersize = bw, padding = pad, margin = 0,
            radius = Size.radius.default,
            color = selected and C.COLOR_BLACK or C.COLOR_DARK_GRAY,
            background = C.COLOR_WHITE,
            HorizontalGroup:new{ align = "top",
                left,
                HorizontalSpan:new{ width = Size.padding.default },
                body,
            },
        }
        table.insert(self.cards, { i = i, w = card })
    end
end

function SuspectPanel:stripText()
    return self.game:statusText()
end

function SuspectPanel:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C.COLOR_WHITE)
    local gap = Size.padding.small
    -- status / general clue strip, with a pager on the right
    local pager_w = 0
    if self.pages > 1 then
        pager_w = Screen:scaleBySize(90)
        local t = TextWidget:new{ text = string.format("‹ %d/%d ›", self.page, self.pages),
            face = self.f_name, bold = true }
        local ts = t:getSize()
        bb:paintBorder(x + self.width - pager_w + gap, y + gap, pager_w - 2 * gap, self.strip_h - 2 * gap,
            Size.border.thin, C.COLOR_BLACK)
        t:paintTo(bb, math.floor(x + self.width - pager_w / 2 - ts.w / 2), math.floor(y + (self.strip_h - ts.h) / 2))
        t:free()
    end
    local text = self:stripText()
    if text and text ~= "" then
        local tb = TextBoxWidget:new{ text = text, face = self.f_strip,
            width = self.width - pager_w - 2 * gap, height = self.strip_h - 2 * gap,
            height_overflow_show_ellipsis = true }
        tb:paintTo(bb, x + gap, y + gap)
        tb:free()
    end
    self.rects = {}
    for k, c in ipairs(self.cards) do
        local col = (k - 1) % self.cols
        local row = math.floor((k - 1) / self.cols)
        local cx = x + col * self.card_w + gap
        local cy = y + self.strip_h + row * self.card_h + gap
        c.w:paintTo(bb, cx, cy)
        self.rects[k] = { i = c.i, x = cx, y = cy, w = self.card_w - 2 * gap, h = self.card_h - 2 * gap }
    end
end

function SuspectPanel:hit(pos)
    for _, r in ipairs(self.rects or {}) do
        if pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h then return r.i end
    end
end

function SuspectPanel:turn(delta)
    local pg = math.max(1, math.min(self.pages, self.page + delta))
    if pg == self.page then
        pg = delta > 0 and 1 or self.pages -- wrap around
    end
    self.page = pg
    self:build()
    UIManager:setDirty(self.game, function() return "ui", self.dimen end)
end

function SuspectPanel:onTapPanel(_, ges)
    local i = self:hit(ges.pos)
    if i then
        self.game:onSuspectTap(i)
    elseif ges.pos.y < self.dimen.y + self.strip_h then
        if self.pages > 1 and ges.pos.x > self.dimen.x + self.width - Screen:scaleBySize(90) then
            local mid = self.dimen.x + self.width - Screen:scaleBySize(45)
            self:turn(ges.pos.x < mid and -1 or 1)
        else
            self.game:showAllClues()
        end
    end
    return true
end

function SuspectPanel:onHoldPanel(_, ges)
    local i = self:hit(ges.pos)
    if i then self.game:onSuspectHold(i) end
    return true
end

function SuspectPanel:onSwipePanel(_, ges)
    if self.pages > 1 and (ges.direction == "west" or ges.direction == "east") then
        self:turn(ges.direction == "west" and 1 or -1)
    end
    return true
end

--------------------------------------------------------------------------------
-- Popups: dismissed by a tap (or hold) anywhere.
--------------------------------------------------------------------------------

local Popup = InputContainer:extend{
    content = nil,
    pos_x = 0,
    pos_y = 0,
    on_close = nil,
}

function Popup:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    local sz = self.content:getSize()
    self.region = Geom:new{ x = self.pos_x, y = self.pos_y, w = sz.w, h = sz.h }
    local range = function() return self.dimen end
    self.ges_events = {
        TapClose = { GestureRange:new{ ges = "tap", range = range } },
        HoldClose = { GestureRange:new{ ges = "hold", range = range } },
    }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
end

function Popup:paintTo(bb)
    self.content:paintTo(bb, self.region.x, self.region.y)
end

function Popup:onShow()
    UIManager:setDirty(self, function() return "ui", self.region end)
end

function Popup:close()
    UIManager:close(self, "ui", self.region)
    if self.on_close then self.on_close() end
    return true
end
Popup.onTapClose = Popup.close
Popup.onHoldClose = Popup.close
Popup.onClose = Popup.close

local M = { SuspectPanel = SuspectPanel }

--- XRay-style bottom sheet for a held suspect.
function M.showSuspectPopup(p, i, placed)
    local s = p.suspects[i]
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local pad = Size.padding.large * 2
    local inner_w = sw - 2 * pad
    local face_sz = math.floor(math.min(sw, sh) * 0.17)
    local text_w = inner_w - face_sz - pad
    local who = s.is_victim and "The victim" or (s.female and "Woman" or "Man")
    local traits = Faces.traits(s)
    table.insert(traits, 1, who)
    local pos = placed[i]
    local lines = VerticalGroup:new{ align = "left",
        HorizontalGroup:new{ align = "center",
            badge(s.letter, Font:getFace("cfont", 20), pos ~= nil),
            HorizontalSpan:new{ width = Size.padding.large },
            TextWidget:new{ text = s.name, face = Font:getFace("cfont", 24), bold = true,
                max_width = text_w - Screen:scaleBySize(50) },
        },
        TextWidget:new{ text = table.concat(traits, " · ") .. (pos and string.format("  ·  placed at R%d C%d", pos[1], pos[2]) or ""),
            face = Font:getFace("cfont", 16), fgcolor = C.COLOR_DARK_GRAY, max_width = text_w },
        VerticalSpan:new{ width = Size.padding.large },
        TextBoxWidget:new{ text = s.clue, face = Font:getFace("cfont", 21), width = text_w },
    }
    local content = VerticalGroup:new{ align = "left",
        LineWidget:new{ dimen = Geom:new{ w = sw, h = Size.line.thick }, background = C.COLOR_DARK_GRAY },
        FrameContainer:new{
            background = C.COLOR_WHITE, bordersize = 0, width = sw,
            padding = pad, padding_top = Size.padding.large, padding_bottom = pad,
            HorizontalGroup:new{ align = "top",
                FrameContainer:new{ bordersize = Size.border.thick, radius = Size.radius.window, padding = 0,
                    faceImage(s, face_sz) },
                HorizontalSpan:new{ width = pad },
                lines,
            },
        },
    }
    local h = content:getSize().h
    UIManager:show(Popup:new{ content = content, pos_x = 0, pos_y = sh - h })
end

--- Compact floating card for a held square, placed next to it.
-- rect = { x, y, w, h } of the square on screen.
function M.showCellCard(p, r, c, rect, occupant)
    local cell = Puzzle.cell(p, r, c)
    if not cell then return end
    local o = Puzzle.objectInfo(cell.obj)
    local name
    if cell.void then name = "Not part of the scene"
    elseif o and cell.obj ~= 0 then name = o.name end
    if cell.carpet and not cell.void then name = name and (name .. " on a carpet") or "Carpet" end
    name = name or "Empty floor"
    local can = cell.void and "" or (Puzzle.standable(p, r, c) and "You can stand here." or "You can't stand here.")
    local area = cell.void and "" or (p.rooms[cell.area].name .. " · ")
    local isz = Screen:scaleBySize(48)
    local icon
    local fn = PLUGIN_DIR .. "/icons/" .. tostring(cell.obj) .. ".svg"
    if o and cell.obj ~= 0 and lfs.attributes(fn, "mode") == "file" then
        icon = ImageWidget:new{ file = fn, width = isz, height = isz, alpha = true, is_icon = true }
    end
    local texts = VerticalGroup:new{ align = "left",
        TextWidget:new{ text = name, face = Font:getFace("cfont", 22), bold = true },
        TextWidget:new{ text = area .. string.format("R%d C%d", r, c), face = Font:getFace("cfont", 17),
            fgcolor = C.COLOR_DARK_GRAY },
    }
    if can ~= "" then
        table.insert(texts, TextWidget:new{ text = can, face = Font:getFace("cfont", 17), bold = true })
    end
    if occupant then
        table.insert(texts, TextWidget:new{ text = "Placed here: " .. occupant.name, face = Font:getFace("cfont", 17) })
    end
    local row = HorizontalGroup:new{ align = "center" }
    if icon then
        table.insert(row, icon)
        table.insert(row, HorizontalSpan:new{ width = Size.padding.large })
    end
    table.insert(row, texts)
    local content = FrameContainer:new{
        bordersize = Size.border.thick, radius = Size.radius.window, padding = Size.padding.large,
        background = C.COLOR_WHITE, row,
    }
    local sz = content:getSize()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local x = math.floor(rect.x + rect.w / 2 - sz.w / 2)
    x = math.max(Size.padding.default, math.min(x, sw - sz.w - Size.padding.default))
    local y = rect.y - sz.h - Size.padding.default
    if y < Size.padding.default then y = rect.y + rect.h + Size.padding.default end
    y = math.min(y, sh - sz.h - Size.padding.default)
    UIManager:show(Popup:new{ content = content, pos_x = x, pos_y = y })
end

return M
